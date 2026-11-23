import CoreGraphics

/// Decides which card leads the horizontal card strip so the selected card stays in view.
/// The strip is driven only by its leading card, so keyboard moves never fight a second scroll command.
enum ShelfCardScroll {
    static let cardWidth: CGFloat = 222
    static let spacing: CGFloat = 14
    static let inset: CGFloat = 18

    /// How many cards fit fully in a strip of the given width.
    static func fullyVisibleCount(width: CGFloat) -> Int {
        max(1, Int(((width - inset * 2 + spacing) / (cardWidth + spacing)).rounded(.down)))
    }

    /// The leading card index after selecting `selected`: unchanged while the selection is already
    /// in view, otherwise moved by the smallest amount that reveals it.
    static func leadingIndex(current: Int, selected: Int, fullyVisible: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        let fit = max(1, fullyVisible)
        let last = max(0, total - fit)
        let current = min(max(current, 0), last)
        let selected = min(max(selected, 0), total - 1)
        if selected < current { return selected }
        if selected >= current + fit { return min(selected - fit + 1, last) }
        return current
    }
}
