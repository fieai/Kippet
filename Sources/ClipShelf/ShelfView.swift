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

    @State private var showClearConfirmation = false
    @State private var message: String?
    @State private var groupEditor: GroupEditor?
    @State private var groupName = ""
    @State private var groupColor: ClipGroupColor = .teal
    @State private var groupError: String?
    @State private var groupToDelete: ClipGroup?
    @State private var leadingCard: Clip.ID?
    @State private var titleEditor: Clip?
    @State private var titleDraft = ""
    @State private var editError: String?
    @State private var textEditorID: Clip.ID?
    @State private var textDraft = ""
    @State private var extractionID: Clip.ID?
    @State private var selectingCards = false
    @FocusState private var draftFocused: Bool
    @Namespace private var boardSpace

    private var store: ClipboardStore { browser.store }

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
                    stackView.transition(contentTransition(from: .bottom))
                case .preview:
                    if let selected {
                        fullPreview(selected).id(selected.id).transition(contentTransition(from: .bottom))
                    }
                case .empty:
                    ContentUnavailableView(
                        emptyTitle, systemImage: browser.favoritesOnly ? "star" : "clipboard",
                        description: Text(emptyHint)
                    )
                    .symbolEffect(.bounce, value: browser.opening)
                    .transition(.opacity)
                case .cards:
                    cards(visible, selected: selected?.id).transition(contentTransition(from: .top))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(ShelfMotion.swap, value: mode)
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
            if let clip = status.transformClip { transformPicker(clip, anchor: anchor) }
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
            Text("内容已放到剪贴板。请在系统设置中允许 TapV 使用辅助功能。授权后，从原输入框重新打开 TapV 即可直接粘贴。")
        }
        .sheet(item: $groupEditor) { editor in
            groupEditorSheet(editor)
        }
        .sheet(item: $titleEditor) { clip in titleEditorSheet(clip) }
        .sheet(item: $status.ruleDraft) { rule in
            ClipRuleEditor(rule: rule, store: store)
        }
        .sheet(item: $status.snippetDraft) { draft in
            SnippetEditor(
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
            Text("「\(group.name)」里的卡片仍会保留在收藏中。")
        }
    }

    private enum ContentMode: Hashable { case stack, preview, empty, cards }

    private struct TransformPickerAnchor: PreferenceKey {
        static let defaultValue: Anchor<CGRect>? = nil

        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
            if let anchor = nextValue() { value = anchor }
        }
    }

    private func contentTransition(from edge: Edge) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: edge == .bottom ? 14 : -10)),
            removal: .opacity
        )
    }

    private var hairline: some View {
        Rectangle().fill(ShelfTheme.hairline).frame(height: 1).padding(.horizontal, 14)
    }

    private var toolbar: some View {
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
                Label(pasteStack.entries.isEmpty ? "粘贴栈" : "粘贴栈 · \(pasteStack.entries.count)",
                      systemImage: pasteStack.isCollecting ? "record.circle" : "tray.full")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(status.showsStack ? ShelfTheme.accent : .primary)
            .contentTransition(.numericText())
            .animation(ShelfMotion.lift, value: pasteStack.entries.count)
            .accessibilityAddTraits(status.showsStack ? .isSelected : [])

            Button {
                status.isPinned.toggle()
            } label: {
                Image(systemName: status.isPinned ? "pin.fill" : "pin")
                    .rotationEffect(.degrees(status.isPinned ? 0 : 35))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(ShelfGlyphButtonStyle(isActive: status.isPinned))
            .help(status.isPinned ? "取消钉住面板" : "钉住面板")
            .accessibilityLabel(status.isPinned ? "取消钉住面板" : "钉住面板")
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
                Button(store.isPaused ? "恢复记录" : "暂停记录", action: store.toggleCapture)
                Button("开启直接粘贴…", action: onRequestAccess)
                Button("设置…", action: onOpenPreferences)
                Divider()
                Button("清空未收藏的历史…", role: .destructive) { showClearConfirmation = true }
                    .disabled(!store.clips.contains { !$0.isSaved })
            } label: {
                Image(systemName: store.isPaused ? "pause.circle" : "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(store.isPaused ? "已暂停 · 更多操作" : "更多操作")

            Button(action: onReturnToApp) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(ShelfGlyphButtonStyle())
            .help("收起 TapV")
            .accessibilityLabel("收起 TapV")
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
                .transition(.scale(scale: 0.6).combined(with: .opacity))
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
        .animation(ShelfMotion.lift, value: searchFocused)
        .help("搜索剪贴板　\(preferences.shortcut(for: .search).label)")
    }

    private var selectedGroup: ClipGroup? {
        store.groups.first { $0.id == browser.groupID }
    }

    private var pinboards: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        pinboardButton("历史", symbol: "clock", color: ShelfTheme.accent, selected: !browser.favoritesOnly) {
                            selectBoard(favorites: false)
                        }
                        .id("history")
                        pinboardButton("全部收藏", symbol: "star", color: .orange,
                                       selected: browser.favoritesOnly && browser.groupID == nil) {
                            selectBoard(favorites: true)
                        }
                        .id("favorites")
                        ForEach(store.groups) { group in
                            PinboardTab(
                                group: group,
                                isSelected: browser.favoritesOnly && browser.groupID == group.id,
                                select: { selectBoard(favorites: true, groupID: group.id) },
                                addCard: { addCards([$0], to: group) },
                                moveBoard: { store.moveGroup($0, onto: group.id) },
                                onDragState: onDragState,
                                namespace: boardSpace
                            )
                            .contextMenu {
                                Button("重命名或改色…") { editGroup(group) }
                                Button("删除分组…", role: .destructive) { groupToDelete = group }
                            }
                            .id(group.id.uuidString)
                        }
                    }
                    .animation(ShelfMotion.glide, value: visibleBoardID)
                    .animation(ShelfMotion.list, value: store.groups.map(\.id))
                }
                .scrollIndicators(.hidden)
                .onChange(of: visibleBoardID) { _, id in withAnimation(ShelfMotion.glide) { proxy.scrollTo(id) } }
            }
            Button { editGroup() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(ShelfGlyphButtonStyle(size: 24))
            .help("新建钉板")
            .accessibilityLabel("新建钉板")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 9)
    }

    private var visibleBoardID: String {
        guard browser.favoritesOnly else { return "history" }
        return browser.groupID?.uuidString ?? "favorites"
    }

    private func selectBoard(favorites: Bool, groupID: ClipGroup.ID? = nil) {
        stopEditingText()
        onReturnToCards()
        browser.favoritesOnly = favorites
        browser.groupID = groupID
        endMultiSelection()
        status.showsStack = false
        browser.selectedID = browser.results.first?.id
        browser.revealCards()
    }

    private func pinboardButton(_ title: String, symbol: String, color: Color,
                                selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .modifier(PinboardStyle(tint: color, isSelected: selected, namespace: boardSpace))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func addCards(_ ids: Set<Clip.ID>, to group: ClipGroup) {
        status.pasteMessage = nil
        message = store.addCards(ids, to: group.id)
            ? "已归入「\(group.name)」" : "无法归入钉板，请检查卡片或收藏容量"
    }

    private func endMultiSelection() {
        selectingCards = false
        browser.clearMultiSelection()
    }

    private func saveSnippet(_ title: String, _ content: String, _ groupID: ClipGroup.ID?) -> Bool {
        guard let clip = store.createSnippet(title: title, content: content, in: groupID) else { return false }
        browser.search = ""
        browser.contentType = nil
        browser.sourceName = nil
        browser.sourceBundleIdentifier = nil
        selectBoard(favorites: true, groupID: groupID)
        browser.isPreviewing = false
        browser.selectedID = clip.id
        status.snippetDraft = nil
        status.pasteMessage = nil
        message = "已保存片段"
        return true
    }

    private var sourceMenu: some View {
        Menu {
            Picker("来源应用", selection: sourceSelection) {
                Text("全部来源").tag(nil as String?)
                ForEach(sourceChoices) { source in Text(source.name).tag(Optional(source.id)) }
            }
            .pickerStyle(.inline)
        } label: {
            filterLabel(browser.sourceName ?? "全部来源", symbol: "app")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("来源应用")
        .accessibilityValue(browser.sourceName ?? "全部来源")
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

    private func filterBySource(_ source: ClipSource?) {
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

    private func cards(_ visible: [Clip], selected: Clip.ID?) -> some View {
        let shortcuts = Dictionary(uniqueKeysWithValues: visible.prefix(9).enumerated().map {
            ($0.element.id, $0.offset + 1)
        })
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    let revealing = Date.now.timeIntervalSince(browser.revealedAt) < 0.6
                    LazyHStack(spacing: 14) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, clip in
                            let isSelected = browser.multiSelection.isEmpty
                                ? selected == clip.id : browser.multiSelection.contains(clip.id)
                            ClipCard(
                                clip: clip, detection: store.detectionCache.result(for: clip), isSelected: isSelected,
                                shortcut: shortcuts[clip.id], commandHeld: status.commandHeld,
                                shelfIsOpen: status.shelfIsOpen,
                                onSource: { filterBySource($0) }, onDragState: onDragState
                            )
                            .frame(width: 222, height: max(145, geometry.size.height - 30))
                            .modifier(ShelfCardEntrance(index: index, animates: revealing && index < 12))
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.86, anchor: .bottom).combined(with: .opacity),
                                removal: .scale(scale: 0.8).combined(with: .opacity)
                            ))
                            .onTapGesture(count: 2) {
                                if !selectingCards, NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty {
                                    onPaste(clip, false)
                                }
                            }
                            .onTapGesture {
                                onReturnToCards()
                                let keys = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                                browser.selectCard(clip.id, extending: keys.contains(.shift),
                                                   toggling: selectingCards || keys.contains(.command))
                            }
                            .accessibilityAction {
                                onReturnToCards()
                                browser.selectCard(clip.id, toggling: selectingCards)
                            }
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .contextMenu { cardActions(clip) }
                            .anchorPreference(key: TransformPickerAnchor.self, value: .bounds) {
                                clip.id == status.transformClip?.id ? $0 : nil
                            }
                            .modifier(PinboardCardDrop(groupID: browser.favoritesOnly ? browser.groupID : nil) { id, groupID in
                                if store.moveCard(id, onto: clip.id, in: groupID) {
                                    status.pasteMessage = nil
                                    message = "已更新卡片顺序"
                                }
                            })
                            .id(clip.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                    .animation(ShelfMotion.list, value: visible.map(\.id))
                    .id(browser.revealCount)
                }
                .scrollPosition(id: $leadingCard, anchor: .leading)
                .background {
                    ShelfWheelRegion { step in
                        let current = visible.firstIndex(where: { $0.id == leadingCard }) ?? 0
                        let next = min(max(current + step, 0), visible.count - 1)
                        if next != current {
                            withAnimation(ShelfMotion.glide) { leadingCard = visible[next].id }
                        }
                    }
                }
                .onChange(of: selected, initial: true) { _, id in
                    if let id {
                        withAnimation(ShelfMotion.glide) {
                            proxy.scrollTo(id, anchor: id == visible.first?.id ? .leading : nil)
                        }
                    }
                }
                .onChange(of: browser.opening) { _, _ in
                    if let first = visible.first { proxy.scrollTo(first.id, anchor: .leading) }
                }
            }
        }
    }

    @ViewBuilder
    private func cardActions(_ clip: Clip) -> some View {
        Button("粘贴") { onPaste(clip, false) }
        Button("加入粘贴栈") { appendToStack([clip]) }
        if clip.payload.supportsPlainText {
            Button("粘贴为纯文本") { onPaste(clip, true) }
            Menu("处理后粘贴") { transformActions(clip) }
        }
        if clip.payload.kind == .text {
            Menu("粘贴为") { formatActions(clip) }
        }
        Button("复制") { copy(clip) }
        detectedContentActions(clip)
        if clip.payload.singleImageFile != nil {
            Button("复制原文件") { copy(clip, asFile: true) }
            if clip.imageSnapshot == nil {
                Button("选取图片文件…") { onChooseImage(clip) }
            }
        }
        Button("预览") {
            browser.selectedID = clip.id
            onReturnToCards()
            if !browser.isPreviewing { browser.togglePreview() }
        }
        Button("编辑卡片备注…") {
            titleDraft = clip.title ?? ""
            editError = nil
            titleEditor = clip
        }
        if clip.ocrImageData != nil {
            Button("提取图片中的文字") { showExtraction(clip) }
        }
        if clip.payload.kind == .text {
            Button("编辑正文…") { startEditingText(clip) }
        }
        Divider()
        Button("为此来源新建规则…") {
            status.ruleDraft = ClipRule(
                id: UUID(), name: "", isEnabled: true,
                match: .init(sourceBundleIdentifiers: clip.sourceBundleIdentifier.map { [$0] },
                             kinds: [clip.payload.kind]),
                action: .favorite
            )
        }
        Button(clip.isFavorite ? "取消星标" : "添加星标") { toggleFavorite(clip) }
        Menu("收藏分组") {
            ForEach(store.groups) { group in
                let isMember = clip.groupIDs?.contains(group.id) == true
                Button {
                    toggleMembership(group, for: clip, removing: isMember)
                } label: {
                    if isMember {
                        Label(group.name, systemImage: "checkmark")
                    } else {
                        Text(group.name)
                    }
                }
            }
            if !store.groups.isEmpty { Divider() }
            Button("新建分组…") { editGroup(adding: clip.id) }
        }
        Button("删除", role: .destructive) {
            if browser.delete(clip.id) {
                status.pasteMessage = nil
                message = "已删除卡片"
            }
        }
    }

    @ViewBuilder
    private func detectedContentActions(_ clip: Clip) -> some View {
        if let detection = store.detectionCache.result(for: clip) {
            switch detection {
            case let .color(red, green, blue, alpha, _):
                let color = ClipColor(red: red, green: green, blue: blue, alpha: alpha)
                ForEach(ClipColor.Notation.allCases) { notation in
                    Button("复制为 \(notation.rawValue)") { copyText(color.formatted(as: notation)) }
                }
            case let .oneTimeCode(code):
                Button("只复制验证码") { copyText(code) }
            case .email, .phone:
                if let action = detection.contactAction, let url = detection.contactURL {
                    Button(action) { NSWorkspace.shared.open(url) }
                }
            case .code:
                EmptyView()
            }
        }
        if let payloads = clip.barcodePayloads, !payloads.isEmpty {
            Button("复制二维码内容") { copyText(payloads.joined(separator: "\n")) }
            if let url = payloads.lazy.compactMap(ShelfLinkPreviewModel.previewURL(for:)).first {
                Button("打开链接") { NSWorkspace.shared.open(url) }
            }
        }
    }

    @ViewBuilder
    private func transformActions(_ clip: Clip) -> some View {
        ForEach(PasteTransform.Section.allCases, id: \.self) { section in
            if section != .cleanup { Divider() }
            ForEach(PasteTransform.allCases.filter { $0.section == section }) { transform in
                Button(transform.title) { pasteTransformed(clip, with: transform) }
            }
        }
    }

    @ViewBuilder
    private func formatActions(_ clip: Clip) -> some View {
        if case let .text(_, rtf, html) = clip.payload {
            Button("原格式") { onPaste(clip, false) }
            Button("纯文本") { onPaste(clip, true) }
            Button("Markdown") { pasteConverted(store.markdown(clip)) }
            Button("HTML 源码") { pasteConverted(store.htmlSource(clip)) }
                .disabled(html == nil && rtf == nil)
        }
    }

    private func transformPicker(_ clip: Clip, anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { geometry in
            let card = anchor.map { geometry[$0] }
            let width: CGFloat = 270
            let center = card?.midX ?? geometry.size.width / 2
            let x = min(max(center, width / 2 + 14), max(width / 2 + 14, geometry.size.width - width / 2 - 14))
            Color.clear.contentShape(Rectangle()).onTapGesture(perform: closeTransformPicker)
            PasteTransformPicker(lastUsed: preferences.lastPasteTransform, onPick: { transform in
                closeTransformPicker()
                pasteTransformed(clip, with: transform)
            }, onCancel: closeTransformPicker)
            .frame(width: width)
            .position(x: x, y: geometry.size.height / 2)
        }
    }

    private func closeTransformPicker() {
        onReturnToCards()
        status.transformClip = nil
    }

    private func pasteTransformed(_ clip: Clip, with transform: PasteTransform) {
        let result = store.transformed(clip, with: transform)
        if result != nil { preferences.lastPasteTransform = transform }
        pasteConverted(result)
    }

    private func pasteConverted(_ clip: Clip?) {
        if let clip {
            onPaste(clip, true)
        } else {
            status.pasteMessage = "没有可处理的内容"
        }
    }

    private var hasActiveSearchFilters: Bool {
        !browser.search.isEmpty || browser.contentType != nil || browser.sourceName != nil
    }

    private var emptyTitle: String {
        if hasActiveSearchFilters { return "没有匹配记录" }
        if selectedGroup != nil, browser.favoritesOnly { return "分组里还没有卡片" }
        return browser.favoritesOnly ? "暂无收藏" : "暂无记录"
    }

    private var emptyHint: String {
        if hasActiveSearchFilters { return "试试其他关键词、来源或内容类型" }
        if selectedGroup != nil, browser.favoritesOnly { return "在历史中右键卡片，将它加入这个分组" }
        if browser.favoritesOnly { return "收藏的记录会显示在这里" }
        if store.isCaptureDenied { return "在系统设置中允许 TapV 读取剪贴板" }
        return store.isPaused ? "恢复记录后，复制一段文字试试" : "复制文字、链接、图片或文件即可开始"
    }

    private func footer(_ clip: Clip?, selection: [Clip]) -> some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                if let error = store.storageError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if let feedback = status.pasteMessage ?? message {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                        .labelStyle(FeedbackLabelStyle())
                        .id(feedback)
                        .transition(ShelfToastTransition.transition)
                } else {
                    if !status.showsStack {
                        Text(browser.isPreviewing
                             ? "← → 切换预览　空格关闭　↩ 粘贴"
                             : "← → 选卡片　空格预览　⌘／⇧ 点击多选　⌘1–9 快贴")
                            .transition(.opacity)
                        if selection.count == 1, clip?.payload.supportsPlainText == true {
                            Text("⌥↩ 处理后粘贴")
                        }
                    }
                }
                if browser.canUndoDeletion {
                    Button("撤销删除") {
                        if browser.undoDeletion() { status.pasteMessage = "已撤销删除" }
                    }
                    .buttonStyle(.link)
                    .help("⌘Z")
                }
                if status.directPasteAccess != .ready {
                    Button("开启直接粘贴…", action: onRequestAccess)
                        .buttonStyle(.link)
                }
                if !status.shortcutAvailable {
                    Text("\(status.shortcutLabel) 不可用，可从菜单栏打开")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .animation(ShelfMotion.swap, value: status.pasteMessage ?? message)
            .animation(ShelfMotion.swap, value: browser.canUndoDeletion)

            Spacer(minLength: 10)

            if selection.count > 1 {
                Text("已选 \(selection.count) 项").font(.caption)
                Menu("归入钉板") {
                    ForEach(store.groups) { group in
                        Button(group.name) { addCards(Set(selection.map(\.id)), to: group) }
                    }
                }
                .disabled(store.groups.isEmpty)
                .help(store.groups.isEmpty ? "请先新建钉板" : "把所选卡片归入同一个钉板")
                Menu("拼接粘贴") {
                    Button("用换行拼接") { pasteJoined(selection, separator: "\n") }
                    Button("用空格拼接") { pasteJoined(selection, separator: " ") }
                }
                .disabled(!selection.allSatisfy { $0.payload.supportsPlainText })
                .help("拼接支持文字和链接")
                Button("加入粘贴栈") { appendToStack(selection) }
                Button("取消多选", action: endMultiSelection)
            } else if let clip {
                if !browser.isPreviewing {
                    Button(selectingCards ? "退出多选" : "多选") {
                        if selectingCards { endMultiSelection() } else { selectingCards = true }
                    }
                }
                Button {
                    toggleFavorite(clip)
                } label: {
                    Image(systemName: clip.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(clip.isFavorite ? Color.orange : .secondary)
                }
                .accessibilityLabel(clip.isFavorite ? "取消星标" : "添加星标")
                .help(clip.isFavorite ? "取消星标" : "添加星标")

                Button(browser.isPreviewing ? "关闭预览" : "预览") {
                    stopEditingText()
                    onReturnToCards()
                    browser.togglePreview()
                }
                Button("复制") { copy(clip) }
                if clip.payload.kind == .text {
                    Menu("粘贴为") { formatActions(clip) }
                        .fixedSize()
                }
                if clip.payload.supportsPlainText {
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
    }

    private func pasteJoined(_ clips: [Clip], separator: String) {
        status.pasteMessage = nil
        if let combined = browser.joined(clips, separator: separator) {
            onPaste(combined, true)
        } else {
            message = "无法拼接。请检查内容类型和大小。"
        }
    }

    private func appendToStack(_ clips: [Clip]) {
        status.pasteMessage = nil
        message = pasteStack.append(clips) ? "已加入粘贴栈" : "粘贴栈空间已满"
    }

    private var stackView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("粘贴栈").font(.headline)
                Text(status.stackShortcutAvailable
                     ? "\(status.stackShortcutLabel) 贴下一条"
                     : "\(status.stackShortcutLabel) 不可用，可点「贴下一条」")
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
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(pasteStack.entries.enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 8) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                Image(systemName: entry.clip.payload.kind.symbol)
                                    .foregroundStyle(ShelfTheme.tint(for: entry.clip.payload.kind))
                                Text(entry.clip.title ?? String(entry.clip.payload.previewText.prefix(240)))
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
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))
                        }
                    }
                    .animation(ShelfMotion.list, value: pasteStack.entries.map(\.id))
                }
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
    }

    private func fullPreview(_ clip: Clip) -> some View {
        let detection = store.detectionCache.result(for: clip)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(clip.title ?? detection?.label ?? clip.payload.kind.label,
                      systemImage: detection?.symbol ?? clip.payload.kind.symbol)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if clip.payload.kind == .text && textEditorID != clip.id {
                    Button("编辑正文…") { startEditingText(clip) }
                }
                if clip.ocrImageData != nil {
                    Button(extractionID == clip.id ? "查看图片" : "提取图片中的文字") {
                        if extractionID == clip.id { extractionID = nil } else { showExtraction(clip) }
                    }
                }
            }
            if textEditorID == clip.id {
                TextEditor(text: $textDraft)
                    .focused($draftFocused)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("卡片正文")
                HStack {
                    if let editError { Text(editError).foregroundStyle(.red).font(.caption) }
                    Spacer()
                    Button("取消", action: stopEditingText)
                    Button("保存") { saveText(clip, paste: false) }
                    Button("保存并粘贴") { saveText(clip, paste: true) }
                        .buttonStyle(.borderedProminent)
                }
            } else if case let .link(value) = clip.payload {
                ShelfLinkPreview(url: value)
            } else if clip.hasPendingSyncImage || clip.ocrImageData != nil {
                if extractionID == clip.id {
                    OCRTextPreview(id: clip.id, store: store, onCopy: copyText)
                } else {
                    ShelfThumbnail(clip: clip, maxPixelSize: 1400)
                }
            } else if let detection {
                DetectedContentView(detection: detection, source: clip.payload.previewText, copy: copyText)
            } else {
                ScrollView {
                    Text(clip.payload.previewText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func showExtraction(_ clip: Clip) {
        onReturnToCards()
        browser.selectCard(clip.id)
        if !browser.isPreviewing { browser.togglePreview() }
        extractionID = clip.id
    }

    private func startEditingText(_ clip: Clip) {
        guard case let .text(text, _, _) = clip.payload else { return }
        onReturnToCards()
        browser.selectedID = clip.id
        if !browser.isPreviewing { browser.togglePreview() }
        textEditorID = clip.id
        textDraft = text
        editError = nil
        status.isEditingClip = true
        draftFocused = true
    }

    private func stopEditingText() {
        guard textEditorID != nil else { return }
        draftFocused = false
        textEditorID = nil
        editError = nil
        status.isEditingClip = false
    }

    private func saveText(_ clip: Clip, paste: Bool) {
        guard let updated = store.editText(clip.id, text: textDraft) else {
            editError = "无法保存，请检查正文是否为空或超出容量。"
            return
        }
        stopEditingText()
        onReturnToCards()
        if paste {
            onPaste(updated, false)
        } else {
            status.pasteMessage = nil
            message = "已保存正文"
        }
    }

    private func titleEditorSheet(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("卡片备注").font(.headline)
            TextField("输入便于搜索的备注", text: $titleDraft)
                .textFieldStyle(.roundedBorder)
            if let editError { Text(editError).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("取消") { titleEditor = nil }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if store.rename(clip.id, title: titleDraft) {
                        titleEditor = nil
                    } else {
                        editError = "无法保存备注，请控制在 120 个字符以内。"
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 350)
    }

    private func copy(_ clip: Clip, asFile: Bool = false) {
        message = nil
        onCopy(clip, asFile)
    }

    private func copyText(_ text: String) {
        copy(Clip(id: UUID(), payload: .text(text, rtf: nil, html: nil), date: .now))
    }

    private func toggleFavorite(_ clip: Clip) {
        status.pasteMessage = nil
        if store.toggleFavorite(clip.id) {
            message = clip.isFavorite ? "已取消星标" : "已添加星标"
        } else {
            message = "收藏空间已满"
        }
    }

    private struct GroupEditor: Identifiable {
        let id = UUID()
        let group: ClipGroup?
        let clipID: Clip.ID?
    }

    private func editGroup(_ group: ClipGroup? = nil, adding clipID: Clip.ID? = nil) {
        groupName = group?.name ?? ""
        groupColor = group?.color ?? .teal
        groupError = nil
        groupEditor = GroupEditor(group: group, clipID: clipID)
    }

    private func groupEditorSheet(_ editor: GroupEditor) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editor.group == nil ? "新建收藏分组" : "重命名收藏分组")
                .font(.headline)
            TextField("分组名称", text: $groupName)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 10) {
                Text("颜色").foregroundStyle(.secondary)
                ForEach(ClipGroupColor.allCases, id: \.self) { color in
                    Button { groupColor = color } label: {
                        Circle()
                            .fill(color.shelfColor)
                            .frame(width: 16, height: 16)
                            .padding(3)
                            .overlay {
                                Circle().strokeBorder(groupColor == color ? Color.primary : .clear, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.label)
                    .accessibilityAddTraits(groupColor == color ? .isSelected : [])
                }
            }
            if let groupError {
                Text(groupError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { groupEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button(editor.group == nil ? "新建" : "保存") { saveGroup(editor) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 330)
    }

    private func saveGroup(_ editor: GroupEditor) {
        status.pasteMessage = nil
        if let group = editor.group {
            guard store.renameGroup(group.id, name: groupName, color: groupColor) else {
                groupError = "无法保存分组。请检查名称是否重复或太长。"
                return
            }
            message = "已重命名分组"
        } else {
            guard let group = store.createGroup(name: groupName, color: groupColor) else {
                groupError = "无法新建分组。请检查名称是否重复或太长。"
                return
            }
            if let clipID = editor.clipID {
                message = store.toggleGroup(group.id, for: clipID)
                    ? "已加入「\(group.name)」" : "已新建分组，未能加入这张卡片"
            } else {
                browser.favoritesOnly = true
                browser.groupID = group.id
                message = "已新建分组"
            }
        }
        groupEditor = nil
    }

    private func deleteGroup(_ group: ClipGroup) {
        store.removeGroup(group.id)
        if browser.groupID == group.id { browser.groupID = nil }
        status.pasteMessage = nil
        message = "已删除分组"
    }

    private func toggleMembership(_ group: ClipGroup, for clip: Clip, removing: Bool) {
        status.pasteMessage = nil
        if store.toggleGroup(group.id, for: clip.id) {
            message = removing ? "已移出「\(group.name)」" : "已加入「\(group.name)」"
        } else {
            message = "无法更新分组，请检查收藏空间"
        }
    }
}

private struct SnippetEditor: View {
    let groups: [ClipGroup]
    let onSave: (String, String, ClipGroup.ID?) -> Bool
    let onCancel: () -> Void
    @State private var groupID: ClipGroup.ID?
    @State private var title: String
    @State private var content: String
    @State private var error: String?
    @FocusState private var editingContent: Bool

    init(
        groups: [ClipGroup], draft: SnippetDraft,
        onSave: @escaping (String, String, ClipGroup.ID?) -> Bool, onCancel: @escaping () -> Void
    ) {
        self.groups = groups
        self.onSave = onSave
        self.onCancel = onCancel
        _groupID = State(initialValue: draft.groupID)
        _title = State(initialValue: draft.title)
        _content = State(initialValue: draft.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建片段").font(.headline)
            TextField("标题（可选）", text: $title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $content)
                .focused($editingContent)
                .font(.body)
                .frame(height: 116)
                .padding(5)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.3)) }
                .accessibilityLabel("片段正文或链接")
            Picker("保存到", selection: $groupID) {
                Text("全部收藏").tag(nil as ClipGroup.ID?)
                ForEach(groups) { Text($0.name).tag(Optional($0.id)) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") {
                    if !onSave(title, content, groupID) {
                        error = "无法保存，请检查标题长度、正文大小或收藏容量。"
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!content.contains { !$0.isWhitespace })
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { editingContent = true }
    }
}

private struct OCRTextPreview: View {
    let id: Clip.ID
    let store: ClipboardStore
    let onCopy: (String) -> Void
    @State private var text: String?
    @State private var completed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("复制识别文字") { onCopy(text) }
            } else if completed {
                Text(text == nil ? "暂时无法识别这张图片" : "未在图片中识别到文字")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("正在识别图片文字").controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: id) {
            let result = await store.recognizeText(id)
            guard !Task.isCancelled else { return }
            text = result
            completed = true
        }
    }
}

private struct ClipCard: View {
    let clip: Clip
    let detection: DetectedContent?
    let isSelected: Bool
    let shortcut: Int?
    let commandHeld: Bool
    let shelfIsOpen: Bool
    let onSource: (ClipSource) -> Void
    let onDragState: (Bool) -> Void
    @State private var hovering = false

    private var tint: Color { ShelfTheme.tint(for: clip.payload.kind) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ShelfTheme.cardRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 11)
                .padding(.top, 10)
                .padding(.bottom, 8)
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            meta
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
        }
        .background {
            shape.fill(ShelfTheme.cardFill)
            // A whisper of the content color washes down from the top edge.
            shape.fill(LinearGradient(colors: [tint.opacity(0.12), tint.opacity(0)],
                                      startPoint: .top, endPoint: .center))
        }
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(isSelected ? ShelfTheme.accent : Color.primary.opacity(hovering ? 0.16 : 0.08),
                              lineWidth: isSelected ? 2 : 1)
                .allowsHitTesting(false)
        }
        .shadow(color: isSelected ? ShelfTheme.accent.opacity(0.32) : .black.opacity(hovering ? 0.16 : 0.08),
                radius: isSelected ? 12 : hovering ? 9 : 3, y: isSelected ? 6 : hovering ? 4 : 1)
        .offset(y: isSelected ? -5 : hovering ? -2 : 0)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(ShelfMotion.lift, value: isSelected)
        .animation(ShelfMotion.lift, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let source = clip.source {
                Button { onSource(source) } label: { icon(source) }
                    .buttonStyle(.plain)
                    .help("只看来自「\(source.name)」的记录")
                    .accessibilityLabel("按来源筛选 \(source.name)")
            } else {
                icon(nil).accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(clip.title ?? clip.sourceName ?? clip.payload.kind.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 2) {
                    if clip.title != nil, let source = clip.sourceName {
                        Text("\(source) ·").lineLimit(1)
                    }
                    Text("\(Text(clip.date, style: .relative))前")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(clip.date.formatted(date: .abbreviated, time: .shortened))
            }
            Spacer(minLength: 0)
            if let shortcut {
                Text("⌘\(shortcut)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(commandHeld ? Color.white : .secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(commandHeld ? ShelfTheme.accent : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .scaleEffect(commandHeld ? 1.12 : 1)
                    .animation(ShelfMotion.lift, value: commandHeld)
                    .accessibilityLabel("快贴快捷键 Command \(shortcut)")
            }
            ShelfDragHandle(item: .card(clip), onDragState: onDragState)
                .frame(width: 14, height: 26)
                .overlay {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .opacity(hovering || isSelected ? 1 : 0.35)
                        .allowsHitTesting(false)
                }
                .help("拖出卡片")
        }
    }

    private var meta: some View {
        HStack(spacing: 5) {
            Label(detection?.label ?? clip.payload.kind.label, systemImage: detection?.symbol ?? clip.payload.kind.symbol)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(0.12), in: Capsule())
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if let expiry = clip.expiresAt {
                ClipExpiryBadge(expiry: expiry, tint: tint, shelfIsOpen: shelfIsOpen)
            }
            Spacer(minLength: 0)
            if let groups = clip.groupIDs, !groups.isEmpty {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("已加入收藏分组")
            }
            if clip.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("已加星标")
            }
        }
        .animation(ShelfMotion.lift, value: clip.isFavorite)
    }

    private var detail: String? {
        switch clip.payload {
        case let .text(text, _, _): "\(text.count) 字"
        case let .files(urls): urls.count > 1 ? "\(urls.count) 个文件" : nil
        case let .link(value): URLComponents(string: value)?.scheme?.uppercased()
        case .image: nil
        }
    }

    @ViewBuilder
    private func icon(_ source: ClipSource?) -> some View {
        if let appIcon = ShelfIconCache.shared.image(for: source?.bundleIdentifier) {
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
        } else {
            Image(systemName: clip.payload.kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private var preview: some View {
        if clip.hasPendingSyncImage || clip.ocrImageData != nil {
            ShelfThumbnail(clip: clip, maxPixelSize: 440, fills: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                }
                .overlay(alignment: .topTrailing) {
                    if clip.barcodePayloads?.isEmpty == false {
                        Image(systemName: "qrcode")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ShelfTheme.chipRadius))
                            .padding(5)
                            .accessibilityLabel("含二维码内容")
                    }
                }
                .padding(.horizontal, 9)
        } else if case let .link(value) = clip.previewPayload {
            VStack(alignment: .leading, spacing: 6) {
                if let host = URLComponents(string: value)?.host {
                    Label {
                        Text(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "globe")
                            .foregroundStyle(tint)
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
                Text(value)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
        } else {
            if let detection {
                DetectedContentView(detection: detection, source: clip.payload.previewText)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            } else {
                Text(String(clip.payload.previewText.prefix(640)))
                    .font(.system(size: 12.5))
                    .lineSpacing(2.5)
                    .lineLimit(9)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // Long text fades into the meta row rather than ending on a hard cut.
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0.72), .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
            }
        }
    }
}

private struct ClipExpiryBadge: View {
    let expiry: Date
    let tint: Color
    let shelfIsOpen: Bool
    @State private var inViewport = false

    var body: some View {
        Group {
            if shelfIsOpen, inViewport {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    badge(at: context.date)
                }
            } else {
                badge(at: .now)
            }
        }
        .fixedSize()
        .onGeometryChange(for: Bool.self) { geometry in
            let viewport = CGRect(origin: .zero, size: geometry.bounds(of: .scrollView)?.size ?? .zero)
            return geometry.frame(in: .scrollView).intersects(viewport)
        } action: { inViewport = $0 }
    }

    private func badge(at date: Date) -> some View {
        let remaining = max(0, expiry.timeIntervalSince(date))
        let countdown = Duration.seconds(remaining.rounded(.up)).formatted(.time(pattern: .minuteSecond))
        let color = remaining <= 15 ? ShelfTheme.warning : tint
        return Label(countdown, systemImage: "timer")
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel("删除倒计时 \(countdown)")
    }
}

private struct FeedbackLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(ShelfTheme.accent)
            configuration.title.foregroundStyle(.primary)
        }
    }
}

