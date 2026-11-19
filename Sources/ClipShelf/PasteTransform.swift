import Foundation

enum PasteTransform: String, CaseIterable, Identifiable, Codable, Sendable {
    case trimWhitespace, collapseWhitespace, removeLineBreaks, removeBlankLines
    case uppercase, lowercase, capitalized
    case sortLines, dedupeLines
    case jsonPretty, jsonMinify, cleanURL, urlEncode, urlDecode, base64Encode, base64Decode

    enum Section: CaseIterable {
        case cleanup, `case`, lines, developer
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trimWhitespace: "去除首尾空白"
        case .collapseWhitespace: "合并多余空白"
        case .removeLineBreaks: "合并为一行"
        case .removeBlankLines: "删除空行"
        case .uppercase: "全部大写"
        case .lowercase: "全部小写"
        case .capitalized: "单词首字母大写"
        case .sortLines: "按行排序"
        case .dedupeLines: "删除重复行"
        case .jsonPretty: "JSON 格式化"
        case .jsonMinify: "JSON 压缩"
        case .cleanURL: "清除链接追踪参数"
        case .urlEncode: "URL 编码"
        case .urlDecode: "URL 解码"
        case .base64Encode: "Base64 编码"
        case .base64Decode: "Base64 解码"
        }
    }

    var section: Section {
        switch self {
        case .trimWhitespace, .collapseWhitespace, .removeLineBreaks, .cleanURL: .cleanup
        case .uppercase, .lowercase, .capitalized: .case
        case .removeBlankLines, .sortLines, .dedupeLines: .lines
        case .jsonPretty, .jsonMinify, .urlEncode, .urlDecode, .base64Encode, .base64Decode: .developer
        }
    }

    func apply(to text: String) -> String? {
        switch self {
        case .trimWhitespace:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .collapseWhitespace:
            return Self.lines(in: text).map(Self.collapsed).joined(separator: "\n")
        case .removeLineBreaks:
            return Self.collapsed(text)
        case .removeBlankLines:
            return Self.lines(in: text).filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: "\n")
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .capitalized:
            return text.capitalized
        case .sortLines:
            return Self.lines(in: text).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .joined(separator: "\n")
        case .dedupeLines:
            var seen: Set<Substring> = []
            return Self.lines(in: text).filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .jsonPretty, .jsonMinify:
            var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
            if self == .jsonPretty { options.insert(.prettyPrinted) }
            guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed),
                  let data = try? JSONSerialization.data(withJSONObject: json, options: options),
                  let result = String(data: data, encoding: .utf8), result != text else { return nil }
            return result
        case .cleanURL:
            return Self.cleanURLs(in: text)
        case .urlEncode:
            return text.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?"))
            )
        case .urlDecode:
            return text.removingPercentEncoding
        case .base64Encode:
            return Data(text.utf8).base64EncodedString()
        case .base64Decode:
            guard let data = Data(base64Encoded: text) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    private static func lines(in text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    private static func collapsed(_ text: some StringProtocol) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid",
        "spm", "scm", "from", "share_source", "share_medium", "ref_src", "ref_url",
    ]

    private static func cleanURLs(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let result = NSMutableString(string: text)
        let original = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: original.length))
        for match in matches.reversed() {
            guard let host = match.url?.host?.lowercased(),
                  var url = URLComponents(string: original.substring(with: match.range)),
                  let items = url.percentEncodedQueryItems else { continue }
            let kept = items.filter { item in
                let name = (item.name.removingPercentEncoding ?? item.name).lowercased()
                if name.hasPrefix("utm_") || trackingNames.contains(name) { return false }
                if name == "si" {
                    return !["youtube.com", "youtu.be", "open.spotify.com"].contains { belongs(host, to: $0) }
                }
                if name == "vd_source" { return !["bilibili.com", "b23.tv"].contains { belongs(host, to: $0) } }
                return true
            }
            guard kept.isEmpty || kept.count < items.count else { continue }
            url.percentEncodedQueryItems = kept.isEmpty ? nil : kept
            if let replacement = url.string { result.replaceCharacters(in: match.range, with: replacement) }
        }
        let cleaned = result as String
        return cleaned == text ? nil : cleaned
    }

    private static func belongs(_ host: String, to domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}
