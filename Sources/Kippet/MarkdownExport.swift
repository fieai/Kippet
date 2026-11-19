import AppKit

@MainActor
enum MarkdownExport {
    static func markdown(_ plainText: String, rtf: Data?, html: Data?) -> String {
        guard let rich = html.flatMap(readHTML) ?? rtf.flatMap(readRTF), rich.length > 0
        else { return plainText }

        let paragraphs = paragraphs(in: rich)
        let bodySizes = paragraphs.compactMap { paragraph -> CGFloat? in
            guard let style = paragraph.runs.first?.style, !style.bold, !style.monospace else { return nil }
            return style.size
        }
        let counts = Dictionary(grouping: bodySizes, by: { $0 }).mapValues(\.count)
        let bodySize = counts.keys.min {
            counts[$0, default: 0] == counts[$1, default: 0]
                ? $0 < $1 : counts[$0, default: 0] > counts[$1, default: 0]
        } ?? 12

        var blocks: [String] = []
        var codeLines: [String] = []
        var listMarker: String?
        for paragraph in paragraphs {
            if paragraph.isCode {
                codeLines.append(paragraph.text)
                continue
            }
            if !codeLines.isEmpty {
                blocks.append(fencedCode(codeLines.joined(separator: "\n")))
                codeLines.removeAll()
                listMarker = nil
            }

            let inline = paragraph.runs.map { $0.style.markdown($0.text) }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !inline.isEmpty else {
                listMarker = nil
                continue
            }
            if let list = paragraph.lists.last {
                let first = list.startingItemNumber
                let marker = list.marker(forItemNumber: first) == list.marker(forItemNumber: first + 1) ? "- " : "1. "
                let indent = String(repeating: "    ", count: paragraph.lists.count - 1)
                let line = indent + marker + inline
                if listMarker == marker, let index = blocks.indices.last {
                    blocks[index] += "\n" + line
                } else {
                    blocks.append(line)
                }
                listMarker = marker
            } else {
                let ratio = (paragraph.runs.first?.style.size ?? bodySize) / bodySize
                let heading = ratio >= 2 ? "# " : ratio >= 1.5 ? "## " : ""
                blocks.append(heading + inline)
                listMarker = nil
            }
        }
        if !codeLines.isEmpty { blocks.append(fencedCode(codeLines.joined(separator: "\n"))) }
        let markdown = blocks.joined(separator: "\n\n")
        return markdown.isEmpty ? plainText : markdown
    }

    static func htmlSource(rtf: Data?, html: Data?) -> String? {
        if let html, let source = String(data: html, encoding: .utf8) ?? String(data: html, encoding: .utf16) {
            return source
        }
        guard let rtf, let rich = readRTF(rtf),
              let data = try? rich.data(
                from: NSRange(location: 0, length: rich.length),
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ]
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func readHTML(_ data: Data) -> NSAttributedString? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
            .webResourceLoadDelegate: LocalHTMLResources(),
        ]
        return try? NSAttributedString(data: data, options: options, documentAttributes: nil)
    }

    private static func readRTF(_ data: Data) -> NSAttributedString? {
        NSAttributedString(rtf: data, documentAttributes: nil)
    }

    private static func paragraphs(in rich: NSAttributedString) -> [Paragraph] {
        let text = rich.string as NSString
        var paragraphs: [Paragraph] = []
        var start = 0
        while start < text.length {
            var end = 0
            var contentsEnd = 0
            text.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            let paragraphStyle = rich.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
            let lists = paragraphStyle?.textLists ?? []
            var contentStart = start
            // TextKit 1 represents the list marker as a separate, tab-delimited prefix.
            if !lists.isEmpty, contentsEnd > start, text.character(at: start) == 9 {
                let range = NSRange(location: start + 1, length: contentsEnd - start - 1)
                let tab = text.range(of: "\t", options: [], range: range)
                if tab.location != NSNotFound { contentStart = NSMaxRange(tab) }
            }

            let range = NSRange(location: contentStart, length: contentsEnd - contentStart)
            var runs: [Run] = []
            rich.enumerateAttributes(in: range) { attributes, runRange, _ in
                let style = InlineStyle(attributes)
                let content = text.substring(with: runRange).replacingOccurrences(of: "\u{FFFC}", with: "")
                if let last = runs.indices.last, runs[last].style == style {
                    runs[last].text += content
                } else {
                    runs.append(Run(text: content, style: style))
                }
            }
            if range.length == 0 {
                let style = InlineStyle(rich.attributes(at: start, effectiveRange: nil))
                if style.monospace { runs = [Run(text: "", style: style)] }
            }
            paragraphs.append(Paragraph(runs: runs, lists: lists))
            start = end
        }
        return paragraphs
    }

    private static func fencedCode(_ text: String) -> String {
        let fence = backtickFence(for: text, minimum: 3)
        return "\(fence)\n\(text)\n\(fence)"
    }

    private static func backtickFence(for text: String, minimum: Int) -> String {
        let longest = text.split { $0 != "`" }.map(\.count).max() ?? 0
        return String(repeating: "`", count: max(minimum, longest + 1))
    }

    private struct Paragraph {
        let runs: [Run]
        let lists: [NSTextList]

        var text: String { runs.map(\.text).joined() }
        var isCode: Bool { lists.isEmpty && !runs.isEmpty && runs.allSatisfy { $0.style.monospace } }
    }

    private struct Run {
        var text: String
        let style: InlineStyle
    }

    private struct InlineStyle: Equatable {
        let size: CGFloat?
        let bold: Bool
        let italic: Bool
        let monospace: Bool
        let link: String?

        init(_ attributes: [NSAttributedString.Key: Any]) {
            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            size = font?.pointSize
            bold = traits.contains(.bold)
            italic = traits.contains(.italic)
            monospace = font?.isFixedPitch == true || traits.contains(.monoSpace)
            link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
        }

        @MainActor
        func markdown(_ text: String) -> String {
            guard let first = text.firstIndex(where: { !$0.isWhitespace }),
                  let last = text.lastIndex(where: { !$0.isWhitespace }) else { return text }
            let end = text.index(after: last)
            let content = String(text[first..<end])
            var inline: String
            if monospace {
                let fence = MarkdownExport.backtickFence(for: content, minimum: 1)
                let padding = content.first == "`" || content.last == "`" ? " " : ""
                inline = fence + padding + content + padding + fence
            } else {
                inline = content.replacingOccurrences(of: "\u{2028}", with: "  \n")
                for character in ["\\", "*", "_", "[", "]", "`"] {
                    inline = inline.replacingOccurrences(of: character, with: "\\" + character)
                }
            }
            let emphasis = (bold ? "**" : "") + (italic ? "*" : "")
            inline = emphasis + inline + emphasis
            if let link {
                let destination = link.replacingOccurrences(of: "(", with: "%28")
                    .replacingOccurrences(of: ")", with: "%29")
                inline = "[\(inline)](\(destination))"
            }
            return text[..<first] + inline + text[end...]
        }
    }

    private final class LocalHTMLResources: NSObject {
        // HTML can contain remote images, stylesheets or iframes. Import the supplied markup only.
        @objc(webView:resource:willSendRequest:redirectResponse:fromDataSource:)
        func blockRequest(_: AnyObject, resource: AnyObject, request: NSURLRequest,
                          redirect: URLResponse?, dataSource: AnyObject) -> NSURLRequest? {
            nil
        }
    }
}
