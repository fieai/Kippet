import AppKit
import Carbon
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct ShelfPreferencesView: View {
    @Bindable var preferences: ShelfPreferences
    let store: ClipboardStore
    let sync: SyncEngine
    var onApplyShortcut: (ShelfShortcutAction, ShelfShortcut) -> String?
    var onRecordingChange: (Bool) -> Void

    @State private var shortcutError: (action: ShelfShortcutAction, message: String)?
    @State private var loginError: String?
    @State private var appSelectionError: String?
    @State private var loginStatus = SMAppService.Status.notRegistered
    @State private var pickingApps = false
    @State private var limitDraft: String
    @State private var daysDraft: String
    @State private var pendingRetention: RetentionDraft?

    init(
        store: ClipboardStore,
        sync: SyncEngine,
        onApplyShortcut: @escaping (ShelfShortcutAction, ShelfShortcut) -> String?,
        onRecordingChange: @escaping (Bool) -> Void
    ) {
        let preferences = store.shelfPreferences
        self.preferences = preferences
        self.store = store
        self.sync = sync
        self.onApplyShortcut = onApplyShortcut
        self.onRecordingChange = onRecordingChange
        _limitDraft = State(initialValue: String(preferences.historyLimit))
        _daysDraft = State(initialValue: String(preferences.retentionDays))
    }

    var body: some View {
        TabView {
            general
                .tabItem { Label("通用", systemImage: "gearshape") }
            shortcuts
                .tabItem { Label("快捷键", systemImage: "keyboard") }
            privacy
                .tabItem { Label("隐私", systemImage: "hand.raised") }
            ShelfRulesView(store: store)
                .tabItem { Label("规则", systemImage: "list.bullet.rectangle") }
            ShelfAutomationView(preferences: preferences, store: store)
                .tabItem { Label("自动化", systemImage: "bolt") }
            ShelfSyncSettings(sync: sync)
                .tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
        }
        .padding(12)
        .frame(minWidth: 500, minHeight: 400)
        .onAppear(perform: refreshLoginItem)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshLoginItem()
        }
        .fileImporter(
            isPresented: $pickingApps, allowedContentTypes: [.applicationBundle], allowsMultipleSelection: true,
            onCompletion: addExcludedApps
        )
        .alert("应用新的保留设置？", isPresented: Binding(
            get: { pendingRetention != nil },
            set: { if !$0 { pendingRetention = nil } }
        ), presenting: pendingRetention) { draft in
            Button("应用并清理历史", role: .destructive) { saveRetention(draft) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("超出新限制的普通历史会被清理。")
        }
    }

    private var general: some View {
        Form {
            Section("历史保留") {
                TextField("最多保留条数", text: $limitDraft, prompt: Text("100–10000"))
                TextField("保存天数", text: $daysDraft, prompt: Text("0–365"))
                HStack {
                    Text("0 天表示按条数和空间保留。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("应用") { applyRetentionDraft() }
                        .disabled(retentionDraft == nil || retentionDraft == currentRetention)
                }
                if retentionDraft == nil {
                    Text("请填写 100–10,000 条和 0–365 天。")
                        .foregroundStyle(.red)
                }
            }

            Section("系统") {
                Toggle("登录时打开 Kippet", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: updateLoginItem
                ))
                if loginStatus == .requiresApproval {
                    Button("在系统设置中确认登录项…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError { Text(loginError).foregroundStyle(.red) }
                Toggle("复制提示音", isOn: $preferences.copySound)
            }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            Section("全局快捷键") {
                ForEach(ShelfShortcutAction.allCases.filter(\.isGlobal)) { shortcutRow($0) }
            }
            Section("面板快捷键") {
                ForEach(ShelfShortcutAction.allCases.filter { !$0.isGlobal }) { shortcutRow($0) }
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ action: ShelfShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(action.title) {
                HStack {
                    ShortcutRecorder(
                        label: preferences.shortcut(for: action).label,
                        accessibilityLabel: "录制\(action.title)快捷键",
                        onRecord: { applyShortcut($0, for: action) },
                        onInvalid: { shortcutError = (action, "请按下包含 ⌃、⌥ 或 ⌘ 的组合键。") },
                        onRecordingChange: { recording in
                            if recording { shortcutError = nil }
                            onRecordingChange(recording)
                        }
                    )
                    .frame(width: 120, height: 26)
                    Button("恢复默认") { applyShortcut(action.defaultShortcut, for: action) }
                        .disabled(preferences.shortcut(for: action) == action.defaultShortcut)
                        .accessibilityLabel("恢复\(action.title)默认快捷键")
                }
            }
            if let shortcutError, shortcutError.action == action {
                Text(shortcutError.message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var privacy: some View {
        Form {
            Section("排除应用") {
                ForEach(preferences.excludedApps.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })) { app in
                    LabeledContent {
                        Button("移除") { preferences.removeExcludedApp(app.id) }
                            .accessibilityLabel("移除 \(app.name)")
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            Text(app.id).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    pickingApps = true
                } label: {
                    Label("添加应用…", systemImage: "plus")
                }
                Text("跳过所选应用的后续复制。")
                    .foregroundStyle(.secondary)
                if let appSelectionError { Text(appSelectionError).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    private func applyShortcut(_ shortcut: ShelfShortcut, for action: ShelfShortcutAction) {
        shortcutError = onApplyShortcut(action, shortcut).map { (action, $0) }
    }

    private struct RetentionDraft: Equatable {
        let limit: Int
        let days: Int
    }

    private var retentionDraft: RetentionDraft? {
        guard let limit = Int(limitDraft.trimmingCharacters(in: .whitespaces)),
              let days = Int(daysDraft.trimmingCharacters(in: .whitespaces)),
              ShelfPreferences.historyLimits.contains(limit),
              ShelfPreferences.retentionRange.contains(days) else { return nil }
        return RetentionDraft(limit: limit, days: days)
    }

    private var currentRetention: RetentionDraft {
        RetentionDraft(limit: preferences.historyLimit, days: preferences.retentionDays)
    }

    private func applyRetentionDraft() {
        guard let draft = retentionDraft else { return }
        let current = currentRetention
        let fewerDays = draft.days > 0 && (current.days == 0 || draft.days < current.days)
        if draft.limit < current.limit || fewerDays {
            pendingRetention = draft
        } else {
            saveRetention(draft)
        }
    }

    private func saveRetention(_ draft: RetentionDraft) {
        preferences.applyHistoryRetention(limit: draft.limit, days: draft.days)
        limitDraft = String(draft.limit)
        daysDraft = String(draft.days)
    }

    private func refreshLoginItem() {
        loginStatus = SMAppService.mainApp.status
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "登录项更新失败。\(error.localizedDescription)"
        }
        refreshLoginItem()
    }

    private func addExcludedApps(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            var skipped = 0
            for url in urls {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
                    skipped += 1
                    continue
                }
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                preferences.exclude(ExcludedApp(id: id, name: name))
            }
            appSelectionError = skipped == 0 ? nil : "有 \(skipped) 个应用无法读取标识。"
        case .failure(let error):
            appSelectionError = "无法添加应用。\(error.localizedDescription)"
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let label: String
    let accessibilityLabel: String
    let onRecord: (ShelfShortcut) -> Void
    let onInvalid: () -> Void
    let onRecordingChange: (Bool) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton(title: "", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(RecorderButton.startRecording)
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.shortcutLabel = label
        button.onRecord = onRecord
        button.onInvalid = onInvalid
        button.onRecordingChange = onRecordingChange
    }

    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) {
        button.stopRecording()
    }

    final class RecorderButton: NSButton {
        var shortcutLabel = "" {
            didSet { if monitor == nil { title = shortcutLabel } }
        }
        var onRecord: ((ShelfShortcut) -> Void)?
        var onInvalid: (() -> Void)?
        var onRecordingChange: ((Bool) -> Void)?
        private var monitor: Any?
        private var keyWindowObserver: NSObjectProtocol?

        override var acceptsFirstResponder: Bool { true }

        @objc func startRecording() {
            if monitor != nil {
                stopRecording()
                return
            }
            guard let window, window.makeFirstResponder(self) else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                      event.window === window || (event.window == nil && window.isKeyWindow)
                else { return event }
                self.record(event)
                return nil
            }
            guard monitor != nil else { return }
            title = "请按快捷键…"
            onRecordingChange?(true)
            keyWindowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopRecording() }
            }
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { stopRecording() }
            return resigned
        }

        override func keyDown(with event: NSEvent) {
            if monitor != nil { record(event) } else { super.keyDown(with: event) }
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard monitor != nil else { return super.performKeyEquivalent(with: event) }
            record(event)
            return true
        }

        func stopRecording() {
            let wasRecording = monitor != nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
            monitor = nil
            keyWindowObserver = nil
            title = shortcutLabel
            if wasRecording { onRecordingChange?(false) }
        }

        private func record(_ event: NSEvent) {
            guard !event.isARepeat else { return }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty {
                stopRecording()
                return
            }
            guard let shortcut = ShelfShortcut.recorded(from: event) else {
                onInvalid?()
                return
            }
            stopRecording()
            onRecord?(shortcut)
        }
    }
}
