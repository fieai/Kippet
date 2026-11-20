@MainActor
enum PasteHandoff {
    enum Focus {
        case switching, originalInput, wrongInput, elsewhere
    }

    enum Result: Equatable {
        case sent, focusLost, clipboardChanged, keyUnavailable, cancelled
    }

    static func preservesFocus(
        keptOriginalFocus: Bool, shelfIsKey: @autoclosure () -> Bool, targetIsFrontmost: @autoclosure () -> Bool
    ) -> Bool {
        keptOriginalFocus && shelfIsKey() && targetIsFrontmost()
    }

    static func canHandoff(hasInputSnapshot: Bool, preserved: Bool) -> Bool {
        hasInputSnapshot || preserved
    }

    static func matchesFocus(windowMatches: Bool?, inputMatches: Bool?, preserved: Bool) -> Bool {
        windowMatches != false && (inputMatches ?? preserved)
    }

    static func sendWhenFocused(
        focus: () -> Focus,
        clipboardIsCurrent: () -> Bool,
        restore: () -> Void,
        send: () -> Bool,
        wait: () async -> Void = { try? await Task.sleep(for: .milliseconds(35)) }
    ) async -> Result {
        var requestedRestore = false
        var confirmedOnce = false
        for _ in 0..<20 {
            await wait()
            guard !Task.isCancelled else { return .cancelled }
            guard clipboardIsCurrent() else { return .clipboardChanged }

            switch focus() {
            case .elsewhere:
                return .focusLost
            case .switching:
                confirmedOnce = false
            case .wrongInput:
                confirmedOnce = false
                if !requestedRestore {
                    requestedRestore = true
                    restore()
                }
            case .originalInput:
                guard confirmedOnce else {
                    confirmedOnce = true
                    continue
                }
                guard clipboardIsCurrent() else { return .clipboardChanged }
                return send() ? .sent : .keyUnavailable
            }
        }
        return .focusLost
    }
}