private struct PinboardTab: View {
    let group: ClipGroup
    let isSelected: Bool
    let select: () -> Void
    let addCard: @MainActor @Sendable (Clip.ID) -> Void
    let moveBoard: @MainActor @Sendable (ClipGroup.ID) -> Void
    let onDragState: (Bool) -> Void
    let namespace: Namespace.ID
    @State private var isTargeted = false

    var body: some View {
        let tint = (group.color ?? .teal).shelfColor
        HStack(spacing: 5) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                        .scaleEffect(isTargeted ? 1.5 : 1)
                    Text(group.name).lineLimit(1).frame(maxWidth: 160)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            ShelfDragHandle(item: .pinboard(group.id), onDragState: onDragState)
                .frame(width: 12, height: 22)
                .overlay {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                .help("拖动排序钉板")
        }
        .modifier(PinboardStyle(tint: tint, isSelected: isSelected, namespace: namespace, isTargeted: isTargeted))
        .contentShape(Rectangle())
        .onDrop(of: [ShelfDrag.cardType.rawValue, ShelfDrag.pinboardType], isTargeted: $isTargeted) { providers in
            ShelfDrag.receiveID(from: providers, type: ShelfDrag.pinboardType, perform: moveBoard)
                || ShelfDrag.receiveID(from: providers, type: ShelfDrag.cardType.rawValue, perform: addCard)
        }
    }
}

