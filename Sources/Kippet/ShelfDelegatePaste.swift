import AppKit
@preconcurrency import ApplicationServices
import OSLog
import UniformTypeIdentifiers

enum DirectPasteAccess: String {
    case needsAccessibility, needsEventPosting, ready

    init(accessibility: Bool, eventPosting: Bool) {
        if !accessibility {
            self = .needsAccessibility
        } else {
            self = eventPosting ? .ready : .needsEventPosting
        }
    }

    @MainActor
    static var current: Self {
        let accessibility = AXIsProcessTrusted()
        return Self(accessibility: accessibility, eventPosting: accessibility && CGPreflightPostEventAccess())
    }
}

extension ShelfDelegate {
    enum StackTrigger: String {
        case shortcut, button
    }

    func paste(_ clip: Clip, plainText: Bool) {
        status.pasteMessage = nil
        pasteTask?.cancel()
        pasteTask = Task { [weak self] in
            await self?.pasteWhenPrepared(clip, plainText: plainText)
        }
    }

    func copy(_ clip: Clip, asFile: Bool) {
        status.pasteMessage = nil
        pasteTask?.cancel()
        pasteTask = Task { [weak self] in
            guard let self else { return }
            let result = await store.copy(clip, asFile: asFile)
            if !Task.isCancelled {
                status.pasteMessage = result.message
                if case .written = result, preferences.copySound { NSSound(named: "Tink")?.play() }
            }
        }
    }

    @discardableResult
    private func pasteWhenPrepared(_ clip: Clip, plainText: Bool, stackAttempt: UInt64? = nil) async -> Bool {
        let asFile = pasteTarget?.application.bundleIdentifier == "com.apple.finder"
        let copy = await store.copy(clip, plainText: plainText, asFile: asFile)
        guard case let .written(change) = copy, !Task.isCancelled else {
            logStackCopy(stackAttempt, result: copy)
            guard !Task.isCancelled else { return false }
            status.pasteMessage = copy.message
            return false
        }
        logStackCopy(stackAttempt, result: copy)

        updatePasteAccess()
        guard status.directPasteAccess == .ready else {
            logStack(stackAttempt, event: "authorization", outcome: status.directPasteAccess.rawValue)
            pasteLog.notice("Direct paste requires authorization: \(self.status.directPasteAccess.rawValue, privacy: .public)")
            status.showPasteAccessPrompt = true
            return false
        }

        let preserved = PasteHandoff.preservesFocus(
            keptOriginalFocus: keptOriginalFocus, shelfIsKey: window.isKeyWindow,
            targetIsFrontmost: pasteTarget?.application == NSWorkspace.shared.frontmostApplication
        )
        let target = hideShelf(cancelPaste: false)
        guard let target, PasteHandoff.canHandoff(hasInputSnapshot: target.hasInputSnapshot, preserved: preserved) else {
            logStack(stackAttempt, event: "target", outcome: "no_original_input")
            pasteLog.notice("No original input or uninterrupted foreground session")
            status.pasteMessage = L("已复制。请在原输入框按 ⌘V。")
            return false
        }
        logStack(stackAttempt, event: "target", outcome: target.hasInputSnapshot ? "input_snapshot" : "foreground_preserved")
        return await sendPrepared(
            change: change, target: target, preserved: preserved, restoreOriginal: true, stackAttempt: stackAttempt
        )
    }

    private func sendPrepared(
        change: Int, target: PasteTarget, preserved: Bool, restoreOriginal: Bool, stackAttempt: UInt64?
    ) async -> Bool {
        let result = await PasteHandoff.sendWhenFocused(
            focus: { target.focusState(preserved: preserved) },
            clipboardIsCurrent: { store.isCurrentPasteboardChange(change) },
            restore: { if restoreOriginal { target.restoreInput() } },
            send: {
                logStack(stackAttempt, event: "focus", outcome: "confirmed")
                let sent = KeyboardLayout.sendPaste(to: target.application.processIdentifier)
                logStack(stackAttempt, event: "dispatch", outcome: sent ? "sent" : "unavailable")
                return sent
            }
        )
        switch result {
        case .sent:
            pasteLog.notice("Paste shortcut posted to the original application")
            return true
        case .cancelled:
            logStack(stackAttempt, event: "handoff", outcome: "cancelled")
        case .clipboardChanged:
            logStack(stackAttempt, event: "handoff", outcome: "clipboard_changed")
            pasteLog.notice("Clipboard changed before direct paste")
            status.pasteMessage = L("剪贴板已变化，直接粘贴已取消。")
        case .focusLost:
            logStack(stackAttempt, event: "focus", outcome: "lost")
            pasteLog.notice("Original input did not regain focus")
            status.pasteMessage = L("已复制。请在原输入框按 ⌘V。")
        case .keyUnavailable:
            pasteLog.notice("Paste key events could not be created or posted")
            status.pasteMessage = L("已复制。请在原输入框按 ⌘V。")
        }
        return false
    }

    @objc func openPasteStack() {
        status.transformClip = nil
        status.showsStack = true
        showShelf()
    }

