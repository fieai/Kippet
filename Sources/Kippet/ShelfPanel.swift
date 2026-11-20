import AppKit
import SwiftUI

final class ShelfPanel: NSPanel {
    static let cornerRadius: CGFloat = 18
    static let materialMask: NSImage = {
        let radius = cornerRadius
        let side = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        return mask
    }()

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension ShelfDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideShelf()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updatePasteAccess()
        if status.isPinned, pasteTarget == nil,
           let frontmost = NSWorkspace.shared.frontmostApplication, frontmost != .current {
            pasteTarget = PasteTarget(application: frontmost)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        status.commandHeld = false
        Task { @MainActor [weak self] in
            guard let self, !window.isKeyWindow else { return }
            shelfLostFocus()
        }
    }

    func shelfLostFocus() {
        let action = status.panel.focusLoss(
            isDragging: status.isDragging,
            hasModal: window.attachedSheet != nil || NSApp.modalWindow != nil ||
                status.showPasteAccessPrompt || status.showsSnippetEditor || status.ruleDraft != nil
        )
        guard action != .ignore else { return }
        status.commandHeld = false
        if action == .clearPasteTarget {
            pasteTarget = nil
            keptOriginalFocus = false
            pasteTask?.cancel()
        } else {
            hideShelf(restoreApplication: false)
        }
    }

    private func monitorOutsideClicks() {
        guard outsideMouseMonitor == nil else { return }
        outsideMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.window.frame.contains(NSEvent.mouseLocation) else { return }
                self.shelfLostFocus()
            }
        }
    }

    func stopMonitoringOutsideClicks() {
        if let outsideMouseMonitor { NSEvent.removeMonitor(outsideMouseMonitor) }
        outsideMouseMonitor = nil
    }

    func toggleShelf() {
        if status.panel.shouldShow(isKey: window.isKeyWindow) {
            showShelf()
        } else {
            hideShelf()
        }
    }

    func configureWindow() {
        window.title = "Kippet"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.animationBehavior = .none
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        window.setFrame(shelfFrame(), display: false)
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        // The system backdrop and window shadow use this mask independently of the content layer.
        material.maskImage = ShelfPanel.materialMask
        material.wantsLayer = true
        material.layer?.cornerRadius = ShelfPanel.cornerRadius
        material.layer?.masksToBounds = true
        let host = NSHostingView(rootView: ShelfView(
            browser: browser,
            status: status,
            pasteStack: pasteStack,
            preferences: preferences,
            sync: sync,
            onPaste: { [weak self] clip, plainText in self?.paste(clip, plainText: plainText) },
            onCopy: { [weak self] clip, asFile in self?.copy(clip, asFile: asFile) },
            onRequestAccess: { [weak self] in self?.requestAccess() },
            onReturnToApp: { [weak self] in self?.hideShelf() },
            onChooseImage: { [weak self] clip in self?.chooseImage(for: clip) },
            onSearchFieldInstalled: { [weak self] field in self?.searchField = field },
            onReturnToCards: { [weak self] in
                if self?.window.makeFirstResponder(nil) == true { self?.status.searchFocused = false }
            },
            onOpenPreferences: { [weak self] in self?.showPreferences() },
            onPasteNext: { [weak self] in self?.pasteNextInStack(trigger: .button) },
            onDragState: { [weak self] dragging in
                guard let self else { return }
                status.isDragging = dragging
                if !dragging, !window.isKeyWindow { shelfLostFocus() }
            }
        ))
        // The window and edge constraints already determine the shelf's size.
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            host.topAnchor.constraint(equalTo: material.topAnchor),
            host.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        window.contentView = material
        startMonitoringShelfKeys()
    }

    @objc func showShelf() {
        guard status.panel.shouldShow(isKey: window.isKeyWindow) else { return }
        pasteTask?.cancel()
        let frontmost = NSWorkspace.shared.frontmostApplication
        pasteTarget = frontmost.flatMap { $0 == .current ? nil : PasteTarget(application: $0, openingShelf: true) }
        keptOriginalFocus = pasteTarget != nil
        cancelScheduledCapture()
        recordClipboard(from: frontmost, allowed: allowsCapture(
            from: frontmost, stable: lastPolledActivation == activationSerial
        ))
        sync.requestSync()
        browser.open()
        status.commandHeld = false
        let frame = shelfFrame()
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        status.panel.open()
        presentWindow(at: frame)
        window.makeKey()
        window.makeFirstResponder(nil)
        monitorOutsideClicks()
    }

    private func presentWindow(at frame: NSRect) {
        windowTransition &+= 1
        window.ignoresMouseEvents = false
        let wasVisible = window.isVisible && window.alphaValue > 0.98
        guard !ShelfMotion.reduceMotion, !wasVisible else {
            window.setFrame(frame, display: false)
            window.alphaValue = 1
            window.orderFrontRegardless()
            return
        }
        // Rise from just below the final position while fading in.
        window.setFrame(frame.offsetBy(dx: 0, dy: -26), display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = 1
        }
    }

    /// Paste hand-off needs the panel gone at once so focus returns; plain dismissals sink and fade.
    private func dismissWindow(animated: Bool) {
        windowTransition &+= 1
        let transition = windowTransition
        guard animated, !ShelfMotion.reduceMotion, window.isVisible else {
            window.orderOut(nil)
            window.alphaValue = 1
            return
        }
        window.ignoresMouseEvents = true
        let frame = window.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(frame.offsetBy(dx: 0, dy: -14), display: true)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.windowTransition == transition else { return }
                self.window.orderOut(nil)
                self.window.setFrame(frame, display: false)
                self.window.alphaValue = 1
                self.window.ignoresMouseEvents = false
            }
        }
    }

    private func shelfFrame() -> NSRect {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        else { return window.frame }
        let available = screen.visibleFrame.insetBy(dx: 14, dy: 12)
        return NSRect(x: available.minX, y: available.minY, width: available.width, height: min(382, available.height))
    }

    @discardableResult
    func hideShelf(cancelPaste: Bool = true, restoreApplication: Bool = true) -> PasteTarget? {
        if cancelPaste { pasteTask?.cancel() }
        let target = pasteTarget
        pasteTarget = nil
        keptOriginalFocus = false
        status.panel.close()
        browser.isPreviewing = false
        status.showsStack = false
        status.commandHeld = false
        status.isDragging = false
        status.isEditingClip = false
        status.snippetDraft = nil
        status.ruleDraft = nil
        status.searchFocused = false
        status.transformClip = nil
        stopMonitoringOutsideClicks()
        if restoreApplication, NSWorkspace.shared.frontmostApplication == .current {
            target?.activate()
        }
        dismissWindow(animated: cancelPaste)
        return target
    }

    @objc func newSnippet() {
        presentSnippet(SnippetDraft(groupID: browser.favoritesOnly ? browser.groupID : nil))
    }

    func presentSnippet(_ draft: SnippetDraft) {
        guard window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        showShelf()
        status.transformClip = nil
        status.showsStack = false
        status.snippetDraft = draft
    }
}
