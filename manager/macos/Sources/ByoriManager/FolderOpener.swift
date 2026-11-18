import AppKit
import Foundation

/// Opens Byori's folders and config files in the Finder, creating a missing
/// folder first. Each call returns why it could not, or nil: a folder that
/// could not be created, or an open the system refused, used to end in a click
/// that did nothing and said nothing.
@MainActor
struct FolderOpener {
    var fileManager: FileManager = .default
    var open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }

    func openDirectory(_ url: URL) -> String? {
        if let failure = prepare(url) { return failure }
        return openItem(url)
    }

    /// Opens the file when it exists. Otherwise shows the folder it would be
    /// created in, creating that folder if needed.
    func openFileOrRevealFolder(_ url: URL) -> String? {
        if fileManager.fileExists(atPath: url.path) {
            return openItem(url)
        }
        let directory = url.deletingLastPathComponent()
        if let failure = prepare(directory) { return failure }
        reveal([directory])
        return nil
    }

    func openItem(_ url: URL) -> String? {
        open(url) ? nil : "열 수 없습니다: \(url.path)"
    }

    private func prepare(_ directory: URL) -> String? {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return nil
        } catch {
            return "\(directory.path) 폴더를 만들 수 없습니다: \(error.localizedDescription)"
        }
    }
}
