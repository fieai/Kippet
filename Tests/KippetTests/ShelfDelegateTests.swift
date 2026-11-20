import Testing
@testable import Kippet

@MainActor
struct ShelfDelegateTests {
    @Test func pollingSkipsPausedUnchangedAndStaleChanges() {
        #expect(ShelfCapturePolicy.changeToPoll(current: 12, last: 11, isPaused: true) == nil)
        #expect(ShelfCapturePolicy.changeToPoll(current: 12, last: 12, isPaused: false) == nil)
        #expect(ShelfCapturePolicy.changeToPoll(current: 12, last: 11, isPaused: false, expected: 11) == nil)
        #expect(ShelfCapturePolicy.changeToPoll(current: 12, last: 11, isPaused: false, expected: 12) == 12)
        #expect(ShelfCapturePolicy.changeToPoll(current: 12, last: 11, isPaused: false) == 12)
    }

    @Test func pollingSchedulesOnlyNewPendingChanges() {
        #expect(ShelfCapturePolicy.changeToSchedule(pending: nil, scheduled: 11) == nil)
        #expect(ShelfCapturePolicy.changeToSchedule(pending: 11, scheduled: 11) == nil)
        #expect(ShelfCapturePolicy.changeToSchedule(pending: 11, scheduled: nil) == 11)
        #expect(ShelfCapturePolicy.changeToSchedule(pending: 12, scheduled: 11) == 12)
    }

    @Test func captureWithExclusionsRequiresAKnownStableAllowedSource() {
        let excluded = [ExcludedApp(id: "app.private", name: "Private")]
        #expect(ShelfCapturePolicy.allowsSource(bundleIdentifier: nil, stable: false, excluding: []))
        #expect(ShelfCapturePolicy.allowsSource(bundleIdentifier: "app.allowed", stable: true, excluding: excluded))
        #expect(!ShelfCapturePolicy.allowsSource(bundleIdentifier: "app.private", stable: true, excluding: excluded))
        #expect(!ShelfCapturePolicy.allowsSource(bundleIdentifier: "app.allowed", stable: false, excluding: excluded))
        #expect(!ShelfCapturePolicy.allowsSource(bundleIdentifier: nil, stable: true, excluding: excluded))
    }

    @Test func panelCanReopenWithoutKeyFocusAndClosingClearsPin() {
        var panel = ShelfPanelState()
        #expect(panel.shouldShow(isKey: false))
        panel.open()
        #expect(panel.isOpen)
        #expect(!panel.shouldShow(isKey: true))
        #expect(panel.shouldShow(isKey: false))
        panel.togglePin()
        #expect(panel.isPinned)
        panel.close()
        #expect(!panel.isOpen)
        #expect(!panel.isPinned)
    }

    @Test func outsideClickDismissesUnpinnedPanelAndRetainsPinnedPanel() {
        var panel = ShelfPanelState()
        #expect(panel.focusLoss(isDragging: false, hasModal: false) == .ignore)
        panel.open()
        #expect(panel.focusLoss(isDragging: true, hasModal: false) == .ignore)
        #expect(panel.focusLoss(isDragging: false, hasModal: true) == .ignore)
        #expect(panel.focusLoss(isDragging: false, hasModal: false) == .dismiss)
        panel.togglePin()
        #expect(panel.focusLoss(isDragging: false, hasModal: false) == .clearPasteTarget)
        #expect(panel.isOpen)
        panel.togglePin()
        #expect(panel.focusLoss(isDragging: false, hasModal: false) == .dismiss)
    }

    @Test func pasteWithoutSnapshotRequiresKeyShelfAndOriginalForeground() {
        #expect(PasteHandoff.preservesFocus(keptOriginalFocus: true, shelfIsKey: true, targetIsFrontmost: true))
        #expect(!PasteHandoff.preservesFocus(keptOriginalFocus: false, shelfIsKey: true, targetIsFrontmost: true))
        #expect(!PasteHandoff.preservesFocus(keptOriginalFocus: true, shelfIsKey: false, targetIsFrontmost: true))
        let preserved = PasteHandoff.preservesFocus(
            keptOriginalFocus: true, shelfIsKey: true, targetIsFrontmost: false
        )
        #expect(!preserved)
        #expect(!PasteHandoff.canHandoff(hasInputSnapshot: false, preserved: preserved))
        #expect(PasteHandoff.canHandoff(hasInputSnapshot: true, preserved: false))
        #expect(PasteHandoff.canHandoff(hasInputSnapshot: false, preserved: true))
    }

    @Test func pasteAbortsWhenTargetAppChangesAfterFirstConfirmation() async {
        var focus: ArraySlice<PasteHandoff.Focus> = [.originalInput, .elsewhere]
        let result = await PasteHandoff.sendWhenFocused(
            focus: { focus.popFirst() ?? .switching }, clipboardIsCurrent: { true },
            restore: { Issue.record("Unexpected focus restore in a different app") },
            send: {
                Issue.record("Unexpected paste after the target app changed")
                return true
            },
            wait: {}
        )
        #expect(result == .focusLost)
        #expect(focus.isEmpty)
    }

    @Test func pasteDiscardsEarlierConfirmationWhenInputChanges() async {
        var focus: ArraySlice<PasteHandoff.Focus> = [.originalInput, .wrongInput, .originalInput, .elsewhere]
        var restores = 0
        let result = await PasteHandoff.sendWhenFocused(
            focus: { focus.popFirst() ?? .switching }, clipboardIsCurrent: { true }, restore: { restores += 1 },
            send: {
                Issue.record("Unexpected paste before reconfirming the input")
                return true
            },
            wait: {}
        )
        #expect(result == .focusLost)
        #expect(restores == 1)
        #expect(focus.isEmpty)
    }
}