    func pasteNextInStack(trigger: StackTrigger) {
        stackAttemptID += 1
        let attempt = stackAttemptID
        logStack(attempt, event: "received", outcome: trigger.rawValue)
        let rejection: String? = if status.isPastingStack {
            "already_pasting"
        } else if status.isEditingClip {
            "editing_clip"
        } else if status.isDragging {
            "dragging"
        } else if window.attachedSheet != nil || NSApp.modalWindow != nil {
            "modal_window"
        } else {
            nil
        }
        if let rejection {
            logStack(attempt, event: "rejected", outcome: rejection)
            return
        }
        guard let entry = pasteStack.next else {
            logStack(attempt, event: "rejected", outcome: "empty_stack")
            openPasteStack()
            return
        }
        updatePasteAccess()
        guard status.directPasteAccess == .ready else {
            logStack(attempt, event: "authorization", outcome: status.directPasteAccess.rawValue)
            openPasteStack()
            status.pasteMessage = L("授权直接粘贴后即可逐条贴出粘贴栈。")
            return
        }

        let fromShelf = status.shelfIsOpen && window.isKeyWindow
        let focusedTarget: PasteTarget?
        if fromShelf {
            focusedTarget = nil
        } else if let app = NSWorkspace.shared.frontmostApplication, app != .current {
            focusedTarget = PasteTarget(application: app)
            guard focusedTarget?.hasInputSnapshot == true else {
                logStack(attempt, event: "target", outcome: "no_original_input")
                NSSound.beep()
                return
            }
            logStack(attempt, event: "target", outcome: "input_snapshot")
        } else {
            logStack(attempt, event: "target", outcome: "no_external_foreground")
            return
        }

        status.isPastingStack = true
        status.pasteMessage = nil
        pasteTask?.cancel()
        pasteTask = Task { [weak self] in
            guard let self else { return }
            defer { status.isPastingStack = false }
            let sent: Bool
            if fromShelf {
                sent = await pasteWhenPrepared(entry.clip, plainText: false, stackAttempt: attempt)
            } else if let target = focusedTarget {
                let asFile = target.application.bundleIdentifier == "com.apple.finder"
                let copy = await store.copy(entry.clip, asFile: asFile)
                logStackCopy(attempt, result: copy)
                guard case let .written(change) = copy, !Task.isCancelled else {
                    status.pasteMessage = copy.message
                    return
                }
                sent = await sendPrepared(
                    change: change, target: target, preserved: false, restoreOriginal: false, stackAttempt: attempt
                )
            } else {
                logStack(attempt, event: "target", outcome: "no_original_input")
                return
            }
            if sent {
                let before = pasteStack.entries.count
                let advanced = pasteStack.didSend(entry.id)
                let after = pasteStack.entries.count
                pasteLog.notice("Stack attempt=\(attempt, privacy: .public) event=dequeue outcome=\(advanced ? "advanced" : "head_changed", privacy: .public) before=\(before, privacy: .public) after=\(after, privacy: .public)")
            }
        }
    }

    private func logStackCopy(_ attempt: UInt64?, result: ClipboardStore.CopyResult) {
        guard let attempt else { return }
        let outcome = if Task.isCancelled {
            "cancelled"
        } else {
            switch result {
            case .written: "written"
            case .imageUnavailable: "image_unavailable"
            case .imagePendingSync: "image_pending_sync"
            case .clipboardChanged: "clipboard_changed"
            case .failed: "failed"
            case .cancelled: "cancelled"
            }
        }
        logStack(attempt, event: "clipboard", outcome: outcome)
    }

    private func logStack(_ attempt: UInt64?, event: String, outcome: String) {
        guard let attempt else { return }
        pasteLog.notice("Stack attempt=\(attempt, privacy: .public) event=\(event, privacy: .public) outcome=\(outcome, privacy: .public) queued=\(self.pasteStack.entries.count, privacy: .public)")
    }

    func chooseImage(for clip: Clip) {
        guard let original = clip.storedPayload.singleImageFile else { return }
        pasteTask?.cancel()
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.jpeg, .png, .tiff]
        picker.directoryURL = original.deletingLastPathComponent()
        picker.message = L("选择「%@」或另存的图片文件。", original.lastPathComponent)
        picker.prompt = L("补存并复制")
        picker.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let self, let url = picker.url else { return }
            self.pasteTask = Task { [weak self] in
                guard let self else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let image = await self.store.attachImage(from: url, to: clip.id) else {
                    if !Task.isCancelled {
                        self.status.pasteMessage = L("无法补存这张图片。请检查文件是否可读及收藏空间。")
                    }
                    return
                }
                let result = await self.store.copy(image)
                if case .written = result {
                    self.browser.selectedID = image.id
                    self.hideShelf(cancelPaste: false)
                } else if !Task.isCancelled {
                    self.status.pasteMessage = result.message
                }
            }
        }
    }

    @objc func requestAccess() {
        updatePasteAccess()
        switch status.directPasteAccess {
        case .needsAccessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .needsEventPosting:
            _ = CGRequestPostEventAccess()
        case .ready:
            break
        }
    }

    func updatePasteAccess() {
        status.directPasteAccess = .current
    }
}
