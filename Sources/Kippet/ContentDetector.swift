import Foundation

enum DetectedContent: Equatable, Sendable {
    case color(red: Double, green: Double, blue: Double, alpha: Double, original: String)
    case code(language: CodeLanguage?)
    case oneTimeCode(String)
    case email(String)
    case phone(String)

    var contactURL: URL? {
        switch self {
        case let .email(address):
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@+.-_"))
            return address.addingPercentEncoding(withAllowedCharacters: allowed)
                .flatMap { URL(string: "mailto:\($0)") }
        case let .phone(number):
            let digits = number.compactMap(\.wholeNumberValue).map(String.init).joined()
            return URL(string: "tel:\(number.hasPrefix("+") ? "+" : "")\(digits)")
        default:
            return nil
        }
    }
}

enum CodeLanguage: String, Sendable {
    case swift = "Swift"
    case javascript = "JS / TS"
    case python = "Python"
    case json = "JSON"
    case html = "HTML"
    case css = "CSS"
    case shell = "Shell"
    case sql = "SQL"
    case go = "Go"
    case rust = "Rust"
    case other = "其他"

    var label: String { self == .other ? L(rawValue) : rawValue }
}

enum ContentDetector {
    static func detect(_ text: String, sourceBundleIdentifier: String? = nil) -> DetectedContent? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.utf8.first else { return nil }
        if let color = ClipColor.parse(text) {
            return .color(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha, original: text)
        }
        if text.prefix(201).count <= 200,
           let code = oneTimeCode(in: text, sourceBundleIdentifier: sourceBundleIdentifier) {
            return .oneTimeCode(code)
        }
        if text.utf8.prefix(255).count <= 254, emailPattern.firstMatch(in: text) != nil {
            return .email(text)
        }
        if text.utf8.prefix(65).count <= 64, phonePattern.firstMatch(in: text) != nil {
            let range = NSRange(text.startIndex..., in: text)
            if chineseMobile.firstMatch(in: text) != nil ||
                phoneDetector?.firstMatch(in: text, range: range)?.range == range {
                return .phone(text)
            }
        }
        if first == 123 || first == 91, // { or [
           let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
           json is [String: Any] || json is [Any] {
            return .code(language: .json)
        }
        return detectCode(text)
    }

    private static let chineseKeywords = try! NSRegularExpression(pattern: "验证码|校验码|动态码|确认码|代码")
    private static let englishKeywords = try! NSRegularExpression(
        pattern: #"(?<![\p{Latin}\d_])(?:verification\s+code|security\s+code|one-time|OTP|code\s+is)(?![\p{Latin}\d_])"#,
        options: .caseInsensitive
    )
    private static let numericCode = try! NSRegularExpression(pattern: #"\A\d{4,8}\z"#)
    private static let numericTokens = try! NSRegularExpression(pattern: #"(?<![\p{Latin}\d_])\d{4,8}(?![\p{Latin}\d_])"#)
    private static let englishTokens = try! NSRegularExpression(
        pattern: #"(?<![\p{Latin}\d_])(?:\d{4,8}|[A-Za-z0-9]{6,8})(?![\p{Latin}\d_])"#
    )
    private static let bareCodeSources: Set<String> = ["com.apple.MobileSMS", "com.apple.Passwords", "com.tencent.xinWeChat"]
    private static let emailPattern = try! NSRegularExpression(
        pattern: #"\A[A-Z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Z0-9!#$%&'*+/=?^_`{|}~-]+)*@(?:[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?\.)+[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?\z"#,
        options: .caseInsensitive
    )
    private static let phonePattern = try! NSRegularExpression(pattern: #"\A\+?[(\d][\d().\p{Zs}-]*\d\z"#)
    private static let chineseMobile = try! NSRegularExpression(pattern: #"\A1[3-9][0-9]{9}\z"#)
    private static let phoneDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    private static func oneTimeCode(in text: String, sourceBundleIdentifier: String?) -> String? {
        if let sourceBundleIdentifier, bareCodeSources.contains(sourceBundleIdentifier),
           numericCode.firstMatch(in: text) != nil { return text }

        let english = englishKeywords.firstMatch(in: text) != nil
        guard english || chineseKeywords.firstMatch(in: text) != nil else { return nil }
        let pattern = english ? englishTokens : numericTokens
        let range = NSRange(text.startIndex..., in: text)
        var token: String?
        for match in pattern.matches(in: text, range: range) {
            guard let range = Range(match.range, in: text),
                  text[range].unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
            else { continue }
            if token != nil { return nil }
            token = String(text[range])
        }
        return token
    }

    private static let statements = try! NSRegularExpression(pattern: [
        #"\A(?:func|fn|def|function)\s+\w+\s*\("#,
        #"\A(?:let|const|var|type)\s+\w+\s*[:=]"#,
        #"\A(?:import|package)\s+[\w.]+;?\z|\Afrom\s+\w+\s+import\s"#,
        #"\A(?:struct|enum|class|interface)\s+\w.*\{\z"#,
        #"\A(?:if|for|while)\s.*[{:;]\z"#,
        #"\A[\w.]+\s*:?=[^=>]|\A[\w.]+!?\(.*\);?\z|\A\([^)]*\)\s*=>"#,
        #"\A</?[A-Za-z][^<>]*>"#,
    ].joined(separator: "|"))
    private static let structure = try! NSRegularExpression(pattern: #"[{};]\z|\A[{}]"#)
    private static let cssDeclaration = try! NSRegularExpression(pattern: #"\A[a-z-]+\s*:\s*\S.*;\z"#)
    private static let returnStatement = try! NSRegularExpression(pattern: #"\Areturn(?:\s+.+)?;?\z"#)
    private static let sql = try! NSRegularExpression(
        pattern: #"(?im)^\h*(?:SELECT\h+(?:\*|[\w.]+(?:\h*,\h*[\w.]+)*)\s+FROM\h+\w+(?=\h*(?:;|$)|\h+(?:WHERE|JOIN|GROUP|ORDER|LIMIT)\b)|SELECT\h+\w+\h*;|INSERT\h+INTO\h+\w+\h*\(|CREATE\h+TABLE\h+\w+\s*\(|UPDATE\h+\w+\s+SET\h+\w+\h*=)"#
    )
    private static let languages: [(CodeLanguage, NSRegularExpression)] = {
        let patterns: [(CodeLanguage, String)] = [
            (.html, #"</[A-Za-z][^<>]*>|(?i:<!DOCTYPE\s+html)"#),
            (.shell, #"\A#!/|(?m)^\s*(?:export\s+\w+=|echo\s+|fi\s*$)"#),
            (.go, #"(?m)^\s*package\s+\w+\s*$|\b\w+\s*:=|\bfunc\s+\w+\(\w+\s+\w+"#),
            (.rust, #"\b(?:fn\s+\w+\(|let\s+mut\s|use\s+\w+::|println!\()"#),
            (.javascript, #"\b(?:const|function)\s+\w+|=>|\bconsole\.log\(|\b(?:interface|type)\s+\w+\s*[={]"#),
            (.swift, #"\bimport\s+(?:SwiftUI|Foundation|AppKit|UIKit)\b|\bfunc\s+\w+\(|\b(?:struct|enum|class)\s+\w+\s*:\s*\w+|\blet\s+\w+\s*[:=]"#),
            (.python, #"\bdef\s+\w+\([^)]*\)\s*:|\bfrom\s+\w+\s+import\s|(?m)^\s*(?:if|for|while)\s+[^\n]+:\s*$"#),
            (.css, #"(?m)^\s*[.#]?[a-z][\w.# :>\[\]-]*\{\s*$"#),
        ]
        return patterns.map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }
    }()

    private static func detectCode(_ text: String) -> DetectedContent? {
        let lines = text.prefix(16_384).split(
            maxSplits: 40, omittingEmptySubsequences: false, whereSeparator: \.isNewline
        ).prefix(40)
        guard lines.count >= 2 else { return nil }
        var nonEmpty = 0
        var indented = 0
        var statementCount = 0
        var structureCount = 0
        var declarations = 0
        var returns = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            nonEmpty += 1
            if line.first?.isWhitespace == true { indented += 1 }
            if statements.firstMatch(in: trimmed) != nil { statementCount += 1 }
            if structure.firstMatch(in: trimmed) != nil { structureCount += 1 }
            if cssDeclaration.firstMatch(in: trimmed) != nil { declarations += 1 }
            if returnStatement.firstMatch(in: trimmed) != nil { returns += 1 }
        }
        guard nonEmpty >= 2 else { return nil }
        let sample = lines.joined(separator: "\n")
        // A shebang or a full SQL clause is enough structure on its own.
        if sample.hasPrefix("#!/") { return .code(language: .shell) }
        if sql.firstMatch(in: sample) != nil { return .code(language: .sql) }
        let indentationScore = indented * 5 >= nonEmpty * 2 ? 1 : 0
        let score = statementCount * 2 + structureCount + indentationScore + declarations + returns
        guard score >= 4, statementCount > 0 || declarations > 0 else { return nil }
        let language = languages.first { $0.1.firstMatch(in: sample) != nil }?.0
        guard statementCount > 0 || language == .css else { return nil }
        return .code(language: language ?? .other)
    }
}

private extension NSRegularExpression {
    func firstMatch(in text: String) -> NSTextCheckingResult? {
        firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
