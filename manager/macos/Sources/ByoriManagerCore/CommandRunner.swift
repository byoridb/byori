import Darwin
import Foundation

public protocol CommandRunning: Sendable {
    func run(_ command: CommandSpec) async -> CommandResult
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
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
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runSynchronously(command))
            }
        }
    }

    private static func runSynchronously(_ command: CommandSpec) -> CommandResult {
        var pipeFDs = [Int32](repeating: -1, count: 2)
        guard pipe(&pipeFDs) == 0 else {
            return systemErrorResult(prefix: "pipe")
        }
        let readFD = pipeFDs[0]
        let writeFD = pipeFDs[1]
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

        let output = BoundedOutput()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                close(readFD)
                reader.leave()
            }
            var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(readFD, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    buffer.withUnsafeBytes { bytes in
                        output.append(UnsafeRawBufferPointer(rebasing: bytes[..<count]))
                    }
                } else if count == 0 {
                    return
                } else if errno != EINTR {
                    return
                }
            }
        }

        let didTimeOut = LockedFlag()
        let finished = LockedFlag()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + max(0, command.timeout))
        timer.setEventHandler {
            guard !finished.get() else { return }
            didTimeOut.set()
            _ = kill(-spawnedPID, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                guard !finished.get() else { return }
                _ = kill(-spawnedPID, SIGKILL)
            }
        }
        timer.resume()

        var waitStatus: Int32 = 0
        while waitpid(spawnedPID, &waitStatus, 0) == -1, errno == EINTR {}

        finished.set()
        if didTimeOut.get() {
            // The group can still contain a child after the leader exits.
            _ = kill(-spawnedPID, SIGKILL)
        }
        timer.cancel()

        if reader.wait(timeout: .now() + 1) == .timedOut {
            // A successful command should not leave background children holding
            // the output pipe. Treat the command tree as a unit and clean it up.
            _ = kill(-spawnedPID, SIGTERM)
            usleep(100_000)
            _ = kill(-spawnedPID, SIGKILL)
            _ = reader.wait(timeout: .now() + 1)
        }

        return CommandResult(
            exitCode: exitCode(from: waitStatus),
            output: output.string().trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: didTimeOut.get()
        )
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
