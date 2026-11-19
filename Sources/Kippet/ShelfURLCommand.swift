import Foundation

enum ShelfURLCommand: Equatable, Sendable {
    case open
    case search(String)
    case stack
    case newSnippet(text: String, title: String, pinboard: String?)
    case copy(index: Int)

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme.map({ ["kippet", LegacyMigration.urlScheme].contains($0.lowercased()) }) == true,
              parts.user == nil, parts.password == nil, parts.port == nil
        else { return nil }

        func value(_ name: String) -> String? {
            parts.queryItems?.first { $0.name == name }?.value
        }

        switch (parts.host?.lowercased(), parts.path) {
        case ("open", ""): self = .open
        case ("search", ""): self = .search(value("q") ?? "")
        case ("stack", ""): self = .stack
        case ("snippet", "/new"):
            self = .newSnippet(text: value("text") ?? "", title: value("title") ?? "", pinboard: value("pinboard"))
        case ("copy", ""):
            guard let raw = value("index"), let index = Int(raw), index > 0 else { return nil }
            self = .copy(index: index)
        default: return nil
        }
    }
}
