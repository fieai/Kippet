import SwiftUI

extension ShelfView {
    func footer(_ clip: Clip?, selection: [Clip]) -> some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                if let error = store.storageError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ShelfTheme.warning)
                        .id(error)
                        .transition(ShelfToastTransition.transition)
                } else if let feedback = status.pasteMessage ?? message {
                    let tone = ShelfFeedback.tone(for: feedback)
                    Label(feedback, systemImage: tone.symbol)
                        .labelStyle(FeedbackLabelStyle(tone: tone))
                        .lineLimit(2)
                        .id(feedback)
                        .transition(ShelfToastTransition.transition)
                        .task(id: feedback) { await expireFeedback(feedback, after: tone.lifetime) }
                } else {
                    if !status.showsStack {
                        // One line, so moving between text and image cards never changes the footer's height.
                        HStack(spacing: 0) {
                            Text(browser.isPreviewing
                                 ? L("← → 切换预览　空格关闭　↩ 粘贴")
                                 : L("← → 选卡片　空格预览　⌘／⇧ 点击多选　⌘1–9 快贴"))
                            if selection.count == 1, clip?.storedPayload.supportsPlainText == true {
                                Text(verbatim: "　")
                                Text("⌥↩ 处理后粘贴")
                            }
                        }
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(browser.isPreviewing)
                        .transition(.opacity)
                    }
                }
                if browser.canUndoDeletion {
                    Button("撤销删除") {
                        if browser.undoDeletion() { status.pasteMessage = L("已撤销删除") }
                    }
                    .buttonStyle(.link)
                    .help("⌘Z")
                }
                if status.directPasteAccess != .ready {
                    Button("开启直接粘贴…", action: onRequestAccess)
                        .buttonStyle(.link)
                }
                if !status.shortcutAvailable {
                    Text(L("%@ 不可用，可从菜单栏打开", status.shortcutLabel))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .animation(ShelfMotion.swap, value: status.pasteMessage ?? message)
            .animation(ShelfMotion.swap, value: store.storageError)
            .animation(ShelfMotion.swap, value: browser.canUndoDeletion)
            .animation(ShelfMotion.swap, value: browser.isPreviewing)

            Spacer(minLength: 10)

            if selection.count > 1 {
                Text("已选 \(selection.count) 项").font(.caption)
                    .contentTransition(.numericText())
                    .animation(ShelfMotion.select, value: selection.count)
                Menu("归入钉板") {
                    ForEach(store.groups) { group in
                        Button(group.name) { addCards(Set(selection.map(\.id)), to: group) }
                    }
                }
                .disabled(store.groups.isEmpty)
                .help(store.groups.isEmpty ? L("请先新建钉板") : L("把所选卡片归入同一个钉板"))
                Menu("拼接粘贴") {
                    Button("用换行拼接") { pasteJoined(selection, separator: "\n") }
                    Button("用空格拼接") { pasteJoined(selection, separator: " ") }
                }
                .disabled(!selection.allSatisfy { $0.storedPayload.supportsPlainText })
                .help("拼接支持文字和链接")
                Button("加入粘贴栈") { appendToStack(selection) }
                Button("取消多选", action: endMultiSelection)
            } else if let clip {
                if !browser.isPreviewing {
                    Button(selectingCards ? L("退出多选") : L("多选")) {
                        if selectingCards { endMultiSelection() } else { selectingCards = true }
                    }
                }
                Button {
                    toggleFavorite(clip)
                } label: {
                    Image(systemName: clip.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(clip.isFavorite ? Color.orange : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(ShelfMotion.lift, value: clip.isFavorite)
                }
                .accessibilityLabel(clip.isFavorite ? L("取消星标") : L("添加星标"))
                .help(clip.isFavorite ? L("取消星标") : L("添加星标"))

                Button(browser.isPreviewing ? L("关闭预览") : L("预览")) {
                    stopEditingText()
                    onReturnToCards()
                    browser.togglePreview()
                }
                Button("复制") { copy(clip) }
                if clip.storedPayload.kind == .text {
                    Menu("粘贴为") { formatActions(clip) }
                        .fixedSize()
                }
                if clip.storedPayload.supportsPlainText {
                    Menu {
                        transformActions(clip)
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .fixedSize()
                    .accessibilityLabel("处理后粘贴")
                    .help("处理后粘贴　⌥↩")
                }
                Button("粘贴") { onPaste(clip, false) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .animation(ShelfMotion.swap, value: selection.count > 1)
        .animation(ShelfMotion.swap, value: browser.isPreviewing)
        .animation(ShelfMotion.select, value: selectingCards)
    }

    private func pasteJoined(_ clips: [Clip], separator: String) {
        status.pasteMessage = nil
        if let combined = browser.joined(clips, separator: separator) {
            onPaste(combined, true)
        } else {
            message = L("无法拼接。请检查内容类型和大小。")
        }
    }

    /// A message fades back to the keyboard hints once it has been read, unless something replaced it.
    private func expireFeedback(_ feedback: String, after seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        withAnimation(ShelfMotion.swap) {
            if status.pasteMessage == feedback { status.pasteMessage = nil }
            if message == feedback { message = nil }
        }
    }

    func appendToStack(_ clips: [Clip]) {
        status.pasteMessage = nil
        message = pasteStack.append(clips) ? L("已加入粘贴栈") : L("粘贴栈空间已满")
    }
}

private struct FeedbackLabelStyle: LabelStyle {
    let tone: ShelfFeedback.Tone

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(tone == .success ? ShelfTheme.accent : ShelfTheme.warning)
            configuration.title.foregroundStyle(.primary)
        }
    }
}
