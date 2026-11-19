import AppKit
import Testing
@testable import ClipShelf

@MainActor
struct MarkdownExportTests {
    @Test func exportsHTMLInlineFormattingAndParagraphs() {
        let html = Data("""
        <p>Some <b>bold</b>, <i>italic</i> and <b><i>both</i></b> with a
        <a href="https://example.com/page">link</a> and <code>a_b</code>.</p><p>Next</p>
        """.utf8)
        let output = MarkdownExport.markdown("plain", rtf: nil, html: html)
        #expect(output == "Some **bold**, *italic* and ***both*** with a [link](https://example.com/page) and `a_b`.\n\nNext")
    }

    @Test func exportsHTMLListsHeadingsAndCodeBlocks() {
        let html = Data("""
        <h1>Big</h1><h2>Smaller</h2><p>Body</p>
        <ul><li>First</li><li><b>Second</b></li></ul>
        <ol start="3"><li>Third</li><li>Fourth</li></ol>
        <pre><code>  one\n\n  two</code></pre>
        """.utf8)
        let output = MarkdownExport.markdown("plain", rtf: nil, html: html)
        #expect(output == """
        # **Big**

        ## **Smaller**

        Body

        - First
        - **Second**

        1. Third
        1. Fourth

        ```
          one

          two
        ```
        """)
    }

    @Test func exportsRTFAndPrefersOriginalHTML() throws {
        let bold = NSAttributedString(string: "粗体", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        let rtf = try bold.data(
            from: NSRange(location: 0, length: bold.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let html = "<i>HTML</i>"
        #expect(MarkdownExport.markdown("粗体", rtf: rtf, html: nil) == "**粗体**")
        #expect(MarkdownExport.markdown("粗体", rtf: rtf, html: Data(html.utf8)) == "*HTML*")
        #expect(MarkdownExport.htmlSource(rtf: rtf, html: Data(html.utf8)) == html)
        let generated = try #require(MarkdownExport.htmlSource(rtf: rtf, html: nil))
        #expect(generated.contains("<html>"))
        #expect(MarkdownExport.markdown("fallback", rtf: nil, html: Data(generated.utf8)) == "**粗体**")
    }

    @Test func plainTextPassesThroughVerbatim() {
        let plain = "  普通文字\r\n[a]_*\n"
        #expect(MarkdownExport.markdown(plain, rtf: nil, html: nil) == plain)
        #expect(MarkdownExport.htmlSource(rtf: nil, html: nil) == nil)
    }
}
