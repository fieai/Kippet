import Foundation
import Testing
@testable import ClipShelf

struct ContentDetectorTests {
    @Test(arguments: [
        (" #14B8A6\n", "#14B8A6", "#14B8A6"),
        ("#f0a", "#f0a", "#FF00AA"),
        ("#f0a8", "#f0a8", "#FF00AA88"),
        ("#14b8a680", "#14b8a680", "#14B8A680"),
        ("RGB ( 20, 184, 166 )", "RGB ( 20, 184, 166 )", "#14B8A6"),
        ("rgba(100%, 0%, 0%, 50%)", "rgba(100%, 0%, 0%, 50%)", "#FF000080"),
        ("rgb(20 184 166 / 0.5)", "rgb(20 184 166 / 0.5)", "#14B8A680"),
        ("hsl(180deg, 100%, 50%)", "hsl(180deg, 100%, 50%)", "#00FFFF"),
        ("hsla(-120, 100%, 50%, .5)", "hsla(-120, 100%, 50%, .5)", "#0000FF80"),
        ("COLOR(red: 1, green: .5, blue: 0)", "COLOR(red: 1, green: .5, blue: 0)", "#FF8000"),
    ])
    func detectsColors(_ fixture: (String, String, String)) throws {
        let (input, expectedOriginal, hex) = fixture
        let detection = try #require(ContentDetector.detect(input))
        guard case let .color(red, green, blue, alpha, original) = detection else {
            Issue.record("Expected a color, got \(detection)")
            return
        }
        #expect(original == expectedOriginal)
        #expect(ClipColor(red: red, green: green, blue: blue, alpha: alpha).formatted(as: .hex) == hex)
    }

    @Test func colorNotationsPreserveColorAndTransparency() throws {
        let teal = try #require(ClipColor.parse("#14B8A6"))
        #expect(teal.red == 20.0 / 255)
        #expect(teal.green == 184.0 / 255)
        #expect(teal.blue == 166.0 / 255)
        #expect(teal.alpha == 1)
        #expect(teal.formatted(as: .rgb) == "rgb(20, 184, 166)")
        let translucent = try #require(ClipColor.parse("#14B8A680"))
        for notation in ClipColor.Notation.allCases {
            let converted = try #require(ClipColor.parse(translucent.formatted(as: notation)))
            #expect(converted.formatted(as: .hex) == "#14B8A680")
        }
        #expect(ClipColor.parse("#000")?.formatted(as: .hsl) == "hsl(0, 0%, 0%)")
    }

    @Test(arguments: [
        ("您的验证码是 482913，5 分钟内有效", "482913"),
        ("校验码4829，请勿泄露。", "4829"),
        ("动态码为 48291327", "48291327"),
        ("确认码：12345", "12345"),
        ("代码 1234567", "1234567"),
        ("Your VERIFICATION CODE is A7BC92.", "A7BC92"),
        ("Security code: 2085", "2085"),
        ("One-time password: T2K47Z8Q", "T2K47Z8Q"),
        ("您的OTP是98ZY54。", "98ZY54"),
        ("Your code is 076193.", "076193"),
    ])
    func detectsOneTimeCodes(_ fixture: (String, String)) {
        #expect(ContentDetector.detect(fixture.0) == .oneTimeCode(fixture.1))
    }

    @Test(arguments: ["com.apple.MobileSMS", "com.apple.Passwords", "com.tencent.xinWeChat"])
    func allowsBareCodesFromThreeSources(_ source: String) {
        #expect(ContentDetector.detect(" 048291\n", sourceBundleIdentifier: source) == .oneTimeCode("048291"))
        #expect(ContentDetector.detect("AB4829", sourceBundleIdentifier: source) == nil)
    }

    @Test func rejectsBareAndOverlongMessages() {
        #expect(ContentDetector.detect("482913", sourceBundleIdentifier: "com.apple.Notes") != .oneTimeCode("482913"))
        let message = "验证码 482913 "
        #expect(ContentDetector.detect(message + String(repeating: "好", count: 200 - message.count)) == .oneTimeCode("482913"))
        #expect(ContentDetector.detect(message + String(repeating: "好", count: 201 - message.count)) == nil)
    }

