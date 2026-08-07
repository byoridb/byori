import Darwin
import Foundation

/// Verifies that the configured TCP listener is the process managed by the
/// current user's ByoriDB launchd job before callers send credentials to it.
public struct LocalServiceVerifier: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func verify(paths: ManagerPaths) async -> Bool {
        guard (1...65_535).contains(paths.httpPort) else { return false }
        let target = "gui/\(getuid())/\(paths.serviceLabel)"
        let launchd = await runner.run(CommandSpec(
            executable: "/bin/launchctl",
            arguments: ["print", target],
            timeout: 5
        ))
        guard launchd.succeeded, let pid = Self.pid(fromLaunchctlOutput: launchd.output) else {
            return false
        }

        // Restrict lsof to the launchd-reported PID and the configured listening
        // port. A different local user can bind localhost, but cannot appear as
        // a process in this user's launchd domain with this job label.
        let listener = await runner.run(CommandSpec(
            executable: "/usr/sbin/lsof",
            arguments: [
                "-nP", "-a", "-p", String(pid),
                "-iTCP:\(paths.httpPort)", "-sTCP:LISTEN", "-Fp",
            ],
            timeout: 5
        ))
        return listener.succeeded && Self.contains(pid: pid, inLsofOutput: listener.output)
    }

    static func pid(fromLaunchctlOutput output: String) -> Int32? {
        for line in output.components(separatedBy: .newlines) {
            let fields = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces) == "pid",
                  let pid = Int32(fields[1].trimmingCharacters(in: .whitespaces)), pid > 0 else {
                continue
            }
            return pid
        }
        return nil
    }

    static func contains(pid: Int32, inLsofOutput output: String) -> Bool {
        output.components(separatedBy: .newlines).contains("p\(pid)")
    }
}
