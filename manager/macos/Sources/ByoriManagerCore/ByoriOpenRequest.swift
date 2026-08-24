import Foundation

/// A request from outside the app to open a repository.
///
/// `byori open` in a checkout hands `byori://project?root=<path>` to `open(1)`, which
/// launches or activates the app and delivers the URL. A folder dropped on the app,
/// or `open -a Byori <folder>`, arrives as a file URL and means the same thing.
///
/// Everything else is rejected rather than guessed. Opening the wrong directory is
/// not a cosmetic mistake here: an unknown root gets registered, and registering a
/// project assigns it a memory space.
public struct ByoriOpenRequest: Equatable, Sendable {
    public static let scheme = "byori"

    public let root: URL

    public init?(url: URL) {
        if url.isFileURL {
            guard !url.path.isEmpty, url.path.hasPrefix("/") else { return nil }
            root = url.standardizedFileURL
            return
        }
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // `project` is what the CLI sends; `open` is accepted because it is the verb
        // a person would try by hand.
        let action = (components.host ?? "").lowercased()
        guard action == "project" || action == "open" else { return nil }
        // A relative path would resolve against the app's working directory, which
        // has nothing to do with where the command was typed.
        guard let path = components.queryItems?.first(where: { $0.name == "root" })?.value,
              path.hasPrefix("/") else {
            return nil
        }
        root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// The URL a caller outside Swift should send. Kept here so the CLI's spelling and
    /// the app's parser cannot drift apart unnoticed.
    public static func url(forRoot root: URL) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "project"
        components.queryItems = [URLQueryItem(name: "root", value: root.standardizedFileURL.path)]
        return components.url
    }
}
