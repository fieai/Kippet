import AppKit
import SwiftUI

extension ShelfView {
    var toolbar: some View {
        HStack(spacing: 8) {
            searchBar
            Spacer(minLength: 6)

            Picker("类型", selection: $browser.contentType) {
                Text("全部类型").tag(nil as HistoryContentType?)
                ForEach(HistoryContentType.allCases, id: \.self) { type in
                    Text(type.label).tag(Optional(type))
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("内容类型")

            sourceMenu

            Button {
                stopEditingText()
                onReturnToCards()
                status.showsStack.toggle()
            } label: {
                Label {
                    Text(pasteStack.entries.isEmpty ? L("粘贴栈") : L("粘贴栈 · %lld", pasteStack.entries.count))
                        .contentTransition(.numericText())
                } icon: {
                    Image(systemName: pasteStack.isCollecting ? "record.circle" : "tray.full")
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(status.showsStack ? ShelfTheme.accent : .primary)
            .animation(ShelfMotion.lift, value: pasteStack.entries.count)
            .animation(ShelfMotion.lift, value: pasteStack.isCollecting)
            .animation(ShelfMotion.select, value: status.showsStack)
            .accessibilityAddTraits(status.showsStack ? .isSelected : [])

            Button {
                status.panel.togglePin()
            } label: {
                Image(systemName: status.isPinned ? "pin.fill" : "pin")
                    .rotationEffect(.degrees(status.isPinned ? 0 : 35))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(ShelfGlyphButtonStyle(isActive: status.isPinned))
            .help(status.isPinned ? L("取消钉住面板") : L("钉住面板"))
            .accessibilityLabel(status.isPinned ? L("取消钉住面板") : L("钉住面板"))
            .accessibilityAddTraits(status.isPinned ? .isSelected : [])

            if sync.isEnabled { ShelfSyncStatus(status: sync.status) }

            Menu {
                Button("新建片段…") {
                    status.showsStack = false
                    status.snippetDraft = SnippetDraft(groupID: selectedGroup?.id)
                }
                .help(preferences.shortcut(for: .newSnippet).label)
                if !status.showsStack, !browser.isPreviewing {
                    Button("全选当前结果") { _ = browser.selectAllCards() }
                }
                Button(store.isPaused ? L("恢复记录") : L("暂停记录"), action: store.toggleCapture)
                Button("开启直接粘贴…", action: onRequestAccess)
                Button("设置…", action: onOpenPreferences)
                Divider()
                Button("清空未收藏的历史…", role: .destructive) { showClearConfirmation = true }
                    .disabled(!store.clips.contains { !$0.isSaved })
            } label: {
                Image(systemName: store.isPaused ? "pause.circle" : "ellipsis.circle")
                    .contentTransition(.symbolEffect(.replace))
                    .animation(ShelfMotion.lift, value: store.isPaused)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(store.isPaused ? L("已暂停 · 更多操作") : L("更多操作"))

            Button(action: onReturnToApp) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(ShelfGlyphButtonStyle())
            .help("收起 Kippet")
            .accessibilityLabel("收起 Kippet")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private var searchBar: some View {
        let searchFocused = status.searchFocused
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(searchFocused ? ShelfTheme.accent : Color.secondary)
                .scaleEffect(searchFocused ? 1.08 : 1)
                .accessibilityHidden(true)
            ShelfSearchField(text: $browser.search, isEditing: $status.searchFocused, onInstall: onSearchFieldInstalled)
                .frame(height: 22)
            if !browser.search.isEmpty {
                Button {
                    browser.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 22, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .transition(ShelfMotion.badge)
                .accessibilityLabel("清空搜索")
            } else if !searchFocused {
                Text(preferences.shortcut(for: .search).label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .animation(ShelfMotion.lift, value: browser.search.isEmpty)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(minWidth: 145, idealWidth: 270, maxWidth: 340)
        .background(Color(nsColor: .textBackgroundColor).opacity(searchFocused ? 0.95 : 0.55), in: shape)
        .overlay {
            shape.strokeBorder(searchFocused ? ShelfTheme.accent.opacity(0.85) : ShelfTheme.hairline,
                               lineWidth: searchFocused ? 1.5 : 1)
                .allowsHitTesting(false)
        }
        .shadow(color: ShelfTheme.accent.opacity(searchFocused ? 0.28 : 0), radius: 8)
        .animation(ShelfMotion.select, value: searchFocused)
        .help(L("搜索剪贴板　%@", preferences.shortcut(for: .search).label))
    }

    private var sourceMenu: some View {
        Menu {
            Picker("来源应用", selection: sourceSelection) {
                Text("全部来源").tag(nil as String?)
                ForEach(sourceChoices) { source in Text(source.name).tag(Optional(source.id)) }
            }
            .pickerStyle(.inline)
        } label: {
            filterLabel(browser.sourceName ?? L("全部来源"), symbol: "app")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("来源应用")
        .accessibilityValue(browser.sourceName ?? L("全部来源"))
    }

    private var sourceSelection: Binding<String?> {
        Binding {
            browser.sourceName.map { ClipSource(name: $0, bundleIdentifier: browser.sourceBundleIdentifier).id }
        } set: { id in
            filterBySource(sourceChoices.first { $0.id == id })
        }
    }

    private var sourceChoices: [ClipSource] {
        let sources = store.sources
        if let name = browser.sourceName {
            let selected = ClipSource(name: name, bundleIdentifier: browser.sourceBundleIdentifier)
            if !sources.contains(selected) { return [selected] + sources }
        }
        return sources
    }

    func filterBySource(_ source: ClipSource?) {
        onReturnToCards()
        browser.sourceName = source?.name
        browser.sourceBundleIdentifier = source?.bundleIdentifier
        browser.clearMultiSelection()
        status.showsStack = false
        browser.selectedID = browser.results.first?.id
    }

    private func filterLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: 76)
        }
    }
}
