import CoreFoundation
import Foundation
import ImageIO

struct MCPServer {
    struct Access {
        var enabled = false
        var snippetsEnabled = false
        var excludedApps: [ExcludedApp] = []
        var rules = ClipRule.presets

        func permits(_ clip: Clip) -> Bool {
            guard clip.expiresAt == nil, !excludedApps.contains(where: { app in
                if let bundleID = clip.sourceBundleIdentifier { return app.id == bundleID }
                return app.name == clip.sourceName
            }) else { return false }
            let detected: DetectedContent?
            if case let .text(text, _, _) = clip.storedPayload, text.utf8.count <= DetectionCache.maxTextBytes {
                detected = ContentDetector.detect(text, sourceBundleIdentifier: clip.sourceBundleIdentifier)
            } else {
                detected = nil
            }
            return detected?.kind != .oneTimeCode &&
                !RuleEngine.actions(for: clip, detected: detected, rules: rules).contains(.skip)
        }
    }

    struct Snippet {
        let title: String
        let content: String
        let pinboardID: UUID?
    }

    let version: String
    let access: () -> Access
    let loadHistory: () throws -> (clips: [Clip], groups: [ClipGroup])
    let sendSnippet: (Snippet) -> Bool

    func handle(_ line: String) -> [String] {
        let message: Any
        do {
            message = try JSONSerialization.jsonObject(with: Data(line.utf8), options: .fragmentsAllowed)
        } catch {
            return Self.reply(id: NSNull(), error: -32700, message: "Parse error")
        }
        guard let request = message as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String, Self.validID(request["id"])
        else { return Self.reply(id: NSNull(), error: -32600, message: "Invalid Request") }
        guard let id = request["id"] else { return [] }

        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": "2025-06-18",
                "serverInfo": ["name": "kippet", "version": version],
                "capabilities": ["tools": [String: Any]()],
            ]
        case "notifications/initialized", "ping":
            result = [:]
        case "tools/list":
            result = ["tools": Tool.allCases.map(\.definition)]
        case "tools/call":
            let access = access()
            if !access.enabled {
                result = Self.toolError(L("Kippet 未开启 AI 访问，请在 设置 → 自动化 中打开"))
            } else if let params = request["params"] as? [String: Any], let name = params["name"] as? String,
                      let tool = Tool(rawValue: name), let arguments = (params["arguments"] ?? [:]) as? [String: Any] {
                result = call(tool, arguments: arguments, access: access)
            } else {
                return Self.reply(id: id, error: -32602, message: L("未知的 Kippet 工具或参数无效"))
            }
        default:
            return Self.reply(id: id, error: -32601, message: "Method not found")
        }
        return Self.encode(["jsonrpc": "2.0", "id": id, "result": result]).map { [$0] }
            ?? Self.reply(id: id, error: -32603, message: "Internal error")
    }

    private func call(_ tool: Tool, arguments: [String: Any], access: Access) -> [String: Any] {
        do {
            if tool == .addSnippet { return try addSnippet(arguments, allowed: access.snippetsEnabled) }
            let payload = try read(tool, arguments: arguments, access: access)
            guard let json = Self.encode(payload) else { return Self.toolError(L("无法生成 Kippet 响应")) }
            return Self.toolResult(json)
        } catch let error as ToolError {
            return Self.toolError(error.message)
        } catch {
            return Self.toolError(L("无法读取 Kippet 历史"))
        }
    }

    private func read(_ tool: Tool, arguments: [String: Any], access: Access) throws -> Any {
        let snapshot = try loadHistory()
        let clips = snapshot.clips.filter(access.permits)
        let groups = snapshot.groups

        switch tool {
        case .searchClips:
            guard let query = arguments["query"] as? String else { throw ToolError.invalidArguments }
            let kind = (arguments["kind"] as? String).flatMap(ClipKind.init(rawValue:))
            if arguments["kind"] != nil, kind == nil { throw ToolError.invalidArguments }
            let limit = try Self.limit(arguments)
            let filter = HistoryFilter(
                search: query.trimmingCharacters(in: .whitespacesAndNewlines),
                contentType: kind.map(HistoryContentType.kind), favoritesOnly: false,
                sourceName: nil, groupID: nil, sourceBundleIdentifier: nil, locale: .current
            )
            return Array(clips.lazy.filter(filter.includes).prefix(limit).map { Self.summary($0, groups: groups) })
        case .listRecent:
            return try clips.prefix(Self.limit(arguments)).map { Self.summary($0, groups: groups) }
        case .getClip:
            let id = try Self.uuid("id", in: arguments)
            guard let clip = clips.first(where: { $0.id == id }) else { throw ToolError.missingClip }
            return Self.detail(clip, groups: groups)
        case .listPinboards:
            var counts: [UUID: Int] = [:]
            for clip in clips {
                for id in clip.groupIDs ?? [] { counts[id, default: 0] += 1 }
            }
            return groups.map { ["id": $0.id.uuidString, "name": $0.name, "count": counts[$0.id, default: 0]] }
        case .listPinboardClips:
            let id = try Self.uuid("pinboard_id", in: arguments)
            let limit = try Self.limit(arguments)
            guard let group = groups.first(where: { $0.id == id }) else { throw ToolError.missingPinboard }
            let members = clips.filter { $0.groupIDs?.contains(id) == true }
            return group.ordered(members).prefix(limit).map { Self.summary($0, groups: groups) }
        case .addSnippet:
            throw ToolError.invalidArguments
        }
    }

    private func addSnippet(_ arguments: [String: Any], allowed: Bool) throws -> [String: Any] {
        guard allowed else { return Self.toolError(L("Kippet 未允许 AI 新建片段，请在 设置 → 自动化 中打开")) }
        let title = (arguments["title"] ?? "") as? String
        guard let title, let content = arguments["content"] as? String,
              ClipboardStore.isValidSnippet(title: title, content: content)
        else { throw ToolError.invalidArguments }
        let pinboardID = try arguments["pinboard_id"].map { _ in try Self.uuid("pinboard_id", in: arguments) }
        guard sendSnippet(Snippet(title: title, content: content, pinboardID: pinboardID)) else {
            return Self.toolError(L("Kippet 未运行，请先打开 Kippet"))
        }
        return Self.toolResult(L("已发送给 Kippet"))
    }

    private static func summary(_ clip: Clip, groups: [ClipGroup]) -> [String: Any] {
        let preview = clip.storedPayload.kind == .image ? clip.recognizedText ?? clip.storedPayload.previewText
            : clip.storedPayload.previewText
        return [
            "id": clip.id.uuidString,
            "date": clip.date.ISO8601Format(),
            "kind": clip.storedPayload.kind.rawValue,
            "source_app": clip.source?.name as Any? ?? NSNull(),
            "title": clip.title as Any? ?? NSNull(),
            "preview": String(preview.prefix(500)),
            "pinboards": groups.compactMap { group in
                clip.groupIDs?.contains(group.id) == true ? ["id": group.id.uuidString, "name": group.name] : nil
            },
        ]
    }

    private static func detail(_ clip: Clip, groups: [ClipGroup]) -> [String: Any] {
        var result = summary(clip, groups: groups)
        result["note"] = clip.title as Any? ?? NSNull()
        result["ocr_text"] = clip.recognizedText as Any? ?? NSNull()
        result["truncated"] = false
        switch clip.storedPayload {
        case let .text(text, _, _):
            let truncated = text.utf8.count > 100_000
            result["text"] = truncated ? textPrefix(text, bytes: 100_000) : text
            result["truncated"] = truncated
        case let .link(link):
            result["link"] = link
        case let .files(urls):
            result["file_paths"] = urls.map(\.path)
        case .image:
            break
        }
        if clip.hasPreviewImage, let reference = clip.snapshotBlob ?? clip.imageBlob {
            var size = ["bytes": reference.byteCount]
            size["width"] = reference.width
            size["height"] = reference.height
            result["image_size"] = size
        } else if clip.hasPreviewImage, let image = try? clip.readPreviewImage() {
            let data = image.data
            var size = ["bytes": data.count]
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                size["width"] = width
                size["height"] = height
            }
            result["image_size"] = size
        }
        return result
    }

    private static func textPrefix(_ text: String, bytes: Int) -> String {
        let utf8 = text.utf8
        var end = utf8.index(utf8.startIndex, offsetBy: bytes)
        while utf8[end] & 0xC0 == 0x80 { utf8.formIndex(before: &end) }
        return String(decoding: utf8[..<end], as: UTF8.self)
    }

    private static func limit(_ arguments: [String: Any]) throws -> Int {
        guard let raw = arguments["limit"] else { return 50 }
        guard validNumber(raw), let limit = raw as? Int, (1...50).contains(limit) else {
            throw ToolError.invalidArguments
        }
        return limit
    }

    private static func uuid(_ key: String, in arguments: [String: Any]) throws -> UUID {
        guard let value = arguments[key] as? String, let id = UUID(uuidString: value) else {
            throw ToolError.invalidArguments
        }
        return id
    }

    private static func validID(_ id: Any?) -> Bool {
        guard let id else { return true }
        return id is String || id is NSNull || validNumber(id)
    }

    private static func validNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    private static func toolError(_ message: String) -> [String: Any] {
        toolResult(message, isError: true)
    }

    private static func toolResult(_ message: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": isError]
    }

    private static func reply(id: Any, error code: Int, message: String) -> [String] {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]).map { [$0] } ?? []
    }

    private static func encode(_ value: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private enum Tool: String, CaseIterable {
        case searchClips = "search_clips"
        case listRecent = "list_recent"
        case getClip = "get_clip"
        case listPinboards = "list_pinboards"
        case listPinboardClips = "list_pinboard_clips"
        case addSnippet = "add_snippet"

        var definition: [String: Any] {
            let description: String
            let properties: [String: [String: Any]]
            let required: [String]
            let string = ["type": "string"]
            let uuid = ["type": "string", "format": "uuid"]
            let limit: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 50, "default": 50]
            switch self {
            case .searchClips:
                description = "Search Kippet clipboard history."
                properties = ["query": string, "kind": ["type": "string", "enum": ClipKind.allCases.map(\.rawValue)],
                              "limit": limit]
                required = ["query"]
            case .listRecent:
                description = "List the most recent Kippet clips."
                properties = ["limit": limit]
                required = []
            case .getClip:
                description = "Read a Kippet clip by ID."
                properties = ["id": uuid]
                required = ["id"]
            case .listPinboards:
                description = "List Kippet pinboards and their visible clip counts."
                properties = [:]
                required = []
            case .listPinboardClips:
                description = "List clips on a Kippet pinboard in their board order."
                properties = ["pinboard_id": uuid, "limit": limit]
                required = ["pinboard_id"]
            case .addSnippet:
                description = "Send a new snippet to the running Kippet app."
                properties = ["title": string, "content": string, "pinboard_id": uuid]
                required = ["content"]
            }
            return [
                "name": rawValue, "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required],
            ]
        }
    }

    private enum ToolError: Error {
        case invalidArguments, missingClip, missingPinboard

        var message: String {
            switch self {
            case .invalidArguments: L("工具参数无效")
            case .missingClip: L("找不到此卡片")
            case .missingPinboard: L("找不到此钉板")
            }
        }
    }
}
