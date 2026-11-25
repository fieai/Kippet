import AppKit
import Carbon
import Observation

enum HistoryContentType: Hashable, CaseIterable {
    case kind(ClipKind)
    case color, code, oneTimeCode

    static let allCases: [Self] = ClipKind.allCases.map(Self.kind) + [.color, .code, .oneTimeCode]

    var label: String {
        switch self {
        case let .kind(kind): kind.label
        case .color: L("颜色")
        case .code: L("代码")
        case .oneTimeCode: L("验证码")
        }
    }
}

@MainActor
@Observable
final class ShelfBrowser {
    let store: ClipboardStore

    var search = ""
    var contentType: HistoryContentType?
    var kind: ClipKind? {
        get {
            guard case let .kind(kind) = contentType else { return nil }
            return kind
        }
        set { contentType = newValue.map(HistoryContentType.kind) }
    }
    var favoritesOnly = false
    var sourceName: String?
    var sourceBundleIdentifier: String?
    var groupID: ClipGroup.ID?
    var selectedID: Clip.ID?
    private(set) var multiSelection: Set<Clip.ID> = []
    private var selectionAnchor: Clip.ID?
    var isPreviewing = false
    private(set) var opening = 0
    /// Bumped when the card row should rebuild and replay its entrance (opening, switching boards).
    private(set) var revealCount = 0
    /// When the cards were last revealed; cards created shortly after it play their entrance.
    @ObservationIgnored private(set) var revealedAt = Date.distantPast
    /// Opening the shelf cascades the front cards; switching boards only settles them together.
    @ObservationIgnored private(set) var revealCascades = true
    /// Which way the last arrow-key move went (-1, 0, 1), so the preview can slide the same way.
    @ObservationIgnored private(set) var moveDirection = 0
    private var lastDeletion: ClipboardStore.RemovedClip?

