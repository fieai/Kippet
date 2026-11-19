import Testing
@testable import ClipShelf

struct PasteTransformTests {
    @Test func trimsAndCollapsesWhitespace() {
        #expect(PasteTransform.trimWhitespace.apply(to: " \t hello \n") == "hello")
        #expect(PasteTransform.collapseWhitespace.apply(to: "  one\t two \r\n\t\r\n three  ") == "one two\n\nthree")
        #expect(PasteTransform.removeLineBreaks.apply(to: "  one\r\n\t\r\n two\u{2028} three  ") == "one two three")
        #expect(PasteTransform.removeBlankLines.apply(to: "  one\r\n\t \r\n two\r\n") == "  one\n two")
        #expect(PasteTransform.trimWhitespace.apply(to: "already trimmed") == "already trimmed")
    }

    @Test func changesCaseAndKeepsNonCasedText() {
        #expect(PasteTransform.uppercase.apply(to: "hello") == "HELLO")
        #expect(PasteTransform.lowercase.apply(to: "HELLO") == "hello")
        #expect(PasteTransform.capitalized.apply(to: "hello WORLD") == "Hello World")
        #expect(PasteTransform.uppercase.apply(to: "中文内容") == "中文内容")
        #expect(PasteTransform.capitalized.apply(to: "中文内容") == "中文内容")
    }

    @Test func sortsNaturallyAndDeduplicatesInOriginalOrder() {
        #expect(PasteTransform.sortLines.apply(to: "line 10\r\nline 2\r\nline 1") == "line 1\nline 2\nline 10")
        #expect(PasteTransform.dedupeLines.apply(to: "B\r\nA\r\nB\r\nC\r\nA") == "B\nA\nC")
    }

    @Test func formatsAndMinifiesJSON() {
        let compact = #"{"url":"https://example.com/a"}"#
        let pretty = """
        {
          "url" : "https://example.com/a"
        }
        """
        #expect(PasteTransform.jsonPretty.apply(to: compact) == pretty)
        #expect(PasteTransform.jsonMinify.apply(to: pretty) == compact)
        #expect(PasteTransform.jsonPretty.apply(to: pretty) == nil)
        #expect(PasteTransform.jsonMinify.apply(to: compact) == nil)
        #expect(PasteTransform.jsonPretty.apply(to: "{invalid}") == nil)
        #expect(PasteTransform.jsonMinify.apply(to: "{invalid}") == nil)
        #expect(PasteTransform.jsonMinify.apply(to: " true ") == "true")
    }

    @Test func removesTrackingFromMultipleLinksAndKeepsOtherParameters() {
        let source = "链接 A https://youtube.com/watch?v=42&si=secret&UTM_source=chat#clip 和 B https://example.com/a?tag=a%2fb&si=keep&fbclid=discard#section"
        let expected = "链接 A https://youtube.com/watch?v=42#clip 和 B https://example.com/a?tag=a%2fb&si=keep#section"
        #expect(PasteTransform.cleanURL.apply(to: source) == expected)
        #expect(PasteTransform.cleanURL.apply(to: expected) == nil)
        #expect(PasteTransform.cleanURL.apply(to: "https://www.bilibili.com/video/a?vd_source=abc#chapter")
            == "https://www.bilibili.com/video/a#chapter")
        #expect(PasteTransform.cleanURL.apply(to: "https://bilibili.com.example/a?vd_source=abc") == nil)
        #expect(PasteTransform.cleanURL.apply(to: "https://example.com/path?%75tm_medium=link&gclid=x")
            == "https://example.com/path")
    }

    @Test func encodesAndDecodesURLQueryText() {
        let source = "中文 a&b=c+d?"
        let encoded = "%E4%B8%AD%E6%96%87%20a%26b%3Dc%2Bd%3F"
        #expect(PasteTransform.urlEncode.apply(to: source) == encoded)
        #expect(PasteTransform.urlDecode.apply(to: encoded) == source)
        #expect(PasteTransform.urlDecode.apply(to: "%FF") == nil)
    }

    @Test func encodesAndDecodesBase64AndRejectsNonUTF8() {
        #expect(PasteTransform.base64Encode.apply(to: "中文") == "5Lit5paH")
        #expect(PasteTransform.base64Decode.apply(to: "5Lit5paH") == "中文")
        #expect(PasteTransform.base64Decode.apply(to: "/w==") == nil)
        #expect(PasteTransform.base64Decode.apply(to: "base64?") == nil)
    }
}
