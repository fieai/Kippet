import Testing
@testable import Kippet

struct ShelfCardScrollTests {
    @Test func countsFullyVisibleCards() {
        #expect(ShelfCardScroll.fullyVisibleCount(width: 0) == 1)
        #expect(ShelfCardScroll.fullyVisibleCount(width: 36 + 222) == 1)
        #expect(ShelfCardScroll.fullyVisibleCount(width: 36 + 222 * 3 + 14 * 2) == 3)
        #expect(ShelfCardScroll.fullyVisibleCount(width: 36 + 222 * 3 + 14 * 2 - 1) == 2)
    }

    @Test func keepsStripStillWhileSelectionIsInView() {
        for selected in 2..<6 {
            #expect(ShelfCardScroll.leadingIndex(current: 2, selected: selected, fullyVisible: 4, total: 20) == 2)
        }
    }

    @Test func stepsOneCardAtATimePastEitherEdge() {
        #expect(ShelfCardScroll.leadingIndex(current: 2, selected: 6, fullyVisible: 4, total: 20) == 3)
        #expect(ShelfCardScroll.leadingIndex(current: 2, selected: 1, fullyVisible: 4, total: 20) == 1)
        #expect(ShelfCardScroll.leadingIndex(current: 0, selected: 19, fullyVisible: 4, total: 20) == 16)
        #expect(ShelfCardScroll.leadingIndex(current: 9, selected: 0, fullyVisible: 4, total: 20) == 0)
    }

    @Test func clampsToTheEndsOfTheList() {
        #expect(ShelfCardScroll.leadingIndex(current: 18, selected: 19, fullyVisible: 4, total: 20) == 16)
        #expect(ShelfCardScroll.leadingIndex(current: 5, selected: 2, fullyVisible: 4, total: 3) == 0)
        #expect(ShelfCardScroll.leadingIndex(current: 3, selected: 0, fullyVisible: 4, total: 0) == 0)
    }
}
