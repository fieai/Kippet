import SwiftUI

struct ShelfAutomationView: View {
    @Bindable var preferences: ShelfPreferences
    let store: ClipboardStore
    @State private var copyMessage: String?

    private static let links = [
        "clipshelf://open",
        "clipshelf://search?q=hello",
        "clipshelf://stack",
        "clipshelf://snippet/new?text=hello&title=Hello",
        "clipshelf://copy?index=1",
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
                            Button("复制") { copy(config) }
                                .accessibilityLabel("复制 MCP 配置")
                            Button("复制 Claude Code 命令") {
                                copy(ShelfAutomation.claudeCommand(executablePath: path))
                            }
                        }
                    }
                }
            }
            Section("快捷指令 / Raycast / Alfred") {
                Toggle("允许链接复制历史", isOn: $preferences.urlCopyEnabled)
                ForEach(Self.links, id: \.self) { link in
                    LabeledContent {
                        Button("复制") { copy(link) }
                            .accessibilityLabel("复制 \(link)")
                    } label: {
                        Text(link).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            if let copyMessage { Text(copyMessage).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
    }

    private func copy(_ text: String) {
        let clip = Clip(id: UUID(), payload: .text(text, rtf: nil, html: nil), date: .now)
        Task { copyMessage = await store.copy(clip).message }
    }
}
