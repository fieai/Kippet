import Foundation
import Testing
@testable import Kippet

struct ShelfAutomationTests {
    @Test func configAndCommandUseTheActualExecutablePath() throws {
        let path = "/Applications/My Kippet.app/Contents/MacOS/Kippet"
        let config = try #require(ShelfAutomation.mcpConfig(executablePath: path))
        let json = try #require(JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any])
        let servers = try #require(json["mcpServers"] as? [String: [String: Any]])
        #expect(servers["kippet"]?["command"] as? String == path)
        #expect(servers["kippet"]?["args"] as? [String] == ["--mcp"])
        #expect(ShelfAutomation.claudeCommand(executablePath: path) == "claude mcp add kippet -- \"\(path)\" --mcp")
        #expect(ShelfAutomation.claudeCommand(executablePath: "/tmp/$test's") ==
                "claude mcp add kippet -- '/tmp/$test'\\''s' --mcp")
    }
}