    @Test func detectsStandaloneContactValuesAndBuildsActionURLs() {
        let email = ContentDetector.detect("  hello+notes@example.com\n")
        #expect(email == .email("hello+notes@example.com"))
        #expect(email?.contactURL?.absoluteString == "mailto:hello+notes@example.com")
        #expect(DetectedContent.email("hello?notes@example.com").contactURL?.query == nil)
        #expect(ContentDetector.detect("13800138000") == .phone("13800138000"))
        let phone = ContentDetector.detect(" +1 (415) 555-2671 ")
        #expect(phone == .phone("+1 (415) 555-2671"))
        #expect(phone?.contactURL?.absoluteString == "tel:+14155552671")
        #expect(ContentDetector.detect("+44 20 7946 0958") == .phone("+44 20 7946 0958"))
    }

    @Test(arguments: [
        ("func greet(name: String) -> String {\n    return name\n}", CodeLanguage.swift),
        ("func greet() {\n    print(\"Hello\")\n}", .swift),
        ("const square = (x: number) => x * x;\nconsole.log(square(2));", .javascript),
        ("def square(x):\n    return x * x", .python),
        ("def greet():\n    return \"Hi.\"", .python),
        (#"{"color":"teal","items":[1,2,3]}"#, .json),
        ("[1,2,3]", .json),
        ("<article>\n</article>", .html),
        (".card {\n    color: teal;\n}", .css),
        ("#!/bin/sh\necho hello", .shell),
        ("SELECT name\nFROM contacts", .sql),
        ("package main\nfunc main() {\n}", .go),
        ("fn main() {\n    println!(\"Hello\");\n}", .rust),
        ("x = 1;\ny = 2;", .other),
        ("{\n    start();\n    stop();\n}", .other),
    ])
    func detectsCodeAndGuessesLanguage(_ fixture: (String, CodeLanguage)) {
        #expect(ContentDetector.detect(fixture.0) == .code(language: fixture.1))
    }

    @Test(arguments: [
        "", "#12345", "#ABCG", "My color is #14B8A6.", "rgb(256, 0, 1)", "rgba(1, 2, 3, 2)",
        "hsl(0, 100, 50)", "Color(red: 1, green: 0, blue: 2)", "验证码是 482913 或 9876。",
        "验证码是 A7BC92。", "Code is ONEWORD.", "OTP: id_482913", "OTP: 148291312",
        "验证码是 13800138000。", "Email hello@example.com for details.",
        "hello@example.com, support@example.com", "Call +1 (415) 555-2671 to book.",
        "const x = 42;", "{ invalid json }",
    ])
    func rejectsPartialOrInvalidMatches(_ input: String) {
        #expect(ContentDetector.detect(input) == nil)
    }

    @Test(arguments: [
        "明天记得带伞。\n如果晚点到，先在门口等我。",
        "会议纪要\n    今天对齐了需求。\n    下周再讨论方案。",
        "我们计划在 2026 年更新这篇文章。",
        "代码评审安排在周五，请带上最新版本。",
        "The meeting is on Monday.\nIt will take about an hour.",
        "Let the team know;\n  return when you have time.",
        "From my desk,\nwhere it was raining.",
        "Please select a seat from the available options.\nThen confirm your name.",
        "Select items from the menu.\nThen confirm your name.",
        "Scope => Apps\nTimeline => Next week",
        "# Notes\n\n- Use **bold** for emphasis.\n- Keep [the link](https://example.com).",
        "> A short quote\n\n    Followed by an indented paragraph.",
    ])
    func leavesOrdinaryProseUnclassified(_ input: String) {
        #expect(ContentDetector.detect(input) == nil)
    }

    @Test func syntaxTokensRespectStringsCommentsAndLineLimit() {
        let source = "let item = \"return 10\" // 20\nreturn 30"
        let tokens = CodeSyntax.tokens(in: source, language: .swift)
        #expect(tokens.map { String(source[$0.range]) } == ["let", "\"return 10\"", "// 20", "return", "30"])
        #expect(tokens.map(\.kind) == [.keyword, .string, .comment, .keyword, .number])

        let python = "return 1 # 10"
        #expect(CodeSyntax.tokens(in: python, language: .python).map(\.kind) == [.keyword, .number, .comment])
        let sql = "SELECT 1 -- SELECT 2"
        #expect(CodeSyntax.tokens(in: sql, language: .sql).map(\.kind) == [.keyword, .number, .comment])
        let long = String(repeating: "// comment\n", count: 40) + "let afterLimit = 1"
        #expect(CodeSyntax.tokens(in: long, language: .swift).map(\.kind) == Array(repeating: .comment, count: 40))
    }

    @MainActor
    @Test func cachesTextByIDContentAndSource() {
        let cache = DetectionCache()
        let id = UUID()
        var clip = Clip(id: id, payload: .text("482913", rtf: nil, html: nil), date: .now)
        #expect(cache.result(for: clip) == nil)
        clip.sourceBundleIdentifier = "com.apple.MobileSMS"
        #expect(cache.result(for: clip) == .oneTimeCode("482913"))
        cache.invalidate(id)
        clip.payload = .text("#14B8A6", rtf: nil, html: nil)
        #expect(cache.result(for: clip) == ContentDetector.detect("#14B8A6"))
        clip.payload = .text("ordinary prose", rtf: nil, html: nil)
        #expect(cache.result(for: clip) == nil)
        clip.payload = .link("#14B8A6")
        #expect(cache.result(for: clip) == nil)
    }

    @MainActor
    @Test func filtersDerivedTypesAlongsideSearchGroupAndSource() {
        let cache = DetectionCache()
        let group = UUID()
        let source = "com.apple.MobileSMS"
        let color = Clip(id: UUID(), payload: .text("#14B8A6", rtf: nil, html: nil), date: .now,
                         groupIDs: [group], sourceBundleIdentifier: source)
        let otp = Clip(id: UUID(), payload: .text("验证码 482913", rtf: nil, html: nil), date: .now,
                       groupIDs: [group], sourceBundleIdentifier: source)
        let code = Clip(id: UUID(), payload: .text("{\"a\":1}", rtf: nil, html: nil), date: .now,
                        groupIDs: [group], sourceBundleIdentifier: source)
        let link = Clip(id: UUID(), payload: .link("#14B8A6"), date: .now,
                        groupIDs: [group], sourceBundleIdentifier: source)
        let otherColor = Clip(id: UUID(), payload: color.payload, date: .now, isFavorite: true)
        let clips = [color, otp, code, link, otherColor]

        for (type, query, expected) in [
            (HistoryContentType.color, "14b8", [color.id]),
            (.oneTimeCode, "482913", [otp.id]),
            (.code, "", [code.id]),
            (.kind(.text), "", [color.id, otp.id, code.id]),
            (.kind(.link), "", [link.id]),
        ] {
            let filter = HistoryFilter(search: query, contentType: type, favoritesOnly: true, sourceName: nil,
                                       groupID: group, sourceBundleIdentifier: source, locale: .current)
            let matches = filter.matchingDetectedType(in: clips.filter(filter.includes), cache: cache)
            #expect(matches.map(\.id) == expected)
        }
    }

    @MainActor
    @Test func detectionCacheLimitsUTF8BytesAndInvalidatesSameLengthEdits() {
        let cache = DetectionCache()
        var clip = Clip(id: UUID(), payload: .text("#14B8A6", rtf: nil, html: nil), date: .now)
        #expect(cache.result(for: clip) == ContentDetector.detect("#14B8A6"))
        clip.payload = .text("#FF0000", rtf: nil, html: nil)
        cache.invalidate(clip.id)
        #expect(cache.result(for: clip) == ContentDetector.detect("#FF0000"))

        let padded = "#FF0000" + String(repeating: "\u{3000}", count: 6_664) + " "
        #expect(padded.utf8.count == 20_000)
        clip.payload = .text(padded, rtf: nil, html: nil)
        #expect(cache.result(for: clip) == ContentDetector.detect("#FF0000"))
        clip.payload = .text(padded + " ", rtf: nil, html: nil)
        #expect(cache.result(for: clip) == nil)
    }
}
