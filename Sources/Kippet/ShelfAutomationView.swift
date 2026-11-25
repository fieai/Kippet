import SwiftUI

struct ShelfAutomationView: View {
    @Bindable var preferences: ShelfPreferences
    let store: ClipboardStore
    @State private var copyMessage: String?
    /// The text whose 「复制」 button is showing 「已复制」 right now.
    @State private var copiedText: String?

    private static let links = [
        "kippet://open",
        "kippet://search?q=hello",
        "kippet://stack",
        "kippet://snippet/new?text=hello&title=Hello",
        "kippet://copy?index=1",
    ]

    var body: some View {
        Form {
            Section("MCP") {
                Toggle("允许 AI 工具读取历史（MCP）", isOn: $preferences.mcpEnabled)
                Text("仅本机，验证码和被排除来源不会提供")
                    .foregroundStyle(.secondary)
                Toggle("允许 AI 新建片段", isOn: $preferences.mcpSnippetsEnabled)
                    .disabled(!preferences.mcpEnabled)
                if let path = Bundle.main.executablePath, let config = ShelfAutomation.mcpConfig(executablePath: path) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Claude Desktop / Claude Code / Cursor")
                        Text(config)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack {
                            copyButton(config, title: L("复制"))
                                .accessibilityLabel("复制 MCP 配置")
                            copyButton(ShelfAutomation.claudeCommand(executablePath: path), title: L("复制 Claude Code 命令"))
                        }
                    }
                }
            }
            Section("快捷指令 / Raycast / Alfred") {
                Toggle("允许链接复制历史", isOn: $preferences.urlCopyEnabled)
                ForEach(Self.links, id: \.self) { link in
                    LabeledContent {
                        copyButton(link, title: L("复制"))
                            .accessibilityLabel(L("复制 %@", link))
                    } label: {
                        Text(link).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            if let copyMessage {
                Text(copyMessage).foregroundStyle(ShelfTheme.warning)
                    .transition(.opacity)
            }
        }
        .formStyle(.grouped)
        .animation(ShelfMotion.lift, value: copyMessage)
    }

    /// Confirms on the button itself, where the person is looking, then turns back after a moment.
    private func copyButton(_ text: String, title: String) -> some View {
        let copied = copiedText == text
        return Button { copy(text) } label: {
            Label {
                // Both captions share one slot sized to the wider, so neighbours never shift.
                ZStack(alignment: .leading) {
                    Text(title).opacity(copied ? 0 : 1).accessibilityHidden(copied)
                    Text("已复制").opacity(copied ? 1 : 0).accessibilityHidden(!copied)
                }
            } icon: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .animation(ShelfMotion.lift, value: copied)
    }

    private func copy(_ text: String) {
        let clip = Clip(id: UUID(), payload: .text(text, rtf: nil, html: nil), date: .now)
        Task {
            let result = await store.copy(clip)
            if case .written = result {
                copyMessage = nil
                copiedText = text
                try? await Task.sleep(for: .seconds(1.5))
                if copiedText == text { copiedText = nil }
            } else {
                copyMessage = result.message
            }
        }
    }
}
