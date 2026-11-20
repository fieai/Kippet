struct ShelfPanelState: Sendable {
    enum FocusLoss {
        case ignore, clearPasteTarget, dismiss
    }

    private(set) var isOpen = false
    private(set) var isPinned = false

    func shouldShow(isKey: @autoclosure () -> Bool) -> Bool {
        !(isOpen && isKey())
    }

    mutating func open() {
        isOpen = true
    }

    mutating func close() {
        isOpen = false
        isPinned = false
    }

    mutating func togglePin() {
        isPinned.toggle()
    }

    func focusLoss(isDragging: @autoclosure () -> Bool, hasModal: @autoclosure () -> Bool) -> FocusLoss {
        guard isOpen, !isDragging(), !hasModal() else { return .ignore }
        return isPinned ? .clearPasteTarget : .dismiss
    }
}
