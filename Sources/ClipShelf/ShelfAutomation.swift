import Foundation

enum ShelfAutomation {
    static let bundleID = "com.clipshelf.macos"
    static let addSnippetNotification = Notification.Name("\(bundleID).addSnippet")
    static let mcpEnabled = "mcpEnabled"
    static let mcpSnippetsEnabled = "mcpSnippetsEnabled"
    static let urlCopyEnabled = "urlCopyEnabled"

    static func mcpConfig(executablePath: String) -> String? {
        let config = ["mcpServers": ["clipshelf": ["command": executablePath, "args": ["--mcp"]] as [String: Any]]]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func claudeCommand(executablePath: String) -> String {
        let path: String
        if executablePath.contains(where: { "\"\\$`!".contains($0) }) {
            path = "'" + executablePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        } else {
            path = "\"\(executablePath)\""
        }
        return "claude mcp add clipshelf -- \(path) --mcp"
    }
}
