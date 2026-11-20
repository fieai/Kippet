import Foundation
import Testing
@testable import Kippet

struct LocalizationTests {
    @Test func englishStringsPreserveFormatPlaceholders() throws {
        let translations = try englishStrings()
        #expect(!translations.isEmpty)
        for (key, value) in translations.sorted(by: { $0.key < $1.key }) {
            let sourceFormats = Self.formats(in: key)
            let englishFormats = Self.formats(in: value)
            #expect(!value.isEmpty, "Empty translation for \(key)")
            #expect(!sourceFormats.contains("%") && !englishFormats.contains("%"),
                    "Unsupported format in \(key) → \(value)")
            #expect(sourceFormats == englishFormats, "Format mismatch in \(key) → \(value)")
        }
    }

    @Test func fallbackUsesChineseKeysAndFormatsTheirArguments() {
        #expect(L("此条目使用原文") == "此条目使用原文")
        #expect(L("粘贴栈 · %lld 项", 3) == "粘贴栈 · 3 项")
        #expect(L("%@ 已用于「%@」。", "⌘N", "新建片段") == "⌘N 已用于「新建片段」。")
    }

    @Test func chineseSourceStringsAreLocalized() throws {
        let translations = try englishStrings()
        let directory = Self.root.appending(path: "Sources/Kippet")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var uncovered: [String] = []
        for file in files.filter({ $0.pathExtension == "swift" }).sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in Self.sourceTokens.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range(at: 2), in: source),
                      let token = Range(match.range, in: source) else { continue }
                let quoted = source[range]
                let delimiterLength = quoted.hasPrefix("\"\"\"") ? 3 : 1
                let literal = String(quoted.dropFirst(delimiterLength).dropLast(delimiterLength))
                guard literal.range(of: #"\p{sc=Han}|[、，。：！？「」『』（）]"#, options: .regularExpression) != nil else {
                    continue
                }

                let filename = file.lastPathComponent
                let prefix = source[..<token.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let lookup: String?
                if prefix.hasSuffix("L(") || Self.indirectKeys[filename]?.contains(literal) == true {
                    lookup = literal
                } else if prefix.range(of: Self.swiftUILocalizedArgument, options: .regularExpression) != nil {
                    lookup = Self.swiftUIInterpolationKeys[literal] ?? literal
                } else {
                    if Self.nonDisplayStrings[filename]?.contains(literal) == true { continue }
                    lookup = nil
                }
                if lookup.flatMap({ translations[$0] }) == nil {
                    let line = source[..<range.lowerBound].filter(\.isNewline).count + 1
                    uncovered.append("\(filename):\(line) \(quoted)")
                }
            }
        }
        #expect(uncovered.isEmpty, "Untranslated Swift strings:\n\(uncovered.joined(separator: "\n"))")
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func englishStrings() throws -> [String: String] {
        let url = Self.root.appending(path: "Resources/Localization/en.lproj/Localizable.strings")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: String])
    }

    private static func formats(in text: String) -> [String] {
        text.matches(of: /%%|%@|%lld|%/).map { String($0.output) }.filter { $0 != "%%" }
    }

    // The string capture follows both comment alternatives, which are skipped.
    private static let sourceTokens = try! NSRegularExpression(
        pattern: #"//[^\n]*|/\*[\s\S]*?\*/|(#*)("""[\s\S]*?"""|"(?:\\[\s\S]|[^"\\])*")\1"#
    )
    private static let swiftUILocalizedArgument =
        #"\b(?:Text|Button|Label|Section|Toggle|Picker|Menu|Link|ProgressView|LabeledContent|TextField|alert|help|accessibilityLabel)\($"#

    // SwiftUI's LocalizedStringKey retains the live relative date and number formatting.
    private static let swiftUIInterpolationKeys = [
        #"\(Text(clip.date, style: .relative))前"#: "%@前",
        #"已选 \(selection.count) 项"#: "已选 %lld 项",
    ]
    // Stored preset and enum names are passed to the lookup when displayed.
    private static let indirectKeys: [String: Set<String>] = [
        "ClipRule.swift": ["颜色", "验证码 2 分钟后删除", "密码管理器内容不记录", "颜色归入『颜色』钉板"],
        "ContentDetector.swift": ["其他"],
    ]
    // Stable image search token, detection pattern, and persisted sync-name suffix.
    private static let nonDisplayStrings: [String: Set<String>] = [
        "Clip.swift": ["图片"],
        "ContentDetector.swift": ["验证码|校验码|动态码|确认码|代码"],
        "SyncMerge.swift": [#"（\(number)）"#],
    ]
}
