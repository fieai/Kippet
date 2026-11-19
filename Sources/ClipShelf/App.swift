import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Observation
import OSLog
import SwiftUI
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

@MainActor
@Observable
final class ShelfStatus {
    var shortcutAvailable = false
    var pasteMessage: String?
    var directPasteAccess = DirectPasteAccess.needsAccessibility
    var showPasteAccessPrompt = false
    var isPinned = false
    var commandHeld = false
    var isDragging = false
    var isEditingClip = false
    var shortcutLabel = "⌥⇧V"
    var stackShortcutAvailable = false
    var stackShortcutLabel = "⌃⌥V"
    var showsStack = false
    var isPastingStack = false
    var snippetDraft: SnippetDraft?
    var showsSnippetEditor: Bool { snippetDraft != nil }
    var ruleDraft: ClipRule?
    var shelfIsOpen = false
    var searchFocused = false
    var transformClip: Clip?
}

struct SnippetDraft: Identifiable {
    let id = UUID()
    var title = ""
    var content = ""
    var groupID: ClipGroup.ID?
}

private final class ShelfPanel: NSPanel {
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

@main
struct ClipShelfApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPStdio.run()
            return
        }
        let app = NSApplication.shared
        let delegate = ShelfDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class ShelfDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum StackTrigger: String {
        case shortcut, button
    }

    private let pasteLog = Logger(subsystem: "com.clipshelf.macos", category: "DirectPaste")
    private let store = ClipboardStore.live()
    private lazy var sync = SyncEngine(store: store)
    private lazy var browser = ShelfBrowser(store: store)
    private var preferences: ShelfPreferences { store.shelfPreferences }
    private let pasteStack = PasteStack()
    private let status = ShelfStatus()
    private let window = ShelfPanel(
        contentRect: NSRect(x: 0, y: 0, width: 1040, height: 382),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private var preferencesWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var pendingURLs: [URL]? = []
    private struct RegisteredHotKey {
        let id: UInt32
        let key: UInt16
        let modifiers: UInt32
        let reference: EventHotKeyRef
    }
    private var hotKeys: [ShelfShortcutAction: RegisteredHotKey] = [:]
    private var nextHotKeyID: UInt32 = 0
    private var heldHotKeys: Set<ShelfShortcutAction> = []
    private var isRecordingShortcut = false
    private var stackAttemptID: UInt64 = 0
    private var hotKeyHandler: EventHandlerRef?
    private var keyMonitor: Any?
    private var outsideMouseMonitor: Any?
    private weak var searchField: NSTextField?
    private var captureTimer: Timer?
    private var captureSyncTimer: Timer?
    private var scheduledChange: Int?
    private var activationSerial = 0
    private var lastPolledActivation = 0
    private var pasteTarget: PasteTarget?
    private var keptOriginalFocus = false
    private var pasteTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        configureStatusItem()
        configureWindow()
        applyRetention()
        store.prewarmOCR()
        refreshHotKey()
        sync.start()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refreshHotKey), name: Self.inputSourceChanged, object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(addAutomationSnippet(_:)),
            name: ShelfAutomation.addSnippetNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleCapture() }
        }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
        let urls = pendingURLs ?? []
        pendingURLs = nil
        if urls.isEmpty { showShelf() } else { application(NSApp, open: urls) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if pendingURLs != nil {
            pendingURLs?.append(contentsOf: urls)
            return
        }
        for url in urls {
            guard let command = ShelfURLCommand(url: url) else { continue }
            handleURLCommand(command)
        }
    }

    private func handleURLCommand(_ command: ShelfURLCommand) {
        switch command {
        case .open:
            showShelf()
        case let .search(query):
            guard !preferences.presentationMode else { return }
            status.showsStack = false
            status.transformClip = nil
            browser.isPreviewing = false
            browser.favoritesOnly = false
            browser.groupID = nil
            browser.contentType = nil
            browser.sourceName = nil
            browser.sourceBundleIdentifier = nil
            showShelf()
            browser.search = query
            browser.clearMultiSelection()
            browser.selectedID = browser.results.first?.id
        case .stack:
            openPasteStack()
        case let .newSnippet(text, title, pinboard):
            let groupID = pinboard.flatMap { value in
                let id = UUID(uuidString: value)
                return store.groups.first {
                    $0.id == id || $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame
                }?.id
            }
            presentSnippet(SnippetDraft(title: title, content: text, groupID: groupID))
        case let .copy(index):
            guard preferences.urlCopyEnabled, index <= store.clips.count else { return }
            copy(store.clips[index - 1], asFile: false)
        }
    }

    @objc private func addAutomationSnippet(_ notification: Notification) {
        guard preferences.mcpEnabled, preferences.mcpSnippetsEnabled,
              let info = notification.userInfo, let content = info["content"] as? String,
              let title = (info["title"] ?? "") as? String else { return }
        let pinboardID = (info["pinboard"] as? String).flatMap(UUID.init(uuidString:))
        guard info["pinboard"] == nil || pinboardID != nil else { return }
        _ = store.createSnippet(title: title, content: content, in: pinboardID)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showShelf()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureTimer?.invalidate()
        cancelScheduledCapture()
        pasteTask?.cancel()
        DistributedNotificationCenter.default().removeObserver(self, name: Self.inputSourceChanged, object: nil)
        DistributedNotificationCenter.default().removeObserver(
            self, name: ShelfAutomation.addSnippetNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.removeObserver(
            self, name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        stopMonitoringOutsideClicks()
        unregisterHotKeys()
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        sync.flush()
        store.flush()
    }

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

    @objc private func frontmostDidChange(_ notification: Notification) {
        activationSerial &+= 1
        if let target = pasteTarget,
           let active = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           active != target.application {
            keptOriginalFocus = false
            if active != .current { shelfLostFocus() }
        }
    }

    private func shelfLostFocus() {
        guard status.shelfIsOpen, !status.isDragging, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !status.showPasteAccessPrompt, !status.showsSnippetEditor, status.ruleDraft == nil else { return }
        status.commandHeld = false
        if status.isPinned {
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

    private func stopMonitoringOutsideClicks() {
        if let outsideMouseMonitor { NSEvent.removeMonitor(outsideMouseMonitor) }
        outsideMouseMonitor = nil
    }

    fileprivate func toggleShelf() {
        if status.shelfIsOpen, window.isKeyWindow {
            hideShelf()
        } else {
            showShelf()
        }
    }

    private func configureWindow() {
        window.title = "TapV"
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
            if selection.count == 1, let clip = selection.first, clip.payload.supportsPlainText {
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
            status.pasteMessage = "已撤销删除"
            return true
        case kVK_ANSI_S where !editingSearch && modifiers == .command:
            guard let clip = browser.selected else { return false }
            if !event.isARepeat {
                status.pasteMessage = store.toggleFavorite(clip.id)
                    ? (clip.isFavorite ? "已取消星标" : "已添加星标")
                    : "收藏空间已满"
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

    @objc private func selectAllFromEditMenu(_ sender: NSMenuItem) {
        if window.isKeyWindow, window.attachedSheet == nil, searchField?.currentEditor() == nil,
           !status.isEditingClip, !status.showsSnippetEditor, !status.showsStack, !browser.isPreviewing,
           status.transformClip == nil, status.ruleDraft == nil,
           browser.selectAllCards() { return }
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender)
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

    private func scheduleCapture() {
        let sameForeground = lastPolledActivation == activationSerial
        lastPolledActivation = activationSerial
        guard let change = store.pendingChange, scheduledChange != change else { return }
        cancelScheduledCapture()
        let source = NSWorkspace.shared.frontmostApplication
        guard allowsCapture(from: source, stable: sameForeground) else {
            recordClipboard(from: source, expectedChange: change, allowed: false)
            return
        }
        if pasteStack.isCollecting {
            recordClipboard(from: source, expectedChange: change, allowed: true)
            return
        }
        scheduledChange = change
        let foregroundAtDiscovery = activationSerial
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancelScheduledCapture()
                let stable = foregroundAtDiscovery == self.activationSerial
                self.recordClipboard(from: source, expectedChange: change, allowed: self.allowsCapture(from: source, stable: stable))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureSyncTimer = timer
    }

    private func allowsCapture(from source: NSRunningApplication?, stable: Bool) -> Bool {
        if preferences.excludedApps.isEmpty { return true }
        guard stable, let bundleID = source?.bundleIdentifier else { return false }
        return !preferences.excludedApps.contains { $0.id == bundleID }
    }

    private func recordClipboard(from source: NSRunningApplication?, expectedChange: Int? = nil, allowed: Bool) {
        if store.poll(
            sourceName: source?.localizedName, sourceBundleIdentifier: source?.bundleIdentifier,
            expectedChange: expectedChange, captureAllowed: allowed
        ) {
            if preferences.copySound { NSSound(named: "Tink")?.play() }
            if pasteStack.isCollecting, let clip = store.clips.first,
               !pasteStack.append([clip]) {
                pasteStack.isCollecting = false
                status.pasteMessage = "粘贴栈已满，连续收集已停止。"
            }
        }
    }

    private func cancelScheduledCapture() {
        captureSyncTimer?.invalidate()
        captureSyncTimer = nil
        scheduledChange = nil
    }

    @objc private func showShelf() {
        guard !preferences.presentationMode, !(status.shelfIsOpen && window.isKeyWindow) else { return }
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
        status.shelfIsOpen = true
        presentWindow(at: frame)
        window.makeKey()
        window.makeFirstResponder(nil)
        monitorOutsideClicks()
    }

    /// Bumped on every show and hide so a finishing fade-out never hides a shelf that reopened.
    private var windowTransition = 0

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
    private func hideShelf(cancelPaste: Bool = true, restoreApplication: Bool = true) -> PasteTarget? {
        if cancelPaste { pasteTask?.cancel() }
        let target = pasteTarget
        pasteTarget = nil
        keptOriginalFocus = false
        status.shelfIsOpen = false
        browser.isPreviewing = false
        status.showsStack = false
        status.isPinned = false
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

    private func paste(_ clip: Clip, plainText: Bool) {
        status.pasteMessage = nil
        pasteTask?.cancel()
        pasteTask = Task { [weak self] in
            await self?.pasteWhenPrepared(clip, plainText: plainText)
        }
    }

    private func copy(_ clip: Clip, asFile: Bool) {
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

        let preserved = keptOriginalFocus && window.isKeyWindow &&
            pasteTarget?.application == NSWorkspace.shared.frontmostApplication
        let target = hideShelf(cancelPaste: false)
        guard let target, target.hasInputSnapshot || preserved else {
            logStack(stackAttempt, event: "target", outcome: "no_original_input")
            pasteLog.notice("No original input or uninterrupted foreground session")
            status.pasteMessage = "已复制。请在原输入框按 ⌘V。"
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
            status.pasteMessage = "剪贴板已变化，直接粘贴已取消。"
        case .focusLost:
            logStack(stackAttempt, event: "focus", outcome: "lost")
            pasteLog.notice("Original input did not regain focus")
            status.pasteMessage = "已复制。请在原输入框按 ⌘V。"
        case .keyUnavailable:
            pasteLog.notice("Paste key events could not be created or posted")
            status.pasteMessage = "已复制。请在原输入框按 ⌘V。"
        }
        return false
    }

    @objc private func openPasteStack() {
        guard !preferences.presentationMode else { return }
        status.transformClip = nil
        status.showsStack = true
        showShelf()
    }

    @objc private func newSnippet() {
        presentSnippet(SnippetDraft(groupID: browser.favoritesOnly ? browser.groupID : nil))
    }

    private func presentSnippet(_ draft: SnippetDraft) {
        guard !preferences.presentationMode, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        showShelf()
        status.transformClip = nil
        status.showsStack = false
        status.snippetDraft = draft
    }

    private func pasteNextInStack(trigger: StackTrigger) {
        stackAttemptID += 1
        let attempt = stackAttemptID
        logStack(attempt, event: "received", outcome: trigger.rawValue)
        let rejection: String? = if preferences.presentationMode {
            "presentation_mode"
        } else if status.isPastingStack {
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
            status.pasteMessage = "授权直接粘贴后即可逐条贴出粘贴栈。"
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

    private func chooseImage(for clip: Clip) {
        guard let original = clip.payload.singleImageFile else { return }
        pasteTask?.cancel()
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.jpeg, .png, .tiff]
        picker.directoryURL = original.deletingLastPathComponent()
        picker.message = "选择「\(original.lastPathComponent)」或另存的图片文件。"
        picker.prompt = "补存并复制"
        picker.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let self, let url = picker.url else { return }
            self.pasteTask = Task { [weak self] in
                guard let self else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let image = await self.store.attachImage(from: url, to: clip.id) else {
                    if !Task.isCancelled {
                        self.status.pasteMessage = "无法补存这张图片。请检查文件是否可读及收藏空间。"
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

    @objc private func requestAccess() {
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

    private func updatePasteAccess() {
        status.directPasteAccess = .current
    }

    private func applyRetention() {
        store.updateRetention(limit: preferences.historyLimit, days: preferences.retentionDays)
    }

    @objc private func showPreferences() {
        if status.shelfIsOpen { hideShelf(restoreApplication: false) }
        if preferencesWindow == nil {
            let content = ShelfPreferencesView(
                store: store,
                sync: sync,
                onApplyShortcut: { [weak self] action, shortcut in self?.applyShortcut(shortcut, for: action) },
                onRecordingChange: { [weak self] in self?.setRecordingShortcut($0) }
            )
            .onChange(of: [preferences.historyLimit, preferences.retentionDays]) { [weak self] _, _ in
                self?.applyRetention()
            }
            .onChange(of: preferences.presentationMode) { [weak self] _, enabled in
                if enabled, self?.status.shelfIsOpen == true { self?.hideShelf(restoreApplication: false) }
            }
            let settings = NSWindow(contentViewController: NSHostingController(rootView: content))
            settings.title = "TapV 设置"
            settings.styleMask = [.titled, .closable, .resizable]
            settings.isReleasedWhenClosed = false
            settings.center()
            preferencesWindow = settings
        }
        NSApp.activate()
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePresentationMode() {
        preferences.presentationMode.toggle()
        if preferences.presentationMode, status.shelfIsOpen { hideShelf(restoreApplication: false) }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusItemImage()
        item.button?.toolTip = "TapV"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(menuItem("打开 TapV", action: #selector(showShelf)))
        menu.addItem(menuItem("暂停记录", action: #selector(toggleCapture)))
        menu.addItem(menuItem("开启直接粘贴…", action: #selector(requestAccess)))
        menu.addItem(.separator())
        let presentation = menuItem("演示模式", action: #selector(togglePresentationMode))
        presentation.tag = 10
        menu.addItem(presentation)
        menu.addItem(menuItem("设置…", action: #selector(showPreferences)))
        let stack = menuItem("粘贴栈…", action: #selector(openPasteStack))
        stack.tag = 11
        menu.addItem(stack)
        let snippet = menuItem("新建片段…", action: #selector(newSnippet))
        snippet.tag = 12
        menu.addItem(snippet)
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 TapV", action: #selector(NSApplication.terminate(_:)), target: NSApp))
        item.menu = menu
        statusItem = item
    }

    private static func statusItemImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 1, y: 3.5))
            mark.line(to: NSPoint(x: 5.2, y: 2.5))
            mark.line(to: NSPoint(x: 6.4, y: 3.5))
            mark.line(to: NSPoint(x: 8, y: 8))
            mark.line(to: NSPoint(x: 10.6, y: 2.5))
            mark.line(to: NSPoint(x: 14.2, y: 3.3))
            mark.line(to: NSPoint(x: 15, y: 4.5))
            mark.line(to: NSPoint(x: 10.4, y: 13.5))
            mark.line(to: NSPoint(x: 5.6, y: 13.5))
            mark.close()
            NSColor.black.setFill()
            mark.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "TapV"
        return image
    }

    private func configureMainMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        let settings = menuItem("设置…", action: #selector(showPreferences))
        settings.keyEquivalent = ","
        app.submenu?.addItem(settings)
        app.submenu?.addItem(withTitle: "退出 TapV", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)

        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("撤销", Selector(("undo:")), "z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
        ] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let selectAll = menuItem("全选", action: #selector(selectAllFromEditMenu(_:)))
        selectAll.keyEquivalent = "a"
        editMenu.addItem(selectAll)
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    private func menuItem(_ title: String, action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target ?? self
        return item
    }

    @objc private func toggleCapture() {
        cancelScheduledCapture()
        store.toggleCapture()
    }

    private static let inputSourceChanged = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    @objc private func refreshHotKey() {
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

    private func applyShortcut(_ shortcut: ShelfShortcut, for action: ShelfShortcutAction) -> String? {
        if let conflict = preferences.shortcutConflict(for: shortcut, changing: action) {
            return "\(shortcut.label) 已用于「\(conflict.title)」。"
        }
        if shortcut.isReserved {
            return "\(shortcut.label) 用于编辑、导航或快贴，请换一个组合。"
        }
        if action.isGlobal, !registerHotKey(shortcut, for: action) {
            return "系统无法注册 \(shortcut.label)，请换一个组合。"
        }
        preferences.setShortcut(shortcut, for: action)
        updateShortcutStatus()
        return nil
    }

    private func setRecordingShortcut(_ recording: Bool) {
        guard recording != isRecordingShortcut else { return }
        isRecordingShortcut = recording
        if recording { unregisterHotKeys() } else { refreshHotKey() }
    }

    private func unregisterHotKeys() {
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

extension ShelfDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(at: 0)?.title = status.shortcutAvailable ? "打开 TapV   \(status.shortcutLabel)" : "打开 TapV"
        menu.item(at: 0)?.isEnabled = !preferences.presentationMode
        menu.item(at: 1)?.title = store.isPaused ? "恢复记录" : "暂停记录"
        updatePasteAccess()
        menu.item(at: 2)?.isHidden = status.directPasteAccess == .ready
        menu.item(withTag: 10)?.state = preferences.presentationMode ? .on : .off
        menu.item(withTag: 11)?.title = "粘贴栈 · \(pasteStack.entries.count) 项"
        menu.item(withTag: 11)?.isEnabled = !preferences.presentationMode
        menu.item(withTag: 12)?.isEnabled = !preferences.presentationMode
    }
}
