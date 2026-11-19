import Foundation
import Testing
@testable import Kippet

struct MCPServerTests {
    @Test func handshakeAndProtocolErrors() throws {
        let server = server()
        let initialize = try response(server, method: "initialize", params: [:])
        #expect(initialize["jsonrpc"] as? String == "2.0")
        #expect(initialize["id"] as? String == "request-1")
        let result = try #require(initialize["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect(result["serverInfo"] as? [String: String] == ["name": "kippet", "version": "1.2.3"])
        let capabilities = try #require(result["capabilities"] as? [String: [String: String]])
        #expect(capabilities == ["tools": [:]])
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).isEmpty)
        #expect(try response(server, method: "ping")["result"] as? [String: String] == [:])
        let unknown = try response(server, method: "unknown")
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        let unknownTool = try response(server, method: "tools/call", params: ["name": "unknown"])
        #expect((unknownTool["error"] as? [String: Any])?["code"] as? Int == -32602)
        let invalidLine = try #require(server.handle("{").first)
        let invalid = try #require(try decode(invalidLine) as? [String: Any])
        #expect((invalid["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    @Test func toolsListHasSchemasForAllTools() throws {
        let reply = try response(server(), method: "tools/list")
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let requiredKeys = [
            "search_clips": ["query"], "list_recent": [], "get_clip": ["id"], "list_pinboards": [],
            "list_pinboard_clips": ["pinboard_id"], "add_snippet": ["content"],
        ]
        #expect(Set(tools.compactMap { $0["name"] as? String }) == Set(requiredKeys.keys))
        #expect(tools.count == requiredKeys.count)
        for tool in tools {
            let name = try #require(tool["name"] as? String)
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["required"] as? [String] == requiredKeys[name])
            let properties = try #require(schema["properties"] as? [String: [String: Any]])
            if ["search_clips", "list_recent", "list_pinboard_clips"].contains(name) {
                #expect(properties["limit"]?["type"] as? String == "integer")
                #expect(properties["limit"]?["maximum"] as? Int == 50)
            }
            if name == "search_clips" {
                #expect(properties["kind"]?["enum"] as? [String] == ["text", "link", "image", "files"])
            }
        }
    }

    @Test func gateRejectsEveryToolCallBeforeAccessingHistoryOrSending() throws {
        let server = MCPServer(
            version: "1.2.3", access: { .init(snippetsEnabled: true) },
            loadHistory: { Issue.record("Read history with the gate off"); return ([], []) },
            sendSnippet: { _ in Issue.record("Sent a snippet with the gate off"); return true }
        )
        for tool in ["search_clips", "list_recent", "get_clip", "list_pinboards", "list_pinboard_clips", "add_snippet"] {
            let result = try call(server, tool)
            #expect(result["isError"] as? Bool == true)
            #expect(try content(result) == "Kippet 未开启 AI 访问，请在 设置 → 自动化 中打开")
        }
        let missing = try response(server, method: "tools/call")
        #expect((missing["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func searchReadsTheArchiveAgainAndAppliesKindAndLimit() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MCPServerTests-\(UUID())")
        let archive = ClipArchive(legacyURL: folder.appending(path: "History.plist"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = server(load: { try archive.load(readOnly: true) })
        let search: [String: Any] = ["query": " hello ", "kind": "text", "limit": 1]
        #expect(try items(call(server, "search_clips", search)).isEmpty)

        let link = Clip(id: UUID(), payload: .link("https://example.com/hello"), date: .now)
        let old = clip("hello earlier")
        let newest = clip("HELLO " + String(repeating: "字", count: 600),
                          source: "Editor", title: "备注")
        try archive.write(upserting: [link, newest, old], removing: [])

        let match = try #require(try items(call(server, "search_clips", search)).first)
        #expect(match["id"] as? String == newest.id.uuidString)
        #expect(match["date"] as? String == newest.date.ISO8601Format())
        #expect(match["kind"] as? String == "text")
        #expect(match["source_app"] as? String == "Editor")
        #expect(match["title"] as? String == "备注")
        #expect((match["preview"] as? String)?.count == 500)
        #expect(try items(call(server, "list_recent", ["limit": 2])).compactMap { $0["id"] as? String } ==
                [link.id.uuidString, newest.id.uuidString])
        let invalidLimits: [Any] = [51, 0, -1, 1.5, true, "2"]
        for invalid in invalidLimits {
            #expect(try call(server, "list_recent", ["limit": invalid])["isError"] as? Bool == true)
        }
        #expect(try call(server, "search_clips", ["query": "hello", "kind": "other"])["isError"] as? Bool == true)
    }

    @Test func sensitiveClipsAreHiddenFromEveryReadAndFromCounts() throws {
        let boardID = UUID()
        let visible = clip("included", board: boardID)
        let firstOnBoard = clip("first on board", board: boardID)
        var future = clip("expires later", board: boardID)
        future.expiresAt = Date.now.addingTimeInterval(120)
        var past = clip("expired", board: boardID)
        past.expiresAt = Date.now.addingTimeInterval(-120)
        let otp = clip("验证码 482913", board: boardID)
        let password = clip("password manager", bundleID: "com.apple.Passwords", board: boardID)
        let excluded = clip("excluded", bundleID: "test.excluded", board: boardID)
        let legacyExcluded = clip("old excluded", source: "Excluded App", board: boardID)
        let ruleMatch = clip("someone@example.com", board: boardID)
        let hidden = [future, past, otp, password, excluded, legacyExcluded, ruleMatch]
        let group = ClipGroup(id: boardID, name: "Board", cardOrder: [otp.id, firstOnBoard.id, visible.id])
        let skip = ClipRule(id: UUID(), name: "Skip detected email", isEnabled: true,
                            match: .init(detected: [.email]), action: .skip)
        let server = server(
            access: .init(enabled: true, excludedApps: [.init(id: "test.excluded", name: "Excluded App")],
                          rules: ClipRule.presets + [skip]),
            load: { (hidden + [visible, firstOnBoard], [group]) }
        )

        let expected = [visible.id.uuidString, firstOnBoard.id.uuidString]
        #expect(try items(call(server, "search_clips", ["query": ""])).compactMap { $0["id"] as? String } == expected)
        #expect(try items(call(server, "list_recent")).compactMap { $0["id"] as? String } == expected)
        let boards = try items(call(server, "list_pinboards"))
        #expect(boards.first?["count"] as? Int == 2)
        let members = try items(call(server, "list_pinboard_clips", ["pinboard_id": boardID.uuidString]))
        #expect(members.compactMap { $0["id"] as? String } == Array(expected.reversed()))
        #expect((members.first?["pinboards"] as? [[String: String]])?.first == ["id": boardID.uuidString, "name": "Board"])
        for clip in hidden {
            #expect(try call(server, "get_clip", ["id": clip.id.uuidString])["isError"] as? Bool == true)
        }
    }

    @Test func detailTruncatesUTF8AndOmitsRichTextAndImageBytes() throws {
        var text = clip(String(repeating: "a", count: 99_999) + "你好", title: "备注")
        text.payload = .text(text.payload.previewText, rtf: Data("raw RTF".utf8), html: Data("raw HTML".utf8))
        let imageBytes = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH+kAAAAASUVORK5CYII="))
        let image = Clip(id: UUID(), payload: .image(imageBytes, format: "public.png"), date: .now,
                         recognizedText: "Recognized words")
        let file = Clip(id: UUID(), payload: .files([URL(fileURLWithPath: "/tmp/a b.txt")]), date: .now)
        let link = Clip(id: UUID(), payload: .link("https://example.com/path"), date: .now)
        let server = server(load: { ([text, image, file, link], []) })

        let rawText = try content(call(server, "get_clip", ["id": text.id.uuidString]))
        let textDetail = try #require(try decode(rawText) as? [String: Any])
        #expect(textDetail["text"] as? String == String(repeating: "a", count: 99_999))
        #expect(textDetail["truncated"] as? Bool == true)
        #expect(textDetail["note"] as? String == "备注")
        #expect(!rawText.contains("raw RTF") && !rawText.contains("raw HTML"))

        let rawImage = try content(call(server, "get_clip", ["id": image.id.uuidString]))
        let imageDetail = try #require(try decode(rawImage) as? [String: Any])
        #expect(imageDetail["image_size"] as? [String: Int] == ["bytes": imageBytes.count, "width": 1, "height": 1])
        #expect(imageDetail["ocr_text"] as? String == "Recognized words")
        #expect(!rawImage.contains(imageBytes.base64EncodedString()))
        #expect(try items(call(server, "search_clips", ["query": "recognized", "kind": "image"])).count == 1)

        let fileDetail = try decode(content(call(server, "get_clip", ["id": file.id.uuidString]))) as? [String: Any]
        #expect(fileDetail?["file_paths"] as? [String] == ["/tmp/a b.txt"])
        let linkDetail = try decode(content(call(server, "get_clip", ["id": link.id.uuidString]))) as? [String: Any]
        #expect(linkDetail?["link"] as? String == "https://example.com/path")
    }

    @Test func addSnippetRequiresSeparatePermissionAndRunningApp() throws {
        let pinboardID = UUID()
        let arguments = ["title": "标题", "content": "正文\n", "pinboard_id": pinboardID.uuidString]
        let disabled = server(send: { _ in Issue.record("Sent with writes off"); return true })
        #expect(try call(disabled, "add_snippet", arguments)["isError"] as? Bool == true)

        var sent: MCPServer.Snippet?
        var appRunning = false
        let enabled = server(access: .init(enabled: true, snippetsEnabled: true), load: {
            Issue.record("A write request should not open the archive"); return ([], [])
        }, send: {
            sent = $0
            return appRunning
        })
        let failure = try call(enabled, "add_snippet", arguments)
        #expect(failure["isError"] as? Bool == true)
        #expect(try content(failure) == "Kippet 未运行，请先打开 Kippet")

        appRunning = true
        #expect(try content(call(enabled, "add_snippet", arguments)) == "已发送给 Kippet")
        #expect(sent?.title == "标题")
        #expect(sent?.content == "正文\n")
        #expect(sent?.pinboardID == pinboardID)

        sent = nil
        #expect(try call(enabled, "add_snippet", ["content": " \n"])["isError"] as? Bool == true)
        #expect(try call(enabled, "add_snippet", ["content": "text", "title": String(repeating: "字", count: 121)])["isError"] as? Bool == true)
        #expect(try call(enabled, "add_snippet", ["content": "text", "pinboard_id": "invalid"])["isError"] as? Bool == true)
        #expect(sent == nil)
    }

    private func server(
        access: MCPServer.Access = .init(enabled: true),
        load: @escaping () throws -> (clips: [Clip], groups: [ClipGroup]) = { ([], []) },
        send: @escaping (MCPServer.Snippet) -> Bool = { _ in false }
    ) -> MCPServer {
        MCPServer(version: "1.2.3", access: { access }, loadHistory: load, sendSnippet: send)
    }

    private func clip(
        _ text: String, source: String? = nil, bundleID: String? = nil, title: String? = nil, board: UUID? = nil
    ) -> Clip {
        Clip(id: UUID(), payload: .text(text, rtf: nil, html: nil), date: .now,
             sourceName: source, groupIDs: board.map { [$0] }, sourceBundleIdentifier: bundleID, title: title)
    }

    private func response(_ server: MCPServer, method: String, params: [String: Any]? = nil) throws -> [String: Any] {
        var request: [String: Any] = ["jsonrpc": "2.0", "id": "request-1", "method": method]
        request["params"] = params
        let data = try JSONSerialization.data(withJSONObject: request)
        let lines = server.handle(String(decoding: data, as: UTF8.self))
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(!line.contains("\n"))
        return try #require(try decode(line) as? [String: Any])
    }

    private func call(_ server: MCPServer, _ tool: String, _ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let reply = try response(server, method: "tools/call", params: ["name": tool, "arguments": arguments])
        return try #require(reply["result"] as? [String: Any])
    }

    private func content(_ result: [String: Any]) throws -> String {
        let block = try #require((result["content"] as? [[String: String]])?.first)
        #expect(block["type"] == "text")
        return try #require(block["text"])
    }

    private func items(_ result: [String: Any]) throws -> [[String: Any]] {
        try #require(try decode(content(result)) as? [[String: Any]])
    }

    private func decode(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8))
    }
}
