import AppKit
import SwiftUI

extension ShelfView {
    struct TransformPickerAnchor: PreferenceKey {
        static let defaultValue: Anchor<CGRect>? = nil

        static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
            if let anchor = nextValue() { value = anchor }
        }
    }

    func cards(_ visible: [Clip], selected: Clip.ID?) -> some View {
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
                            ShelfCard(
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
                                    message = L("已更新卡片顺序")
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
        if clip.storedPayload.supportsPlainText {
            Button("粘贴为纯文本") { onPaste(clip, true) }
            Menu("处理后粘贴") { transformActions(clip) }
        }
        if clip.storedPayload.kind == .text {
            Menu("粘贴为") { formatActions(clip) }
        }
        Button("复制") { copy(clip) }
        detectedContentActions(clip)
        if clip.storedPayload.singleImageFile != nil {
            Button("复制原文件") { copy(clip, asFile: true) }
            if !clip.hasImageSnapshot {
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
        if clip.hasPreviewImage {
            Button("提取图片中的文字") { showExtraction(clip) }
        }
        if clip.storedPayload.kind == .text {
            Button("编辑正文…") { startEditingText(clip) }
        }
        Divider()
        Button("为此来源新建规则…") {
            status.ruleDraft = ClipRule(
                id: UUID(), name: "", isEnabled: true,
                match: .init(sourceBundleIdentifiers: clip.sourceBundleIdentifier.map { [$0] },
                             kinds: [clip.storedPayload.kind]),
                action: .favorite
            )
        }
        Button(clip.isFavorite ? L("取消星标") : L("添加星标")) { toggleFavorite(clip) }
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
                message = L("已删除卡片")
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
                    Button(L("复制为 %@", notation.rawValue)) { copyText(color.formatted(as: notation)) }
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
    func transformActions(_ clip: Clip) -> some View {
        ForEach(PasteTransform.Section.allCases, id: \.self) { section in
            if section != .cleanup { Divider() }
            ForEach(PasteTransform.allCases.filter { $0.section == section }) { transform in
                Button(transform.title) { pasteTransformed(clip, with: transform) }
            }
        }
    }

    @ViewBuilder
    func formatActions(_ clip: Clip) -> some View {
        if case let .text(_, rtf, html) = clip.storedPayload {
            Button("原格式") { onPaste(clip, false) }
            Button("纯文本") { onPaste(clip, true) }
            Button("Markdown") { pasteConverted(store.markdown(clip)) }
            Button("HTML 源码") { pasteConverted(store.htmlSource(clip)) }
                .disabled(html == nil && rtf == nil)
        }
    }

    func transformPicker(_ clip: Clip, anchor: Anchor<CGRect>?) -> some View {
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
            status.pasteMessage = L("没有可处理的内容")
        }
    }
}
