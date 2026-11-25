import AppKit
import SwiftUI

struct ShelfView: View {
    @Bindable var browser: ShelfBrowser
    @Bindable var status: ShelfStatus
    @Bindable var pasteStack: PasteStack
    let preferences: ShelfPreferences
    let sync: SyncEngine
    var onPaste: (Clip, Bool) -> Void
    var onCopy: (Clip, Bool) -> Void
    var onRequestAccess: () -> Void
    var onReturnToApp: () -> Void
    var onChooseImage: (Clip) -> Void
    var onSearchFieldInstalled: (NSTextField) -> Void
    var onReturnToCards: () -> Void
    var onOpenPreferences: () -> Void
    var onPasteNext: () -> Void
    var onDragState: (Bool) -> Void

    @State var showClearConfirmation = false
    @State var message: String?
    @State var groupEditor: GroupEditor?
    @State var groupName = ""
    @State var groupColor: ClipGroupColor = .teal
    @State var groupError: String?
    @State var groupToDelete: ClipGroup?
    @State var leadingCard: Clip.ID?
    @State var titleEditor: Clip?
    @State var titleDraft = ""
    @State var editError: String?
    @State var textEditorID: Clip.ID?
    @State var textDraft = ""
    @State var extractionID: Clip.ID?
    @State var selectingCards = false
    @FocusState var draftFocused: Bool
    @Namespace var boardSpace

    var store: ClipboardStore { browser.store }

    var body: some View {
        let visible = browser.results
        let selected = browser.selection(in: visible)
        let mode: ContentMode = status.showsStack ? .stack
            : browser.isPreviewing && selected != nil ? .preview
            : visible.isEmpty ? .empty : .cards
        VStack(spacing: 0) {
            toolbar
            pinboards
            hairline
            ZStack {
                switch mode {
                case .stack:
                    stackView.transition(ShelfMotion.content(from: .bottom))
                case .preview:
                    if let selected {
                        fullPreview(selected).id(selected.id).transition(
                            browser.moveDirection == 0 ? ShelfMotion.content(from: .bottom)
                                : ShelfMotion.page(direction: browser.moveDirection)
                        )
                    }
                case .empty:
                    ContentUnavailableView(
                        emptyTitle, systemImage: browser.favoritesOnly ? "star" : "clipboard",
                        description: Text(emptyHint)
                    )
                    .transition(.opacity)
                case .cards:
                    cards(visible, selected: selected?.id).transition(ShelfMotion.content(from: .top))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(ShelfMotion.swap, value: mode)
            .animation(mode == .preview ? ShelfMotion.select : nil, value: selected?.id)
            hairline
            footer(status.showsStack ? nil : selected, selection: status.showsStack ? [] : browser.selectedCards(in: visible))
        }
        .overlay {
            // A faint top-lit rim gives the glass panel an edge without a hard border.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .overlayPreferenceValue(TransformPickerAnchor.self) { anchor in
            ZStack {
                if let clip = status.transformClip {
                    transformPicker(clip, anchor: anchor)
                        .transition(.opacity)
                }
            }
            .animation(ShelfMotion.swap, value: status.transformClip?.id)
        }
        .tint(ShelfTheme.accent)
        .onChange(of: browser.opening) { _, _ in
            stopEditingText()
            extractionID = nil
            selectingCards = false
        }
        .onChange(of: browser.search) { _, _ in endMultiSelection() }
        .onChange(of: browser.contentType) { _, _ in endMultiSelection() }
        .onChange(of: store.groups.map(\.id)) { _, groupIDs in
            if let active = browser.groupID, !groupIDs.contains(active) {
                browser.groupID = nil
                endMultiSelection()
            }
        }
        .onChange(of: status.showsSnippetEditor) { _, showsEditor in
            if showsEditor { stopEditingText() }
        }
        .onChange(of: selected?.id, initial: true) { _, _ in
            if let selected {
                store.prewarmImage(selected)
            } else {
                browser.isPreviewing = false
            }
        }
        .alert("清空未收藏的历史？", isPresented: $showClearConfirmation) {
            Button("清空", role: .destructive, action: store.clearHistory)
            Button("取消", role: .cancel) {}
        } message: {
            Text("收藏的内容会保留。")
        }
        .alert("需要授权直接粘贴", isPresented: $status.showPasteAccessPrompt) {
            Button("请求系统授权", action: onRequestAccess)
            Button("返回手动粘贴", role: .cancel, action: onReturnToApp)
        } message: {
            Text("内容已放到剪贴板。请在系统设置中允许 Kippet 使用辅助功能。授权后，从原输入框重新打开 Kippet 即可直接粘贴。")
        }
        .sheet(item: $groupEditor) { editor in
            groupEditorSheet(editor)
        }
        .sheet(item: $titleEditor) { clip in titleEditorSheet(clip) }
        .sheet(item: $status.ruleDraft) { rule in
            ClipRuleEditor(rule: rule, store: store)
        }
        .sheet(item: $status.snippetDraft) { draft in
            ShelfSnippetEditor(
                groups: store.groups, draft: draft,
                onSave: saveSnippet, onCancel: { status.snippetDraft = nil }
            )
        }
        .alert("删除收藏分组？", isPresented: Binding(
            get: { groupToDelete != nil },
            set: { if !$0 { groupToDelete = nil } }
        ), presenting: groupToDelete) { group in
            Button("删除分组", role: .destructive) { deleteGroup(group) }
            Button("取消", role: .cancel) {}
        } message: { group in
            Text(L("「%@」里的卡片仍会保留在收藏中。", group.name))
        }
    }

    private enum ContentMode: Hashable { case stack, preview, empty, cards }

    private var hairline: some View {
        Rectangle().fill(ShelfTheme.hairline).frame(height: 1).padding(.horizontal, 14)
    }

    func endMultiSelection() {
        selectingCards = false
        browser.clearMultiSelection()
    }

    private var hasActiveSearchFilters: Bool {
        !browser.search.isEmpty || browser.contentType != nil || browser.sourceName != nil
    }

    private var emptyTitle: String {
        if hasActiveSearchFilters { return L("没有匹配记录") }
        if selectedGroup != nil, browser.favoritesOnly { return L("分组里还没有卡片") }
        return browser.favoritesOnly ? L("暂无收藏") : L("暂无记录")
    }

    private var emptyHint: String {
        if hasActiveSearchFilters { return L("试试其他关键词、来源或内容类型") }
        if selectedGroup != nil, browser.favoritesOnly { return L("在历史中右键卡片，将它加入这个分组") }
        if browser.favoritesOnly { return L("收藏的记录会显示在这里") }
        if store.isCaptureDenied { return L("在系统设置中允许 Kippet 读取剪贴板") }
        return store.isPaused ? L("恢复记录后，复制一段文字试试") : L("复制文字、链接、图片或文件即可开始")
    }

    func copy(_ clip: Clip, asFile: Bool = false) {
        message = nil
        onCopy(clip, asFile)
    }

    func copyText(_ text: String) {
        copy(Clip(id: UUID(), payload: .text(text, rtf: nil, html: nil), date: .now))
    }

    func toggleFavorite(_ clip: Clip) {
        status.pasteMessage = nil
        if store.toggleFavorite(clip.id) {
            message = clip.isFavorite ? L("已取消星标") : L("已添加星标")
        } else {
            message = L("收藏空间已满")
        }
    }
}
