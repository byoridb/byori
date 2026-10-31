import Darwin
import Foundation

public enum RuntimeMutationLeaseError: LocalizedError, Equatable, Sendable {
    case busy
    case unsafe(String)
    case io(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .busy:
            return "Runtime mutation is already in progress. Try again after it finishes."
        case let .unsafe(reason):
            return "Unsafe runtime mutation lease: \(reason)."
        case let .io(operation, code):
            return "Runtime mutation lease \(operation) failed (errno \(code))."
        }
    }
}

/// An OS-lifetime lease. The caller must keep this object alive until all work
/// (including rollback) and any descriptor transfer have finished.
public final class RuntimeMutationLease: @unchecked Sendable {
    private let mutex = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Returns -1 after release. Concurrent release is safe, but consumers must
    /// coordinate their use/duplication of this borrowed descriptor with release.
    public var fileDescriptor: Int32 {
        mutex.lock()
        defer { mutex.unlock() }
        return descriptor
    }

    public func release() {
        mutex.lock()
        defer { mutex.unlock() }
        if descriptor >= 0 {
            // LOCK_UN would also unlock descriptors transported to a child.
            // Closing leaves ownership with the last open-description reference.
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }

    public static func acquire(home: URL) throws -> RuntimeMutationLease {
        guard home.isFileURL else {
            throw RuntimeMutationLeaseError.unsafe("root must be a file URL")
        }
        let requested = home.standardizedFileURL
        guard !requested.path.utf8.contains(0) else {
            throw RuntimeMutationLeaseError.unsafe("root contains a NUL byte")
        }
        let canonical = requested.resolvingSymlinksInPath()
        let userHome = try actualUserHome().resolvingSymlinksInPath()
        guard canonical.path != "/",
              canonical.path != userHome.path else {
            throw RuntimeMutationLeaseError.unsafe("root is a protected directory")
        }

        var pathRoot = stat()
        if lstat(requested.path, &pathRoot) != 0 {
            guard errno == ENOENT else { throw io("inspect root") }
            if mkdir(requested.path, 0o700) != 0, errno != EEXIST {
                throw io("create root")
            }
            guard lstat(requested.path, &pathRoot) == 0 else { throw io("inspect root") }
        }
        var homeIdentity = stat()
        if stat(userHome.path, &homeIdentity) == 0, sameIdentity(pathRoot, homeIdentity) {
            // Also cover alternate spelling on case-insensitive filesystems.
            throw RuntimeMutationLeaseError.unsafe("root is a protected directory")
        }
        try validate(pathRoot, directory: true)
        let rootFD = open(requested.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw io("open root") }
        defer { close(rootFD) }
        var openedRoot = stat()
        guard fstat(rootFD, &openedRoot) == 0 else { throw io("inspect opened root") }
        try validate(openedRoot, directory: true)
        guard sameIdentity(pathRoot, openedRoot) else {
            throw RuntimeMutationLeaseError.unsafe("root identity changed")
        }

        let lockName = ".runtime-mutation.lock"
        var existingLock = stat()
        if fstatat(rootFD, lockName, &existingLock, AT_SYMLINK_NOFOLLOW) == 0 {
            try validate(existingLock, directory: false)
        } else if errno != ENOENT {
            throw io("inspect lock")
        }
        var fd = openat(rootFD, lockName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0, errno == EEXIST {
            fd = openat(rootFD, lockName, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard fd >= 0 else {
            if errno == ELOOP {
                throw RuntimeMutationLeaseError.unsafe("lock must not be a symlink")
            }
            throw io("open lock")
        }
        var transferred = false
        defer { if !transferred { close(fd) } }
        var openedLock = stat()
        guard fstat(fd, &openedLock) == 0 else { throw io("inspect opened lock") }
        try validate(openedLock, directory: false)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw RuntimeMutationLeaseError.busy
            }
            throw io("lock")
        }

        var currentLock = stat()
        var currentRoot = stat()
        var currentOpenedLock = stat()
        guard fstatat(rootFD, lockName, &currentLock, AT_SYMLINK_NOFOLLOW) == 0,
              lstat(requested.path, &currentRoot) == 0,
              fstat(fd, &currentOpenedLock) == 0 else { throw io("verify lease identity") }
        try validate(currentLock, directory: false)
        try validate(currentOpenedLock, directory: false)
        try validate(currentRoot, directory: true)
        guard sameIdentity(openedLock, currentLock),
              sameIdentity(openedLock, currentOpenedLock),
              sameIdentity(openedRoot, currentRoot),
              requested.resolvingSymlinksInPath().path == canonical.path else {
            throw RuntimeMutationLeaseError.unsafe("lease path identity changed")
        }
        transferred = true
        return RuntimeMutationLease(descriptor: fd)
    }

    private static func validate(_ info: stat, directory: Bool) throws {
        let kind = info.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(directory ? S_IFDIR : S_IFREG) else {
            throw RuntimeMutationLeaseError.unsafe(directory
                ? "root must be a real directory" : "lock must be a regular file")
        }
        guard info.st_uid == geteuid() else {
            throw RuntimeMutationLeaseError.unsafe(directory
                ? "root must belong to the current user" : "lock must belong to the current user")
        }
        // Exact permissions, including setuid/setgid/sticky bits. Merely
        // excluding group/other access would admit unusable or special modes.
        let permissions = info.st_mode & mode_t(0o7777)
        let requiredPermissions = mode_t(directory ? 0o700 : 0o600)
        guard permissions == requiredPermissions else {
            throw RuntimeMutationLeaseError.unsafe(directory
                ? "root must have mode 0700" : "lock must have mode 0600")
        }
        if !directory, info.st_nlink != 1 {
            throw RuntimeMutationLeaseError.unsafe("lock must have exactly one link")
        }
    }

    private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    /// Consult the account database, not a potentially overridden HOME value.
    private static func actualUserHome() throws -> URL {
        var capacity = max(16_384, Int(sysconf(_SC_GETPW_R_SIZE_MAX)))
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let (status, path): (Int32, String?) = buffer.withUnsafeMutableBufferPointer {
                var entry = passwd()
                var result: UnsafeMutablePointer<passwd>?
                let status = getpwuid_r(geteuid(), &entry, $0.baseAddress, $0.count, &result)
                guard status == 0, result != nil, let directory = entry.pw_dir else {
                    return (status, nil)
                }
                // Copy pw_dir while its backing buffer pointer is valid.
                return (status, String(cString: directory))
            }
            if status == ERANGE, capacity < 1_048_576 {
                capacity *= 2
                continue
            }
            guard status == 0, let path else {
                throw RuntimeMutationLeaseError.io(operation: "resolve current user home",
                                                   code: status == 0 ? ENOENT : status)
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    private static func io(_ operation: String) -> RuntimeMutationLeaseError {
        .io(operation: operation, code: errno)
    }
}
