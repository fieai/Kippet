import SwiftUI

extension ShelfView {
    var selectedGroup: ClipGroup? {
        store.groups.first { $0.id == browser.groupID }
    }

    var pinboards: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        pinboardButton(L("历史"), symbol: "clock", color: ShelfTheme.accent, selected: !browser.favoritesOnly) {
                            selectBoard(favorites: false)
                        }
                        .id("history")
                        pinboardButton(L("全部收藏"), symbol: "star", color: .orange,
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

    func selectBoard(favorites: Bool, groupID: ClipGroup.ID? = nil) {
        stopEditingText()
        onReturnToCards()
        browser.favoritesOnly = favorites
        browser.groupID = groupID
        endMultiSelection()
        status.showsStack = false
        browser.selectedID = browser.results.first?.id
        browser.revealCards(cascade: false)
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

    func addCards(_ ids: Set<Clip.ID>, to group: ClipGroup) {
        status.pasteMessage = nil
        message = store.addCards(ids, to: group.id)
            ? L("已归入「%@」", group.name) : L("无法归入钉板，请检查卡片或收藏容量")
    }

    struct GroupEditor: Identifiable {
        let id = UUID()
        let group: ClipGroup?
        let clipID: Clip.ID?
    }

    func editGroup(_ group: ClipGroup? = nil, adding clipID: Clip.ID? = nil) {
        groupName = group?.name ?? ""
        groupColor = group?.color ?? .teal
        groupError = nil
        groupEditor = GroupEditor(group: group, clipID: clipID)
    }

    func groupEditorSheet(_ editor: GroupEditor) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editor.group == nil ? L("新建收藏分组") : L("重命名收藏分组"))
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
                            .animation(ShelfMotion.select, value: groupColor)
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
                    .transition(ShelfMotion.inlineNote)
            }
            HStack {
                Spacer()
                Button("取消") { groupEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button(editor.group == nil ? L("新建") : L("保存")) { saveGroup(editor) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 330)
        .animation(ShelfMotion.lift, value: groupError)
    }

    private func saveGroup(_ editor: GroupEditor) {
        status.pasteMessage = nil
        if let group = editor.group {
            guard store.renameGroup(group.id, name: groupName, color: groupColor) else {
                groupError = L("无法保存分组。请检查名称是否重复或太长。")
                return
            }
            message = L("已重命名分组")
        } else {
            guard let group = store.createGroup(name: groupName, color: groupColor) else {
                groupError = L("无法新建分组。请检查名称是否重复或太长。")
                return
            }
            if let clipID = editor.clipID {
                message = store.toggleGroup(group.id, for: clipID)
                    ? L("已加入「%@」", group.name) : L("已新建分组，未能加入这张卡片")
            } else {
                browser.favoritesOnly = true
                browser.groupID = group.id
                message = L("已新建分组")
            }
        }
        groupEditor = nil
    }

    func deleteGroup(_ group: ClipGroup) {
        store.removeGroup(group.id)
        if browser.groupID == group.id { browser.groupID = nil }
        status.pasteMessage = nil
        message = L("已删除分组")
    }

    func toggleMembership(_ group: ClipGroup, for clip: Clip, removing: Bool) {
        status.pasteMessage = nil
        if store.toggleGroup(group.id, for: clip.id) {
            message = removing ? L("已移出「%@」", group.name) : L("已加入「%@」", group.name)
        } else {
            message = L("无法更新分组，请检查收藏空间")
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
                        .scaleEffect(isTargeted && !ShelfMotion.reduceMotion ? 1.5 : 1)
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

struct PinboardCardDrop: ViewModifier {
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
            // One weight for every state: changing it would resize the chip and nudge its neighbours.
            .font(.system(size: 12, weight: .medium))
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
                        .transition(.opacity)
                }
            }
            .scaleEffect(isTargeted && !ShelfMotion.reduceMotion ? 1.06 : 1)
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
