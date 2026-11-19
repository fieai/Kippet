import Foundation

enum CodeSyntax {
    enum Kind: Equatable { case keyword, string, number, comment }

    struct Token {
        let range: Range<String.Index>
        let kind: Kind
    }

    private static let pattern = #"(?<comment>/\*[\s\S]*?\*/|//[^\r\n]*)|(?<string>"(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|`(?:\\.|[^`\\\r\n])*`)|(?<number>\b(?:0[xX][0-9A-Fa-f]+|\d+(?:\.\d+)?)\b)|(?<word>\b[A-Za-z_]\w*\b)"#
    private static let standard = try! NSRegularExpression(pattern: pattern)
    private static let hashComments = try! NSRegularExpression(pattern: #"#[^\r\n]*|"# + pattern)
    private static let sqlComments = try! NSRegularExpression(pattern: #"--[^\r\n]*|"# + pattern)

    private static let keywords: Set<String> = [
        "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "def", "defer",
        "do", "else", "enum", "export", "extension", "false", "fi", "fn", "for", "from", "func",
        "function", "guard", "if", "impl", "import", "in", "interface", "let", "match", "mut", "new",
        "nil", "none", "null", "package", "private", "protocol", "pub", "public", "return", "self",
        "static", "struct", "switch", "throw", "true", "try", "type", "use", "var", "while",
        "select", "where", "join", "group", "order", "by", "insert", "into", "values", "update",
        "set", "delete", "create", "table", "and", "or", "limit",
    ]

    static func tokens(in source: String, language: CodeLanguage?) -> [Token] {
        let pattern: NSRegularExpression
        switch language {
        case .python, .shell: pattern = hashComments
        case .sql: pattern = sqlComments
        default: pattern = standard
        }

        let prefix = source.prefix(16_384)
        let lines = prefix.split(maxSplits: 40, omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let end = lines.prefix(40).last?.endIndex else { return [] }
        let range = NSRange(source.startIndex..<end, in: source)
        return pattern.matches(in: source, range: range).compactMap { match in
            guard let range = Range(match.range, in: source) else { return nil }
            let kind: Kind
            if match.range(withName: "string").location != NSNotFound {
                kind = .string
            } else if match.range(withName: "number").location != NSNotFound {
                kind = .number
            } else if match.range(withName: "word").location == NSNotFound {
                kind = .comment
            } else if keywords.contains(source[range].lowercased()) {
                kind = .keyword
            } else {
                return nil
            }
            return Token(range: range, kind: kind)
        }
    }
}
