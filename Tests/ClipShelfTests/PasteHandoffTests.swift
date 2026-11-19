import Testing
@testable import ClipShelf

@MainActor
struct PasteHandoffTests {
    @Test func directPasteRequiresBothSystemGrants() {
        #expect(DirectPasteAccess(accessibility: false, eventPosting: false) == .needsAccessibility)
        #expect(DirectPasteAccess(accessibility: false, eventPosting: true) == .needsAccessibility)
        #expect(DirectPasteAccess(accessibility: true, eventPosting: false) == .needsEventPosting)
        #expect(DirectPasteAccess(accessibility: true, eventPosting: true) == .ready)
    }

    @Test func missingAccessibilityFocusRequiresUninterruptedForeground() {
        #expect(PasteHandoff.matchesFocus(windowMatches: nil, inputMatches: nil, preserved: true))
        #expect(!PasteHandoff.matchesFocus(windowMatches: nil, inputMatches: nil, preserved: false))
        #expect(PasteHandoff.matchesFocus(windowMatches: nil, inputMatches: true, preserved: false))
        #expect(!PasteHandoff.matchesFocus(windowMatches: false, inputMatches: true, preserved: true))
        #expect(!PasteHandoff.matchesFocus(windowMatches: true, inputMatches: false, preserved: true))
    }

    @Test func sendsOnlyAfterOriginalInputHasReturned() async {
        var focus: [PasteHandoff.Focus] = [.switching, .wrongInput, .originalInput, .originalInput]
        var restores = 0
        var sends = 0
        let result = await PasteHandoff.sendWhenFocused(
            focus: { focus.removeFirst() },
            clipboardIsCurrent: { true },
            restore: { restores += 1 },
            send: {
                #expect(focus.isEmpty)
                sends += 1
                return true
            },
            wait: {}
        )
        #expect(result == .sent)
        #expect(restores == 1)
        #expect(sends == 1)
    }

    @Test(arguments: [PasteHandoff.Focus.wrongInput, .elsewhere])
    func neverSendsToDifferentInputOrApp(focus: PasteHandoff.Focus) async {
        let result = await PasteHandoff.sendWhenFocused(
            focus: { focus },
            clipboardIsCurrent: { true },
            restore: {},
            send: {
                Issue.record("Unexpected paste to an unconfirmed destination")
                return true
            },
            wait: {}
        )
        #expect(result == .focusLost)
    }

    @Test func abortsIfAnotherCopyReplacesTheClipboard() async {
        var checks = 0
        let result = await PasteHandoff.sendWhenFocused(
            focus: { .originalInput },
            clipboardIsCurrent: {
                checks += 1
                return checks < 3
            },
            restore: {},
            send: {
                Issue.record("Unexpected paste of changed clipboard")
                return true
            },
            wait: {}
        )
        #expect(result == .clipboardChanged)
    }
}
