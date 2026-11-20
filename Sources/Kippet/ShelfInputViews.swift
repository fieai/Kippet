import AppKit
import SwiftUI

struct ShelfSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    var placeholder = L("搜索剪贴板")
    var focusOnInstall = false
    var onCommand: ((Selector) -> Bool)?
    var onInstall: (NSTextField) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder, attributes: [.foregroundColor: NSColor.secondaryLabelColor]
        )
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(placeholder)
        field.delegate = context.coordinator
        onInstall(field)
        if focusOnInstall {
            DispatchQueue.main.async { [weak field] in field?.selectText(nil) }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if let editor = field.currentEditor() as? NSTextView {
            if !editor.hasMarkedText(), editor.string != text {
                editor.string = text
                editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            }
        } else if field.stringValue != text {
            field.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ShelfSearchField

        init(_ parent: ShelfSearchField) { self.parent = parent }

        func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
            parent.isEditing = true
            return true
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            return parent.onCommand?(selector) ?? false
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.isEditing = true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let editor = field.currentEditor() as? NSTextView {
                if !editor.hasMarkedText() { parent.text = editor.string }
            } else {
                parent.text = field.stringValue
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                parent.text = field.stringValue
            }
            parent.isEditing = false
        }
    }
}

struct ShelfWheelRegion: NSViewRepresentable {
    var onStep: (Int) -> Void

    func makeNSView(context: Context) -> Region {
        let region = Region()
        region.onStep = onStep
        return region
    }

    func updateNSView(_ region: Region, context: Context) { region.onStep = onStep }

    final class Region: NSView {
        var onStep: ((Int) -> Void)?
        private var monitor: Any?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === window, !event.hasPreciseScrollingDeltas,
                      abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                      bounds.contains(convert(event.locationInWindow, from: nil)),
                      let onStep
                else { return event }
                onStep(event.scrollingDeltaY < 0 ? 1 : -1)
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
