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
        // A plain open starts on the cards, even when it interrupts a dismissal whose reset has not
        // run yet; refocusing a pinned shelf keeps what it shows. The paste stack entry point asks for
        // the stack after this.
        if !status.shelfIsOpen { status.showsStack = false }
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
        let spec = ShelfMotionSpec.self
        // Reopening while the shelf is still sinking picks up from where it is instead of restarting.
        let midDismiss = window.isVisible && window.alphaValue < 0.98
        let wasVisible = window.isVisible && !midDismiss
        guard !wasVisible else {
            window.setFrame(frame, display: false)
            window.alphaValue = 1
            window.orderFrontRegardless()
            return
        }
        let reduce = ShelfMotion.reduceMotion
        var duration = reduce ? spec.reducedFade : spec.windowRiseDuration
        if midDismiss {
            duration = reduce ? spec.reducedFade : spec.riseDuration(remainingFraction: 1 - Double(window.alphaValue))
            // A different screen means the old position says nothing about the new one.
            let sameScreen = window.frame.size == frame.size && abs(window.frame.minX - frame.minX) <= 1
                && abs(window.frame.minY - frame.minY) <= spec.windowSink + 1
            if !sameScreen {
                window.setFrame(frame.offsetBy(dx: 0, dy: reduce ? 0 : -spec.windowRise), display: false)
            }
        } else {
            window.setFrame(frame.offsetBy(dx: 0, dy: reduce ? 0 : -spec.windowRise), display: false)
            window.alphaValue = 0
        }
        window.orderFrontRegardless()
        let curve = spec.windowRiseCurve
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = reduce ? CAMediaTimingFunction(name: .easeOut)
                : CAMediaTimingFunction(controlPoints: curve.0, curve.1, curve.2, curve.3)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = 1
        }
    }

    /// Paste hand-off needs the panel gone at once so focus returns; plain dismissals sink and fade.
    /// `settle` resets what the panel shows once it is out of sight, so it never flashes back mid-fade.
    private func dismissWindow(animated: Bool, settle: @escaping @MainActor () -> Void) {
        windowTransition &+= 1
        let transition = windowTransition
        guard animated, window.isVisible else {
            window.orderOut(nil)
            window.alphaValue = 1
            settle()
            return
        }
        let spec = ShelfMotionSpec.self
        let reduce = ShelfMotion.reduceMotion
        window.ignoresMouseEvents = true
        let frame = window.frame
        let curve = spec.windowSinkCurve
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? spec.reducedFade : spec.windowSinkDuration
            context.timingFunction = reduce ? CAMediaTimingFunction(name: .easeIn)
                : CAMediaTimingFunction(controlPoints: curve.0, curve.1, curve.2, curve.3)
            window.animator().setFrame(frame.offsetBy(dx: 0, dy: reduce ? 0 : -spec.windowSink), display: true)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.windowTransition == transition else { return }
                self.window.orderOut(nil)
                self.window.setFrame(frame, display: false)
                self.window.alphaValue = 1
                self.window.ignoresMouseEvents = false
                settle()
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
        dismissWindow(animated: cancelPaste) { [weak self] in
            guard let self, !self.status.shelfIsOpen else { return }
            self.browser.isPreviewing = false
            self.status.showsStack = false
        }
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
