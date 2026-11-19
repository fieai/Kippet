import AppKit
import Foundation

enum MCPStdio {
    @MainActor
    static func run() {
        let defaults = UserDefaults(suiteName: ShelfAutomation.bundleID)
        let server = MCPServer(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
            access: {
                guard let defaults else { return .init() }
                return ShelfPreferences.mcpAccess(from: defaults, domain: ShelfAutomation.bundleID)
            },
            loadHistory: { try ClipArchive.live.load(readOnly: true) },
            sendSnippet: sendSnippet
        )
        while let line = readLine() {
            for output in server.handle(line) {
                do {
                    try FileHandle.standardOutput.write(contentsOf: Data((output + "\n").utf8))
                } catch {
                    return
                }
            }
        }
    }

    @MainActor
    private static func sendSnippet(_ snippet: MCPServer.Snippet) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard NSRunningApplication.runningApplications(withBundleIdentifier: ShelfAutomation.bundleID)
            .contains(where: {
                $0.processIdentifier != pid && $0.isFinishedLaunching && !$0.isTerminated &&
                    $0.activationPolicy != .prohibited
            })
        else { return false }

        var userInfo = ["title": snippet.title, "content": snippet.content]
        userInfo["pinboard"] = snippet.pinboardID?.uuidString
        DistributedNotificationCenter.default().postNotificationName(
            ShelfAutomation.addSnippetNotification, object: nil, userInfo: userInfo, deliverImmediately: true
        )
        return true
    }
}
