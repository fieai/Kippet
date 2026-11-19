import AppKit
import SwiftUI

extension DetectedContent {
    var label: String {
        switch self {
        case .color: "颜色"
        case let .code(language): language.map { "代码 · \($0.rawValue)" } ?? "代码"
        case .oneTimeCode: "验证码"
        case .email: "邮箱"
        case .phone: "电话"
        }
    }

    var symbol: String {
        switch self {
        case .color: "paintpalette"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .oneTimeCode: "number.square"
        case .email: "envelope"
        case .phone: "phone"
        }
    }

    var contactAction: String? {
        switch self {
        case .email: "发邮件"
        case .phone: "拨打"
        default: nil
        }
    }
}

struct DetectedContentView: View {
    let detection: DetectedContent
    let source: String
    var copy: ((String) -> Void)? = nil

    var body: some View {
        switch detection {
        case let .color(red, green, blue, alpha, original):
            let color = ClipColor(red: red, green: green, blue: blue, alpha: alpha)
            if let copy {
                fullColorPreview(color, copy: copy)
            } else {
                colorCard(color, original: original)
            }
        case let .code(language):
            if copy != nil {
                ScrollView {
                    codeText(source, language: language)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                codeText(String(source.prefix(1_600)), language: language)
                    .lineLimit(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            }
        case let .oneTimeCode(code):
            VStack(spacing: 5) {
                Text(verbatim: code)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospaced()
                    .tracking(2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(verbatim: source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .email(value), let .phone(value):
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: value)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)
                    .help(value)
                if let action = detection.contactAction, let url = detection.contactURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: detection.symbol)
                    }
                    .buttonStyle(ShelfGlyphButtonStyle())
                    .help(action)
                    .accessibilityLabel(action)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func colorCard(_ color: ClipColor, original: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ColorSwatch(color: color)
            Text(verbatim: original)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(original)
            Text(verbatim: color.formatted(as: original.hasPrefix("#") ? .rgb : .hex))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func fullColorPreview(_ color: ClipColor, copy: @escaping (String) -> Void) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ColorSwatch(color: color).frame(height: 66)
                ForEach(ClipColor.Notation.allCases) { notation in
                    let value = color.formatted(as: notation)
                    HStack {
                        Text(notation.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: value)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button("复制") { copy(value) }
                            .accessibilityLabel("复制为 \(notation.rawValue)")
                    }
                }
            }
        }
    }

    private func codeText(_ source: String, language: CodeLanguage?) -> Text {
        var text = AttributedString()
        var start = source.startIndex
        for token in CodeSyntax.tokens(in: source, language: language) {
            text.append(AttributedString(source[start..<token.range.lowerBound]))
            var part = AttributedString(source[token.range])
            part.foregroundColor = ShelfTheme.syntaxTint(for: token.kind)
            text.append(part)
            start = token.range.upperBound
        }
        text.append(AttributedString(source[start...]))
        return Text(text).font(.system(size: 11.5, design: .monospaced))
    }
}

private struct ColorSwatch: View {
    let color: ClipColor

    var body: some View {
        Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if color.alpha < 1 {
                    Canvas { context, size in
                        let square: CGFloat = 8
                        let rows = Int(ceil(size.height / square))
                        let columns = Int(ceil(size.width / square))
                        var tiles = Path()
                        for row in 0..<rows {
                            for column in stride(from: row % 2, to: columns, by: 2) {
                                tiles.addRect(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square,
                                                     width: square, height: square))
                            }
                        }
                        context.fill(tiles, with: .color(ShelfTheme.checkerTile))
                    }
                    .background(ShelfTheme.checkerBase)
                }
            }
            .clipShape(.rect(cornerRadius: ShelfTheme.chipRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ShelfTheme.chipRadius)
                    .strokeBorder(ShelfTheme.hairline)
            }
            .accessibilityHidden(true)
    }
}
