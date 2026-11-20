import AppKit
import Carbon
import OSLog

extension ShelfDelegate {
    struct RegisteredHotKey {
        let id: UInt32
        let key: UInt16
        let modifiers: UInt32
        let reference: EventHotKeyRef
    }

    func startMonitoringShelfKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.status.shelfIsOpen, !self.status.isDragging, !self.status.isEditingClip,
                  self.window.isKeyWindow, self.window.attachedSheet == nil,
                  NSApp.modalWindow == nil,
                  event.window == nil || event.window === self.window else {
                return event
            }
            self.status.commandHeld = event.modifierFlags.contains(.command)
            if event.type == .flagsChanged { return event }
            return self.handleShelfKey(event) ? nil : event
        }
    }

    private func handleShelfKey(_ event: NSEvent) -> Bool {
        guard !status.showsSnippetEditor, status.ruleDraft == nil, status.transformClip == nil else { return false }
        let editor = searchField?.currentEditor() as? NSTextView
        let composing = editor?.hasMarkedText() == true
        guard !composing else { return false }
        let editingSearch = editor != nil
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if !status.showsStack, modifiers == .option,
           [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode)) {
            let selection = browser.selectedCards(in: browser.results)
            if selection.count == 1, let clip = selection.first, clip.storedPayload.supportsPlainText {
                if !event.isARepeat { status.transformClip = clip }
                return true
            }
        }
        if preferences.shortcut(for: .newSnippet).matches(event) {
            if !event.isARepeat { newSnippet() }
            return true
        }
        if status.showsStack, Int(event.keyCode) != kVK_Escape { return false }
        if preferences.shortcut(for: .search).matches(event) { return focusSearch() }

        if let clip = browser.quickPaste(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            if !event.isARepeat { paste(clip, plainText: modifiers.contains(.shift)) }
            return true
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            if status.showsStack {
                status.showsStack = false
            } else if browser.isPreviewing {
                browser.togglePreview()
            } else {
                hideShelf()
            }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard [[], .command, .shift].contains(modifiers),
                  let clip = browser.selected else { return false }
            if !event.isARepeat { paste(clip, plainText: modifiers == .shift) }
            return true
        case kVK_ANSI_A where !editingSearch && !browser.isPreviewing && modifiers == .command:
            return event.isARepeat || browser.selectAllCards()
        case kVK_Space where !editingSearch && modifiers.isEmpty:
            if !event.isARepeat { browser.togglePreview() }
            return true
        case kVK_Delete, kVK_ForwardDelete:
            guard !editingSearch, modifiers.isEmpty else { return false }
            if !event.isARepeat, browser.deleteSelected() { status.pasteMessage = nil }
            return true
        case kVK_ANSI_Z where !editingSearch && modifiers == .command:
            guard !event.isARepeat, browser.undoDeletion() else { return false }
            status.pasteMessage = L("已撤销删除")
            return true
        case kVK_ANSI_S where !editingSearch && modifiers == .command:
            guard let clip = browser.selected else { return false }
            if !event.isARepeat {
                status.pasteMessage = store.toggleFavorite(clip.id)
                    ? (clip.isFavorite ? L("已取消星标") : L("已添加星标"))
                    : L("收藏空间已满")
            }
            return true
        default:
            if !editingSearch, modifiers == .command {
                if Int(event.keyCode) == kVK_LeftArrow { return browser.switchGroup(-1) }
                if Int(event.keyCode) == kVK_RightArrow { return browser.switchGroup(1) }
            }
            if browser.move(
                keyCode: event.keyCode, modifiers: event.modifierFlags,
                editingSearch: editingSearch, composing: composing
            ) { return true }
            guard !editingSearch, modifiers.intersection([.command, .control]).isEmpty,
                  let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
                  })
            else { return false }
            return focusSearch(typing: event)
        }
    }

    private func focusSearch(typing event: NSEvent? = nil) -> Bool {
        guard let searchField else { return false }
        searchField.selectText(nil)
        guard let editor = searchField.currentEditor() as? NSTextView else { return false }
        status.searchFocused = true
        if let event {
            // Deliver the original event, including its input source, to AppKit's field editor.
            editor.keyDown(with: event)
        }
        return true
    }

    static let inputSourceChanged = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    @objc func refreshHotKey() {
        guard !isRecordingShortcut else { return }
        for action in ShelfShortcutAction.allCases where action.isGlobal {
            if !registerHotKey(preferences.shortcut(for: action), for: action),
               let old = hotKeys.removeValue(forKey: action) {
                UnregisterEventHotKey(old.reference)
                heldHotKeys.remove(action)
            }
        }
        updateShortcutStatus()
    }

    func applyShortcut(_ shortcut: ShelfShortcut, for action: ShelfShortcutAction) -> String? {
        if let conflict = preferences.shortcutConflict(for: shortcut, changing: action) {
            return L("%@ 已用于「%@」。", shortcut.label, conflict.title)
        }
        if shortcut.isReserved {
            return L("%@ 用于编辑、导航或快贴，请换一个组合。", shortcut.label)
        }
        if action.isGlobal, !registerHotKey(shortcut, for: action) {
            return L("系统无法注册 %@，请换一个组合。", shortcut.label)
        }
        preferences.setShortcut(shortcut, for: action)
        updateShortcutStatus()
        return nil
    }

    func setRecordingShortcut(_ recording: Bool) {
        guard recording != isRecordingShortcut else { return }
        isRecordingShortcut = recording
        if recording { unregisterHotKeys() } else { refreshHotKey() }
    }

    func unregisterHotKeys() {
        for hotKey in hotKeys.values { UnregisterEventHotKey(hotKey.reference) }
        hotKeys.removeAll()
        heldHotKeys.removeAll()
    }

    private func registerHotKey(_ shortcut: ShelfShortcut, for action: ShelfShortcutAction) -> Bool {
        let key = shortcut.resolvedKeyCode
        if let old = hotKeys[action], old.key == key, old.modifiers == shortcut.modifiers { return true }
        let target = GetEventDispatcherTarget()
        if hotKeyHandler == nil {
            var hotKeyEvents = [kEventHotKeyPressed, kEventHotKeyReleased].map {
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
            }
            let handlerStatus = InstallEventHandler(
                target,
                { _, event, context in
                    guard let event, let context else { return OSStatus(eventNotHandledErr) }
                    var identifier = EventHotKeyID()
                    let result = GetEventParameter(
                        event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID),
                        nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
                    )
                    guard result == noErr, identifier.signature == 0x434C5348
                    else { return OSStatus(eventNotHandledErr) }
                    let delegate = Unmanaged<ShelfDelegate>.fromOpaque(context).takeUnretainedValue()
                    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                    let id = identifier.id
                    return MainActor.assumeIsolated {
                        delegate.handleHotKey(id, pressed: pressed) ? noErr : OSStatus(eventNotHandledErr)
                    }
                },
                hotKeyEvents.count, &hotKeyEvents, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler
            )
            guard handlerStatus == noErr else { return false }
        }
        nextHotKeyID &+= 1
        let identifier = EventHotKeyID(signature: OSType(0x434C5348), id: nextHotKeyID)
        var reference: EventHotKeyRef?
        // Keep the previous binding registered until the replacement succeeds.
        let registration = RegisterEventHotKey(
            UInt32(key), shortcut.modifiers, identifier, target, UInt32(kEventHotKeyExclusive), &reference
        )
        guard registration == noErr, let reference else { return false }
        let binding = RegisteredHotKey(id: identifier.id, key: key, modifiers: shortcut.modifiers, reference: reference)
        if let old = hotKeys.updateValue(binding, forKey: action) { UnregisterEventHotKey(old.reference) }
        heldHotKeys.remove(action)
        return true
    }

    private func handleHotKey(_ id: UInt32, pressed: Bool) -> Bool {
        guard let action = hotKeys.first(where: { $0.value.id == id })?.key else { return false }
        if !pressed {
            heldHotKeys.remove(action)
        } else if heldHotKeys.insert(action).inserted {
            if action == .showShelf { toggleShelf() } else { pasteNextInStack(trigger: .shortcut) }
        }
        return true
    }

    private func updateShortcutStatus() {
        status.shortcutAvailable = hotKeys[.showShelf] != nil
        status.shortcutLabel = preferences.shortcut(for: .showShelf).label
        status.stackShortcutAvailable = hotKeys[.pasteStack] != nil
        status.stackShortcutLabel = preferences.shortcut(for: .pasteStack).label
        pasteLog.notice("Stack shortcut available \(self.status.stackShortcutAvailable, privacy: .public)")
    }
}
