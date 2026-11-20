import AppKit
import Carbon
import OSLog

@MainActor
final class ShelfDelegate: NSObject, NSApplicationDelegate {
    let pasteLog = Logger(subsystem: "com.fieai.kippet", category: "DirectPaste")
    let store = ClipboardStore.live()
    private(set) lazy var sync = SyncEngine(store: store)
    private(set) lazy var browser = ShelfBrowser(store: store)
    var preferences: ShelfPreferences { store.shelfPreferences }
    let updateChecker = ShelfUpdateChecker()
    let pasteStack = PasteStack()
    let status = ShelfStatus()
    let window = ShelfPanel(
        contentRect: NSRect(x: 0, y: 0, width: 1040, height: 382),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    var preferencesWindow: NSWindow?
    var usageGuideWindow: NSWindow?
    var statusItem: NSStatusItem?
    private var pendingURLs: [URL]? = []
    var hotKeys: [ShelfShortcutAction: RegisteredHotKey] = [:]
    var nextHotKeyID: UInt32 = 0
    var heldHotKeys: Set<ShelfShortcutAction> = []
    var isRecordingShortcut = false
    var stackAttemptID: UInt64 = 0
    var hotKeyHandler: EventHandlerRef?
    var keyMonitor: Any?
    var outsideMouseMonitor: Any?
    weak var searchField: NSTextField?
    var captureTimer: Timer?
    var captureSyncTimer: Timer?
    var pollingState = ShelfPollingState()
    var pollingObservers: [NSObjectProtocol] = []
    var scheduledChange: Int?
    var activationSerial = 0
    var lastPolledActivation = 0
    var pasteTarget: PasteTarget?
    var keptOriginalFocus = false
    var pasteTask: Task<Void, Never>?

    /// Bumped on every show and hide so a finishing fade-out never hides a shelf that reopened.
    var windowTransition = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let shouldShowGuide = prepareUsageGuide()
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
        observeCaptureConditions()
        updateChecker.checkAutomatically(enabled: preferences.autoCheckUpdates)
        let urls = pendingURLs ?? []
        pendingURLs = nil
        if shouldShowGuide { showUsageGuide() } else if urls.isEmpty { showShelf() }
        if !urls.isEmpty { application(NSApp, open: urls) }
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
        stopObservingCaptureConditions()
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
}
