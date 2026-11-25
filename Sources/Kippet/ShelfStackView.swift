import SwiftUI

extension ShelfView {
    var stackView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("粘贴栈").font(.headline)
                Text(status.stackShortcutAvailable
                     ? L("%@ 贴下一条", status.stackShortcutLabel)
                     : L("%@ 不可用，可点「贴下一条」", status.stackShortcutLabel))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("连续收集", isOn: $pasteStack.isCollecting)
                    .toggleStyle(.checkbox)
                    .help("把随后复制到历史的内容按顺序加入栈")
                Button("贴下一条", action: onPasteNext)
                    .buttonStyle(.borderedProminent)
                    .disabled(pasteStack.entries.isEmpty || status.isPastingStack)
            }
            if pasteStack.entries.isEmpty {
                Text("从历史加入卡片，或开启连续收集后复制内容。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(pasteStack.entries.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 8) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                                Image(systemName: entry.clip.storedPayload.kind.symbol)
                                    .foregroundStyle(ShelfTheme.tint(for: entry.clip.storedPayload.kind))
                                Text(entry.clip.title ?? String(entry.clip.storedPayload.previewText.prefix(240)))
                                    .lineLimit(1)
                                Spacer(minLength: 12)
                                Button { pasteStack.move(entry.id, by: -1) } label: { Image(systemName: "chevron.up") }
                                    .disabled(index == 0).accessibilityLabel("上移")
                                Button { pasteStack.move(entry.id, by: 1) } label: { Image(systemName: "chevron.down") }
                                    .disabled(index == pasteStack.entries.count - 1).accessibilityLabel("下移")
                                Button { pasteStack.remove(entry.id) } label: { Image(systemName: "minus.circle") }
                                    .accessibilityLabel("移出粘贴栈")
                            }
                            .buttonStyle(.borderless)
                            .disabled(status.isPastingStack)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(index == 0 ? ShelfTheme.accent.opacity(0.1) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .transition(ShelfMotion.row)
                        }
                    }
                    .animation(ShelfMotion.list, value: pasteStack.entries.map(\.id))
                }
                .transition(.opacity)
            }
            HStack {
                Button("恢复上一条") { pasteStack.undoLastPaste() }
                    .disabled(!pasteStack.canUndoPaste || status.isPastingStack)
                Button("清空栈") { pasteStack.clear() }
                    .disabled((pasteStack.entries.isEmpty && !pasteStack.canUndoPaste && !pasteStack.isCollecting)
                              || status.isPastingStack)
                Spacer()
                Button("返回卡片") { status.showsStack = false }
            }
            .font(.caption)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(ShelfMotion.swap, value: pasteStack.entries.isEmpty)
    }
}
