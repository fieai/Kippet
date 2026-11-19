import Foundation
import Testing
@testable import ClipShelf

struct ShelfAutomationTests {
    @Test func configAndCommandUseTheActualExecutablePath() throws {
        let path = "/Applications/My TapV.app/Contents/MacOS/ClipShelf"
        let config = try #require(ShelfAutomation.mcpConfig(executablePath: path))
        let json = try #require(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let servers = try #require(json["mcpServers"] as? [String: [String: Any]])
        #expect(servers["clipshelf"]?["command"] as? String == path)
        #expect(servers["clipshelf"]?["args"] as? [String] == ["--mcp"])
        #expect(ShelfAutomation.claudeCommand(executablePath: path) == "claude mcp add clipshelf -- \"\(path)\" --mcp")
        #expect(ShelfAutomation.claudeCommand(executablePath: "/tmp/$test's") ==
                "claude mcp add clipshelf -- '/tmp/$test'\\''s' --mcp")
    }
}