private struct PinboardCardDrop: ViewModifier {
    let groupID: ClipGroup.ID?
    let move: @MainActor @Sendable (Clip.ID, ClipGroup.ID) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if let groupID {
            content
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: ShelfTheme.cardRadius, style: .continuous)
                            .strokeBorder(ShelfTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(ShelfMotion.lift, value: isTargeted)
                .onDrop(of: [ShelfDrag.cardType.rawValue], isTargeted: $isTargeted) { providers in
                    ShelfDrag.receiveID(from: providers, type: ShelfDrag.cardType.rawValue) { move($0, groupID) }
                }
        } else {
            content
        }
    }
}

/// Pinboard chips share one sliding highlight, so switching boards glides instead of blinking.
private struct PinboardStyle: ViewModifier {
    let tint: Color
    let isSelected: Bool
    let namespace: Namespace.ID
    var isTargeted = false
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ShelfTheme.chipRadius, style: .continuous)
        content
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background {
                if isSelected {
                    shape.fill(tint.opacity(0.18))
                        .overlay { shape.strokeBorder(tint.opacity(0.5), lineWidth: 1) }
                        .matchedGeometryEffect(id: "board-highlight", in: namespace)
                } else {
                    shape.fill(Color.primary.opacity(hovering ? 0.09 : 0.05))
                }
            }
            .overlay {
                if isTargeted {
                    shape.strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .scaleEffect(isTargeted ? 1.06 : 1)
            .onHover { hovering = $0 }
            .animation(ShelfMotion.lift, value: hovering)
            .animation(ShelfMotion.lift, value: isTargeted)
    }
}

private extension ClipGroupColor {
    var shelfColor: Color {
        switch self {
        case .teal: .teal
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .green: .green
        case .yellow: .yellow
        }
    }
}

@MainActor
private final class ShelfIconCache {
    static let shared = ShelfIconCache()
    private let cache = NSCache<NSString, Entry>()

    private init() { cache.countLimit = 100 }

    func image(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        let key = bundleIdentifier as NSString
        if let entry = cache.object(forKey: key) { return entry.image }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache.setObject(Entry(image: image), forKey: key)
        return image
    }

    private final class Entry {
        let image: NSImage?
        init(image: NSImage?) { self.image = image }
    }
}
