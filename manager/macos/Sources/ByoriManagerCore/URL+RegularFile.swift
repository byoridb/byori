import Foundation

extension URL {
    /// A regular file that is not itself a symbolic link. Callers that read
    /// files found under a user's home use this so a link cannot redirect the
    /// read elsewhere; their own containment and size checks stay with them.
    var isUnlinkedRegularFile: Bool {
        guard let values = try? resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
