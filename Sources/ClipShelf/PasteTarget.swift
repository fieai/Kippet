import AppKit
import ApplicationServices

@MainActor
struct PasteTarget {
    let application: NSRunningApplication
    private let accessibleApp: AXUIElement?
    private let window: AXUIElement?
    private let input: AXUIElement?

    init(application: NSRunningApplication, openingShelf: Bool = false) {
        self.application = application
        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(application.processIdentifier)
            accessibleApp = app
            if openingShelf {
                (input, window) = Self.openingFocus(in: app)
                AXUIElementSetMessagingTimeout(app, 0.1)
            } else {
                AXUIElementSetMessagingTimeout(app, 0.1)
                let focused = Self.focusedInput(in: app, pid: application.processIdentifier)
                input = focused
                window = Self.focusedWindow(in: app, input: focused)
            }
        } else {
            accessibleApp = nil
            window = nil
            input = nil
        }
    }

    var hasInputSnapshot: Bool { input != nil }

    func activate() {
        guard !application.isTerminated else { return }
        if NSApp.isActive {
            application.activate(from: .current, options: [])
        } else if !application.isActive {
            application.activate()
        }
    }

    func focusState(preserved: Bool) -> PasteHandoff.Focus {
        guard !application.isTerminated else { return .elsewhere }
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard frontmost == application else {
            return frontmost == nil || frontmost == .current ? .switching : .elsewhere
        }
        let liveInput = accessibleApp.flatMap { Self.focusedInput(in: $0, pid: application.processIdentifier) }
        let windowMatches = window.map { original in
            accessibleApp.flatMap { Self.focusedWindow(in: $0, input: liveInput) }
                .map { CFEqual($0, original) } ?? false
        }
        let inputMatches = input.map { original in liveInput.map { CFEqual($0, original) } ?? false }
        guard PasteHandoff.matchesFocus(
            windowMatches: windowMatches, inputMatches: inputMatches, preserved: preserved
        ) else { return .wrongInput }
        return NSWorkspace.shared.frontmostApplication == application ? .originalInput : .elsewhere
    }

    func restoreInput() {
        guard NSWorkspace.shared.frontmostApplication == application,
              let accessibleApp, let input else { return }
        let focused = Self.focusedWindow(in: accessibleApp, input: nil)
        if let window, focused.map({ CFEqual($0, window) }) != true {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func openingFocus(in app: AXUIElement) -> (AXUIElement?, AXUIElement?) {
        // All remote reads share a single budget before the panel takes keyboard focus.
        let deadline = DispatchTime.now().uptimeNanoseconds + 16_000_000
        func read(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now + 1_000_000,
                  AXUIElementSetMessagingTimeout(element, Float(deadline - now) / 1_000_000_000) == .success
            else { return nil }
            return Self.element(attribute, of: element)
        }
        let input = read(kAXFocusedUIElementAttribute, from: app)
        let window = read(kAXFocusedWindowAttribute, from: app) ?? input.flatMap { element in
            let window = read(kAXWindowAttribute, from: element)
            AXUIElementSetMessagingTimeout(element, 0)
            return window
        }
        return (input, window)
    }

    private static func focusedInput(in app: AXUIElement, pid: pid_t) -> AXUIElement? {
        if let input = element(kAXFocusedUIElementAttribute, of: app) { return input }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        guard let input = element(kAXFocusedUIElementAttribute, of: system) else { return nil }
        var owner: pid_t = 0
        return AXUIElementGetPid(input, &owner) == .success && owner == pid ? input : nil
    }

    private static func focusedWindow(in app: AXUIElement, input: AXUIElement?) -> AXUIElement? {
        element(kAXFocusedWindowAttribute, of: app) ?? input.flatMap { element(kAXWindowAttribute, of: $0) }
    }

    private static func element(_ attribute: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

@MainActor
enum PasteHandoff {
    enum Focus {
        case switching, originalInput, wrongInput, elsewhere
    }

    enum Result: Equatable {
        case sent, focusLost, clipboardChanged, keyUnavailable, cancelled
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
