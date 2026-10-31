import Darwin
import Foundation
import XCTest
@testable import ByoriManagerCore

final class RuntimeMutationLeaseTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("byori-lease-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: base) }
        return base.appendingPathComponent("runtime", isDirectory: true)
    }

    private func python() throws -> String {
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { String($0) + "/python3" }
            + ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("python3 is required for real subprocess flock tests")
        }
        return path
    }

    private func runPython(_ script: String, arguments: [String] = []) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try python())
        process.arguments = ["-c", script] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    private func assertBusy(_ home: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RuntimeMutationLease.acquire(home: home), file: file, line: line) {
            XCTAssertEqual($0 as? RuntimeMutationLeaseError, .busy, file: file, line: line)
        }
    }

    private func assertUnsafe(_ home: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RuntimeMutationLease.acquire(home: home), file: file, line: line) {
            guard case .unsafe = $0 as? RuntimeMutationLeaseError else {
                return XCTFail("Expected an unsafe-path error, got \($0)", file: file, line: line)
            }
            XCTAssertFalse($0.localizedDescription.contains(home.path), file: file, line: line)
        }
    }

    func testCreatesPrivateRootAndPersistentLockWithCloseOnExec() throws {
        let home = try temporaryHome()
        let lease = try RuntimeMutationLease.acquire(home: home)
        let descriptor = lease.fileDescriptor
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
        var root = stat()
        var lock = stat()
        XCTAssertEqual(lstat(home.path, &root), 0)
        XCTAssertEqual(fstat(descriptor, &lock), 0)
        XCTAssertEqual(root.st_mode & 0o7777, 0o700)
        XCTAssertEqual(lock.st_mode & 0o7777, 0o600)
        XCTAssertEqual(lock.st_nlink, 1)
        assertBusy(home)
        lease.release()
        lease.release()
        XCTAssertEqual(lease.fileDescriptor, -1)
        let next = try RuntimeMutationLease.acquire(home: home)
        defer { next.release() }
        var reopened = stat()
        XCTAssertEqual(fstat(next.fileDescriptor, &reopened), 0)
        XCTAssertEqual(reopened.st_ino, lock.st_ino)
    }

    func testDeinitAndConcurrentIdempotentRelease() throws {
        let home = try temporaryHome()
        var lease: RuntimeMutationLease? = try RuntimeMutationLease.acquire(home: home)
        assertBusy(home)
        lease = nil
        XCTAssertNil(lease)
        let next = try RuntimeMutationLease.acquire(home: home)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in next.release() }
        let final = try RuntimeMutationLease.acquire(home: home)
        final.release()
    }

    func testReleaseAndDeinitCloseOnlyAndLeaveDelegatedDescriptionLocked() throws {
        let home = try temporaryHome()
        for explicitRelease in [false, true] {
            var lease: RuntimeMutationLease? = try RuntimeMutationLease.acquire(home: home)
            let delegatedFD = fcntl(try XCTUnwrap(lease).fileDescriptor, F_DUPFD_CLOEXEC, 32)
            XCTAssertGreaterThanOrEqual(delegatedFD, 32)
            if explicitRelease { lease?.release() }
            lease = nil
            assertBusy(home)
            close(delegatedFD)
            let next = try RuntimeMutationLease.acquire(home: home)
            next.release()
        }
    }

    func testDifferentProcessContendsAndAcquiresAfterRelease() throws {
        let home = try temporaryHome()
        let lease = try RuntimeMutationLease.acquire(home: home)
        defer { lease.release() }
        let script = """
        import os, sys, fcntl
        fd = os.open(sys.argv[1], os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit(23)
        """
        let path = home.appendingPathComponent(".runtime-mutation.lock").path
        XCTAssertEqual(try runPython(script, arguments: [path]).0, 23)
        lease.release()
        XCTAssertEqual(try runPython(script, arguments: [path]).0, 0)
    }

    func testDifferentProcessExitReleasesOwnershipWithoutDeletingLock() throws {
        let home = try temporaryHome()
        try RuntimeMutationLease.acquire(home: home).release()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try python())
        process.arguments = ["-c", """
        import os, sys, fcntl
        fd = os.open(sys.argv[1], os.O_RDWR)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print('locked', flush=True)
        sys.stdin.readline()
        """, home.appendingPathComponent(".runtime-mutation.lock").path]
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let ready = try XCTUnwrap(output.fileHandleForReading.read(upToCount: 7))
        XCTAssertEqual(String(decoding: ready, as: UTF8.self), "locked\n")
        assertBusy(home)
        process.terminate()
        process.waitUntilExit()
        let lease = try RuntimeMutationLease.acquire(home: home)
        lease.release()
    }

    func testRejectsProtectedSymlinkAndNonprivateRootsWithoutRepair() throws {
        assertUnsafe(URL(fileURLWithPath: "/"))
        assertUnsafe(URL(fileURLWithPath: NSHomeDirectory()))
        let home = try temporaryHome()
        assertUnsafe(URL(fileURLWithPath: home.path + "\u{0}/ignored"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o755])
        assertUnsafe(home)
        var info = stat()
        XCTAssertEqual(lstat(home.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".runtime-mutation.lock").path))
        XCTAssertEqual(chmod(home.path, 0o700), 0)
        let alias = home.deletingLastPathComponent().appendingPathComponent("alias")
        XCTAssertEqual(symlink(home.path, alias.path), 0)
        assertUnsafe(alias)
        assertUnsafe(alias.appendingPathComponent("", isDirectory: true))
    }

    func testRootRequiresExact0700IncludingSpecialPermissionBitsWithoutRepair() throws {
        let home = try temporaryHome()
        XCTAssertEqual(mkdir(home.path, 0o700), 0)
        defer { _ = chmod(home.path, 0o700) }
        let modes: [mode_t] = [0o000, 0o600, 0o500, 0o755, 0o1700, 0o2700, 0o4700, 0o7700]
        for mode in modes {
            XCTAssertEqual(chmod(home.path, mode), 0)
            var before = stat()
            XCTAssertEqual(lstat(home.path, &before), 0)
            XCTAssertEqual(before.st_mode & 0o7777, mode, "Fixture mode must be exact")
            assertUnsafe(home)
            var after = stat()
            XCTAssertEqual(lstat(home.path, &after), 0)
            XCTAssertEqual(after.st_mode & 0o7777, mode, "Reject without repairing root permissions")
            XCTAssertEqual(after.st_ino, before.st_ino)
            XCTAssertEqual(after.st_dev, before.st_dev)
            XCTAssertEqual(chmod(home.path, 0o700), 0)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".runtime-mutation.lock").path
            ), "Unsafe root must fail before lock creation")
        }
        let lease = try RuntimeMutationLease.acquire(home: home)
        lease.release()
    }

    func testLockRequiresExact0600IncludingSpecialPermissionBitsWithoutRepair() throws {
        let home = try temporaryHome()
        let lease = try RuntimeMutationLease.acquire(home: home)
        XCTAssertEqual(write(lease.fileDescriptor, "preserve", 8), 8)
        lease.release()
        let lock = home.appendingPathComponent(".runtime-mutation.lock")
        defer { _ = chmod(lock.path, 0o600) }
        let modes: [mode_t] = [0o000, 0o700, 0o400, 0o644, 0o1600, 0o2600, 0o4600, 0o7600]
        for mode in modes {
            XCTAssertEqual(chmod(lock.path, mode), 0)
            var before = stat()
            XCTAssertEqual(lstat(lock.path, &before), 0)
            XCTAssertEqual(before.st_mode & 0o7777, mode, "Fixture mode must be exact")
            assertUnsafe(home)
            var after = stat()
            XCTAssertEqual(lstat(lock.path, &after), 0)
            XCTAssertEqual(after.st_mode & 0o7777, mode, "Reject without repairing lock permissions")
            XCTAssertEqual(after.st_ino, before.st_ino)
            XCTAssertEqual(after.st_dev, before.st_dev)
            XCTAssertEqual(after.st_size, before.st_size)
            XCTAssertEqual(after.st_nlink, 1)
            // Restore fixture access only after checking production did not.
            XCTAssertEqual(chmod(lock.path, 0o600), 0)
            XCTAssertEqual(try String(contentsOf: lock), "preserve")
        }
        let next = try RuntimeMutationLease.acquire(home: home)
        next.release()
    }

    func testRejectsUnsafeLockFilesWithoutTruncationOrRepair() throws {
        for kind in ["permissions", "symlink", "hardlink", "fifo", "directory", "owner"] {
            let home = try temporaryHome()
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let lock = home.appendingPathComponent(".runtime-mutation.lock")
            let other = home.appendingPathComponent("original")
            if kind == "fifo" {
                XCTAssertEqual(mkfifo(lock.path, 0o600), 0)
            } else if kind == "directory" {
                XCTAssertEqual(mkdir(lock.path, 0o700), 0)
            } else {
                let fd = open(other.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                XCTAssertGreaterThanOrEqual(fd, 0)
                XCTAssertEqual(write(fd, "preserve", 8), 8)
                close(fd)
                if kind == "symlink" {
                    XCTAssertEqual(symlink(other.path, lock.path), 0)
                } else if kind == "hardlink" {
                    XCTAssertEqual(link(other.path, lock.path), 0)
                } else {
                    try FileManager.default.moveItem(at: other, to: lock)
                    if kind == "permissions" { XCTAssertEqual(chmod(lock.path, 0o644), 0) }
                    if kind == "owner" {
                        guard geteuid() == 0 else { continue }
                        XCTAssertEqual(chown(lock.path, 501, gid_t.max), 0)
                    }
                }
            }
            assertUnsafe(home)
            if kind == "permissions" {
                XCTAssertEqual(try String(contentsOf: lock), "preserve")
                var info = stat()
                XCTAssertEqual(lstat(lock.path, &info), 0)
                XCTAssertEqual(info.st_mode & 0o777, 0o644)
            }
        }
    }

    func testIOErrorsArePreciseAndDoNotExposePaths() throws {
        let home = try temporaryHome().appendingPathComponent("missing-parent/runtime")
        XCTAssertThrowsError(try RuntimeMutationLease.acquire(home: home)) {
            guard case let .io(operation, code) = $0 as? RuntimeMutationLeaseError else {
                return XCTFail("Expected I/O failure, got \($0)")
            }
            XCTAssertEqual(operation, "create root")
            XCTAssertEqual(code, ENOENT)
            XCTAssertFalse($0.localizedDescription.contains(home.path))
        }
    }

    func testNativeRunnerTransfersExactOpenDescriptionAndParentRetainsLease() async throws {
        let home = try temporaryHome()
        let lease = try RuntimeMutationLease.acquire(home: home)
        defer { lease.release() }
        let result = await ProcessCommandRunner().run(CommandSpec(
            executable: try python(), arguments: ["-c", """
            import os, sys, fcntl
            assert os.environ['BYORI_RUNTIME_LEASE_FD'] == '9'
            assert os.fstat(9).st_ino == os.stat(sys.argv[1]).st_ino
            fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
            other = os.open(sys.argv[1], os.O_RDWR)
            try:
                fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print('shared-description; independent-open-busy')
            else:
                sys.exit(24)
            """, home.appendingPathComponent(".runtime-mutation.lock").path],
            environment: ["BYORI_RUNTIME_LEASE_FD": "9"],
            runtimeLeaseFileDescriptor: lease.fileDescriptor))
        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertEqual(result.output, "shared-description; independent-open-busy")
        assertBusy(home)
        lease.release()
        let next = try RuntimeMutationLease.acquire(home: home)
        next.release()
    }

    func testOrdinaryRunnerDoesNotInheritLeaseOrTransportEnvironment() async throws {
        let home = try temporaryHome()
        let lease = try RuntimeMutationLease.acquire(home: home)
        defer { lease.release() }
        let result = await ProcessCommandRunner().run(CommandSpec(
            executable: try python(), arguments: ["-c", """
            import os, sys
            assert 'BYORI_RUNTIME_LEASE_FD' not in os.environ
            inode = os.stat(sys.argv[1]).st_ino
            for fd in range(3, 256):
                try:
                    info = os.fstat(fd)
                except OSError:
                    continue
                assert info.st_ino != inode
            print('not-inherited')
            """, home.appendingPathComponent(".runtime-mutation.lock").path],
            environment: ["BYORI_RUNTIME_LEASE_FD": "9"]))
        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertEqual(result.output, "not-inherited")
        assertBusy(home)
    }

    func testTransportSurvivesOutputPipeUsingDescriptorNineAndHighCallerFD() async throws {
        let executable = try python()
        let home = try temporaryHome()
        let lease = try RuntimeMutationLease.acquire(home: home)
        defer { lease.release() }
        let callerFD = fcntl(lease.fileDescriptor, F_DUPFD_CLOEXEC, 32)
        XCTAssertGreaterThanOrEqual(callerFD, 32)
        defer { close(callerFD) }
        // Reserve lower slots so the next pipe's read end is FD 9. All slots
        // are our own opens; no existing process descriptors are overwritten.
        var reservations: [Int32] = []
        defer { reservations.forEach { close($0) } }
        var available: Int32 = -1
        while true {
            available = open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard available >= 0 else { return XCTFail("Unable to reserve descriptors") }
            if available >= 9 { break }
            reservations.append(available)
        }
        close(available)
        guard available == 9 else {
            throw XCTSkip("Descriptor 9 was already occupied by the test harness")
        }
        let result = await ProcessCommandRunner().run(CommandSpec(
            executable: executable, arguments: ["-c", """
            import os, sys, fcntl
            fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert os.fstat(9).st_ino == os.stat(sys.argv[1]).st_ino
            assert sys.stdin.read() == ''
            print('stdout intact')
            print('stderr intact', file=sys.stderr)
            """, home.appendingPathComponent(".runtime-mutation.lock").path],
            runtimeLeaseFileDescriptor: callerFD))
        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertTrue(result.output.contains("stdout intact"), result.output)
        XCTAssertTrue(result.output.contains("stderr intact"), result.output)
        assertBusy(home)
    }

    func testInvalidDescriptorFailsBeforeSpawnEvenIfSetupWouldReuseIt() async throws {
        let home = try temporaryHome()
        let marker = home.deletingLastPathComponent().appendingPathComponent("spawned")
        let closedFD = open("/dev/null", O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(closedFD, 0)
        close(closedFD)
        for invalid in [Int32(-1), closedFD] {
            let result = await ProcessCommandRunner().run(CommandSpec(
                executable: try python(), arguments: ["-c", "import sys; open(sys.argv[1], 'w').close()", marker.path],
                runtimeLeaseFileDescriptor: invalid))
            XCTAssertEqual(result.exitCode, 127)
            XCTAssertTrue(result.output.contains("duplicate runtime lease descriptor"), result.output)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testSpawnAndFileActionFailuresDoNotLeakTransportDuplicate() async throws {
        let home = try temporaryHome()
        let executable = try python()
        for command in [
            ("/byori-test-nonexistent-executable", Optional<String>.none),
            (executable, Optional("/byori-test-nonexistent-working-directory")),
        ] {
            let lease = try RuntimeMutationLease.acquire(home: home)
            let result = await ProcessCommandRunner().run(CommandSpec(
                executable: command.0, workingDirectory: command.1,
                runtimeLeaseFileDescriptor: lease.fileDescriptor))
            XCTAssertEqual(result.exitCode, 127, result.output)
            lease.release()
            let next = try RuntimeMutationLease.acquire(home: home)
            next.release()
        }
    }

    func testTimeoutAndCancellationDoNotLeakLeaseIncludingDescendants() async throws {
        let executable = try python()
        for cancel in [false, true] {
            let home = try temporaryHome()
            let ready = home.deletingLastPathComponent().appendingPathComponent("ready")
            let lease = try RuntimeMutationLease.acquire(home: home)
            defer { lease.release() }
            let command = CommandSpec(executable: executable, arguments: ["-c", """
                import os, sys, time, signal, fcntl
                fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                if os.fork() == 0:
                    time.sleep(30)
                    os._exit(0)
                open(sys.argv[1], 'w').close()
                print('ready', flush=True)
                time.sleep(30)
                """, ready.path], timeout: cancel ? 15 : 1,
                runtimeLeaseFileDescriptor: lease.fileDescriptor)
            let task = Task { await ProcessCommandRunner().run(command) }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !FileManager.default.fileExists(atPath: ready.path),
                  ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "Child must start before cancellation")
            assertBusy(home)
            if cancel { task.cancel() }
            let result = await task.value
            XCTAssertFalse(result.succeeded)
            XCTAssertEqual(result.timedOut, !cancel)
            XCTAssertTrue(result.output.contains("ready"), result.output)
            assertBusy(home)
            lease.release()
            let next = try RuntimeMutationLease.acquire(home: home)
            next.release()
        }
    }
}
