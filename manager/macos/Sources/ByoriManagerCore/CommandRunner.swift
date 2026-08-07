import Darwin
import Foundation

public protocol CommandRunning: Sendable {
    func run(_ command: CommandSpec) async -> CommandResult
}

private final class CancellationIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    func isRequested() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }
}

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int = 256 * 1_024) {
        self.limit = limit
    }

    func append(_ chunk: UnsafeRawBufferPointer) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk.bindMemory(to: UInt8.self))
        if data.count > limit {
            data.removeFirst(data.count - limit)
        }
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ command: CommandSpec) async -> CommandResult {
        let cancellation = CancellationIntent()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        returning: Self.runSynchronously(
                            command,
                            cancellation: cancellation
                        )
                    )
                }
            }
        } onCancel: {
            // Only record intent here. The synchronous worker owns spawn,
            // waitpid, and every signal, so cancellation can never race with
            // reaping or target a subsequently reused PID/process group.
            cancellation.request()
        }
    }

    private static func runSynchronously(
        _ command: CommandSpec,
        cancellation: CancellationIntent
    ) -> CommandResult {
        var pipeFDs = [Int32](repeating: -1, count: 2)
        guard pipe(&pipeFDs) == 0 else {
            return systemErrorResult(prefix: "pipe")
        }
        let readFD = pipeFDs[0]
        let writeFD = pipeFDs[1]
        let readFlags = fcntl(readFD, F_GETFL)
        guard readFlags >= 0,
              fcntl(readFD, F_SETFL, readFlags | O_NONBLOCK) == 0 else {
            close(readFD)
            close(writeFD)
            return systemErrorResult(prefix: "fcntl output pipe")
        }
        let nullFD = open("/dev/null", O_RDONLY)
        guard nullFD >= 0 else {
            close(readFD)
            close(writeFD)
            return systemErrorResult(prefix: "open /dev/null")
        }

        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            close(readFD)
            close(writeFD)
            close(nullFD)
            return systemErrorResult(prefix: "posix_spawn setup")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        var setupCode = posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        if setupCode == 0 {
            setupCode = posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO)
        }
        if setupCode == 0 {
            setupCode = posix_spawn_file_actions_adddup2(&actions, nullFD, STDIN_FILENO)
        }
        for descriptor in [readFD, writeFD, nullFD] where setupCode == 0 {
            setupCode = posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        if setupCode == 0, let directory = command.workingDirectory {
            setupCode = directory.withCString {
                posix_spawn_file_actions_addchdir_np(&actions, $0)
            }
        }
        if setupCode != 0 {
            close(readFD)
            close(writeFD)
            close(nullFD)
            return errorResult(code: setupCode, prefix: "posix_spawn file actions")
        }

        // Creating the process group as part of spawn avoids the race where the
        // child execs before a parent-side setpgid call. Every descendant then
        // inherits the group and can be terminated as one command tree.
        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        var setupStatus = posix_spawnattr_setflags(&attributes, flags)
        if setupStatus == 0 {
            setupStatus = posix_spawnattr_setpgroup(&attributes, 0)
        }
        if setupStatus != 0 {
            close(readFD)
            close(writeFD)
            close(nullFD)
            return errorResult(code: setupStatus, prefix: "posix_spawn attributes")
        }

        var environment = ProcessInfo.processInfo.environment
        command.environment.forEach { environment[$0.key] = $0.value }
        var arguments: [UnsafeMutablePointer<CChar>?] =
            ([command.executable] + command.arguments).map { value in
                value.withCString { strdup($0) }
            }
        arguments.append(nil)
        let environmentStrings = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var environmentPointers: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { value in
            value.withCString { strdup($0) }
        }
        environmentPointers.append(nil)
        defer {
            for case let pointer? in arguments {
                free(UnsafeMutableRawPointer(pointer))
            }
            for case let pointer? in environmentPointers {
                free(UnsafeMutableRawPointer(pointer))
            }
        }

        var pid: pid_t = 0
        let spawnStatus = command.executable.withCString { executable in
            posix_spawn(
                &pid,
                executable,
                &actions,
                &attributes,
                &arguments,
                &environmentPointers
            )
        }
        close(writeFD)
        close(nullFD)
        guard spawnStatus == 0 else {
            close(readFD)
            return errorResult(code: spawnStatus, prefix: "Unable to run \(command.executable)")
        }
        let spawnedPID = pid
        defer { close(readFD) }

        let output = BoundedOutput()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let timeoutAt = startedAt + max(0, command.timeout)
        var terminationStartedAt: TimeInterval?
        var forceKillSentAt: TimeInterval?
        var didTimeOut = false
        var waitStatus: Int32 = 0
        var waitError: Int32?
        var outputIsClosed = false
        var leaderExitObserved = false

        while true {
            if !outputIsClosed {
                outputIsClosed = drainOutput(from: readFD, into: output)
            }

            if !leaderExitObserved {
                var exitInfo = siginfo_t()
                let observation = waitid(
                    P_PID,
                    id_t(spawnedPID),
                    &exitInfo,
                    WEXITED | WNOHANG | WNOWAIT
                )
                if observation == 0, exitInfo.si_pid == spawnedPID {
                    // WNOWAIT deliberately keeps the leader as a zombie. Its
                    // PID/PGID therefore cannot be reused while cancellation
                    // finishes terminating descendants in the same group.
                    leaderExitObserved = true
                } else if observation == -1 {
                    if errno == EINTR { continue }
                    waitError = errno
                    break
                }
            }

            let now = ProcessInfo.processInfo.systemUptime
            if let terminationStartedAt {
                if forceKillSentAt == nil, now - terminationStartedAt >= 2 {
                    _ = kill(-spawnedPID, SIGKILL)
                    forceKillSentAt = now
                }
            } else if cancellation.isRequested() {
                _ = kill(-spawnedPID, SIGTERM)
                terminationStartedAt = now
            } else if leaderExitObserved {
                // Natural completion has no reason to terminate a deliberately
                // backgrounded descendant. Reap immediately and bound the pipe
                // drain below.
                break
            } else if now >= timeoutAt {
                didTimeOut = true
                _ = kill(-spawnedPID, SIGTERM)
                terminationStartedAt = now
            }

            if leaderExitObserved,
               let forceKillSentAt,
               now - forceKillSentAt >= 0.05 {
                break
            }

            usleep(10_000)
        }

        if waitError == nil {
            // This is the sole reap point. Every possible process-group signal
            // is complete before waitpid releases the numeric PID/PGID.
            while waitpid(spawnedPID, &waitStatus, 0) == -1 {
                if errno == EINTR { continue }
                waitError = errno
                break
            }
        }

        // The group leader is now reaped (or is no longer our child). A
        // descendant may still hold the output pipe open, so do a short,
        // nonblocking drain and then stop. Never signal the reaped PGID merely
        // to make a pipe reader finish.
        let drainDeadline = ProcessInfo.processInfo.systemUptime + 0.15
        var shouldStopReading = outputIsClosed
        while !shouldStopReading {
            shouldStopReading = drainOutput(from: readFD, into: output)
                || ProcessInfo.processInfo.systemUptime >= drainDeadline
            if !shouldStopReading {
                usleep(5_000)
            }
        }

        if let waitError {
            let detail = String(cString: strerror(waitError))
            let captured = output.string().trimmingCharacters(in: .whitespacesAndNewlines)
            let message = captured.isEmpty ? detail : "\(captured)\nwaitpid: \(detail)"
            return CommandResult(exitCode: 127, output: message, timedOut: didTimeOut)
        }

        return CommandResult(
            exitCode: exitCode(from: waitStatus),
            output: output.string().trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: didTimeOut
        )
    }

    /// Drains a bounded number of nonblocking reads so a continuously writing
    /// child cannot starve wait/timeout polling. Returns true at EOF or on a
    /// terminal read error, and false when the pipe remains open.
    private static func drainOutput(
        from readFD: Int32,
        into output: BoundedOutput
    ) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        for _ in 0..<32 {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(readFD, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                buffer.withUnsafeBytes { bytes in
                    output.append(UnsafeRawBufferPointer(rebasing: bytes[..<count]))
                }
                continue
            }
            if count == 0 { return true }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return false }
            return true
        }
        return false
    }

    private static func exitCode(from status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func systemErrorResult(prefix: String) -> CommandResult {
        errorResult(code: errno, prefix: prefix)
    }

    private static func errorResult(code: Int32, prefix: String) -> CommandResult {
        CommandResult(exitCode: 127, output: "\(prefix): \(String(cString: strerror(code)))")
    }
}