    private static let numberKeys = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ]

    init(store: ClipboardStore) {
        self.store = store
    }

    var results: [Clip] {
        store.filtered(
            query: search, contentType: contentType, favoritesOnly: favoritesOnly,
            sourceName: sourceName, groupID: favoritesOnly ? groupID : nil,
            sourceBundleIdentifier: sourceBundleIdentifier
        )
    }

    var selected: Clip? { selection(in: results) }
    var canUndoDeletion: Bool { lastDeletion != nil }

    func selection(in visible: [Clip]) -> Clip? {
        visible.first { $0.id == selectedID } ?? visible.first
    }

    func selectCard(_ id: Clip.ID, extending: Bool = false, toggling: Bool = false) {
        let visible = results
        guard let index = visible.firstIndex(where: { $0.id == id }) else { return }
        moveDirection = 0
        let previous = selection(in: visible)?.id
        if extending, let anchor = selectionAnchor ?? previous,
           let start = visible.firstIndex(where: { $0.id == anchor }) {
            let range = visible[min(index, start)...max(index, start)].map(\.id)
            multiSelection = toggling ? multiSelection.union(range) : Set(range)
            selectionAnchor = anchor
        } else if toggling {
            if multiSelection.isEmpty, let previous, previous != id { multiSelection.insert(previous) }
            if multiSelection.remove(id) == nil { multiSelection.insert(id) }
            selectionAnchor = id
        } else {
            clearMultiSelection()
            selectionAnchor = id
        }
        selectedID = multiSelection.isEmpty || multiSelection.contains(id)
            ? id : visible.first(where: { multiSelection.contains($0.id) })?.id
    }

    func clearMultiSelection() {
        multiSelection = []
        selectionAnchor = nil
    }

    func selectAllCards() -> Bool {
        let visible = results
        guard let selected = selection(in: visible) else { return false }
        multiSelection = Set(visible.map(\.id))
        selectedID = selected.id
        selectionAnchor = selected.id
        return true
    }

    func selectedCards(in visible: [Clip]) -> [Clip] {
        guard !multiSelection.isEmpty else { return selection(in: visible).map { [$0] } ?? [] }
        return visible.filter { multiSelection.contains($0.id) }
    }

    func joined(_ clips: [Clip], separator: String) -> Clip? {
        guard clips.count > 1, clips.allSatisfy({ $0.storedPayload.supportsPlainText }) else { return nil }
        let parts = clips.map(\.storedPayload.previewText)
        let limit = 8 * 1_024 * 1_024
        var size = separator.utf8.count * (parts.count - 1)
        for part in parts {
            size += part.utf8.count
            if size > limit { return nil }
        }
        return Clip(id: UUID(), payload: .text(parts.joined(separator: separator), rtf: nil, html: nil), date: .now)
    }

    func quickPaste(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Clip? {
        let keys = modifiers.intersection([.command, .option, .control, .shift])
        guard keys == .command || keys == [.command, .shift],
              let index = Self.numberKeys.firstIndex(of: Int(keyCode)) else { return nil }
        let visible = results
        guard visible.indices.contains(index) else { return nil }
        let clip = visible[index]
        return keys.contains(.shift) && !clip.storedPayload.supportsPlainText ? nil : clip
    }

    func open() {
        store.sweepExpired()
        clearMultiSelection()
        selectedID = results.first?.id
        isPreviewing = false
        opening += 1
        revealCards()
    }

    func revealCards(cascade: Bool = true) {
        revealedAt = .now
        revealCascades = cascade
        revealCount += 1
    }

    func togglePreview() {
        moveDirection = 0
        isPreviewing = !isPreviewing && selected != nil
    }

    @discardableResult
    func switchGroup(_ offset: Int) -> Bool {
        let groups = store.groups
        let currentGroup = groups.firstIndex { $0.id == groupID }
        let current = favoritesOnly ? (currentGroup.map { $0 + 2 } ?? 1) : 0
        let next = current + offset.signum()
        guard next != current, (0...groups.count + 1).contains(next) else { return false }
        favoritesOnly = next > 0
        clearMultiSelection()
        groupID = next > 1 ? groups[next - 2].id : nil
        selectedID = results.first?.id
        if selectedID == nil { isPreviewing = false }
        moveDirection = 0
        revealCards(cascade: false)
        return true
    }

    @discardableResult
    func deleteSelected() -> Bool {
        guard let id = selected?.id else { return false }
        return delete(id)
    }

    @discardableResult
    func delete(_ id: Clip.ID) -> Bool {
        let visible = results
        guard let deletion = store.remove(id) else { return false }
        moveDirection = 0
        multiSelection.remove(id)
        lastDeletion = deletion
        if selection(in: visible)?.id == id, let index = visible.firstIndex(where: { $0.id == id }) {
            let remaining = results
            selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
            if selectedID == nil { isPreviewing = false }
        }
        return true
    }

    func undoDeletion() -> Bool {
        guard let lastDeletion, store.restore(lastDeletion) else { return false }
        self.lastDeletion = nil
        moveDirection = 0
        if results.contains(where: { $0.id == lastDeletion.clip.id }) {
            selectedID = lastDeletion.clip.id
        }
        return true
    }

    @discardableResult
    func move(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, editingSearch: Bool, composing: Bool) -> Bool {
        let key = Int(keyCode)
        guard !composing, [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(key)
        else { return false }
        if editingSearch, !search.isEmpty, key == kVK_LeftArrow || key == kVK_RightArrow { return false }
        let keys = modifiers.intersection([.command, .option, .control, .shift])
        let visible = results
        guard !visible.isEmpty else { return false }

        let current = visible.firstIndex { $0.id == selectedID } ?? 0
        let next: Int
        switch (key, keys) {
        case (kVK_LeftArrow, []), (kVK_UpArrow, []):
            next = max(0, current - 1)
        case (kVK_RightArrow, []), (kVK_DownArrow, []):
            next = min(visible.count - 1, current + 1)
        case (kVK_UpArrow, .command):
            next = 0
        case (kVK_DownArrow, .command):
            next = visible.count - 1
        default:
            return false
        }
        moveDirection = (next - current).signum()
        selectedID = visible[next].id
        return true
    }
}
