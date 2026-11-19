import AppKit
import Carbon
import Observation

struct ShelfShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt16?
    let modifiers: UInt32
    private let keyLabel: String

    init(keyCode: UInt16?, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    @MainActor var resolvedKeyCode: UInt16 {
        keyCode ?? KeyboardLayout.pasteKeyCode ?? UInt16(kVK_ANSI_V)
    }

    @MainActor func sameBinding(as other: Self) -> Bool {
        modifiers == other.modifiers && resolvedKeyCode == other.resolvedKeyCode
    }

    @MainActor func matches(_ event: NSEvent) -> Bool {
        resolvedKeyCode == event.keyCode && modifiers == Self.carbonModifiers(event.modifierFlags)
    }

    @MainActor var isReserved: Bool {
        let key = Int(resolvedKeyCode)
        if modifiers == UInt32(optionKey), [kVK_Return, kVK_ANSI_KeypadEnter].contains(key) { return true }
        if modifiers == UInt32(cmdKey) {
            let editingAndNavigation = [kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_Q, kVK_ANSI_S, kVK_ANSI_V,
                                        kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_Comma,
                                        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                                        kVK_Return, kVK_ANSI_KeypadEnter]
            if editingAndNavigation.contains(key) { return true }
        }
        return [UInt32(cmdKey), UInt32(cmdKey | shiftKey)].contains(modifiers) &&
            [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
             kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9].contains(key)
    }

    var label: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + keyLabel
    }

    static func recorded(from event: NSEvent) -> ShelfShortcut? {
        guard event.type == .keyDown, !event.isARepeat,
              !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
        return ShelfShortcut(
            keyCode: event.keyCode, modifiers: carbonModifiers(event.modifierFlags), keyLabel: displayKey(for: event)
        )
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }

    private static func displayKey(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "Esc"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: break
        }

        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        if let index = functionKeys.firstIndex(of: Int(event.keyCode)) { return "F\(index + 1)" }
        if let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
           !characters.isEmpty, characters.rangeOfCharacter(from: .controlCharacters) == nil {
            return characters.uppercased()
        }
        return "键 \(event.keyCode)"
    }
}

enum ShelfShortcutAction: String, CaseIterable, Identifiable {
    case showShelf = "globalShortcut"
    case pasteStack = "pasteStackShortcut"
    case search = "searchShortcut"
    case newSnippet = "newSnippetShortcut"

    var id: Self { self }
    var isGlobal: Bool { self == .showShelf || self == .pasteStack }

    var title: String {
        switch self {
        case .showShelf: "呼出 TapV"
        case .pasteStack: "粘贴栈贴下一条"
        case .search: "聚焦搜索"
        case .newSnippet: "新建片段"
        }
    }

    var defaultShortcut: ShelfShortcut {
        switch self {
        case .showShelf: ShelfShortcut(keyCode: nil, modifiers: UInt32(optionKey | shiftKey), keyLabel: "V")
        case .pasteStack: ShelfShortcut(keyCode: nil, modifiers: UInt32(controlKey | optionKey), keyLabel: "V")
        case .search: ShelfShortcut(keyCode: UInt16(kVK_ANSI_F), modifiers: UInt32(cmdKey), keyLabel: "F")
        case .newSnippet: ShelfShortcut(keyCode: UInt16(kVK_ANSI_N), modifiers: UInt32(cmdKey), keyLabel: "N")
        }
    }
}

struct ExcludedApp: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
}

@MainActor
@Observable
final class ShelfPreferences {
    static let historyLimits = 100...10_000
    static let retentionRange = 0...365
    static let defaultHistoryLimit = 1_000

    private var shortcuts: [ShelfShortcutAction: ShelfShortcut]
    var historyLimit: Int { retention.limit }
    var retentionDays: Int { retention.days }
    private var retention: Retention {
        didSet { save(retention, forKey: Key.retention) }
    }
    private(set) var excludedApps: [ExcludedApp] {
        didSet { save(excludedApps, forKey: Key.excludedApps) }
    }
    var rules: [ClipRule] {
        didSet { saveRules() }
    }
    var copySound: Bool {
        didSet { defaults.set(copySound, forKey: Key.copySound) }
    }
    var lastPasteTransform: PasteTransform? {
        didSet { defaults.set(lastPasteTransform?.rawValue, forKey: Key.lastPasteTransform) }
    }
    var mcpEnabled: Bool {
        didSet { defaults.set(mcpEnabled, forKey: ShelfAutomation.mcpEnabled) }
    }
    var mcpSnippetsEnabled: Bool {
        didSet { defaults.set(mcpSnippetsEnabled, forKey: ShelfAutomation.mcpSnippetsEnabled) }
    }
    var urlCopyEnabled: Bool {
        didSet { defaults.set(urlCopyEnabled, forKey: ShelfAutomation.urlCopyEnabled) }
    }
    var presentationMode = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcuts = Dictionary(uniqueKeysWithValues: ShelfShortcutAction.allCases.compactMap { action in
            Self.load(ShelfShortcut.self, from: defaults, forKey: action.rawValue).map { (action, $0) }
        })
        let saved = Self.load(Retention.self, from: defaults, forKey: Key.retention)
        retention = Retention(
            limit: Self.clamp(saved?.limit ?? Self.defaultHistoryLimit, to: Self.historyLimits),
            days: Self.clamp(saved?.days ?? 0, to: Self.retentionRange)
        )
        excludedApps = Self.decodeExcludedApps(defaults.data(forKey: Key.excludedApps))
        rules = Self.decodeRules(defaults.data(forKey: Key.rules))
        copySound = defaults.bool(forKey: Key.copySound)
        lastPasteTransform = defaults.string(forKey: Key.lastPasteTransform).flatMap(PasteTransform.init(rawValue:))
        mcpEnabled = defaults.bool(forKey: ShelfAutomation.mcpEnabled)
        mcpSnippetsEnabled = defaults.bool(forKey: ShelfAutomation.mcpSnippetsEnabled)
        urlCopyEnabled = defaults.bool(forKey: ShelfAutomation.urlCopyEnabled)
        if defaults.data(forKey: Key.rules) == nil { saveRules() }
    }

    nonisolated static func mcpAccess(from defaults: UserDefaults, domain: String) -> MCPServer.Access {
        // Only saved preferences can enable access, including when the executable receives launch arguments.
        guard let saved = defaults.persistentDomain(forName: domain),
              saved[ShelfAutomation.mcpEnabled] as? Bool == true else { return .init() }
        return .init(
            enabled: true,
            snippetsEnabled: saved[ShelfAutomation.mcpSnippetsEnabled] as? Bool == true,
            excludedApps: decodeExcludedApps(saved[Key.excludedApps] as? Data),
            rules: decodeRules(saved[Key.rules] as? Data)
        )
    }

    nonisolated private static func decodeRules(_ data: Data?) -> [ClipRule] {
        data.flatMap { try? JSONDecoder().decode([ClipRule].self, from: $0) } ?? ClipRule.presets
    }

    nonisolated private static func decodeExcludedApps(_ data: Data?) -> [ExcludedApp] {
        data.flatMap { try? PropertyListDecoder().decode([ExcludedApp].self, from: $0) } ?? []
    }

    func shortcut(for action: ShelfShortcutAction) -> ShelfShortcut {
        shortcuts[action] ?? action.defaultShortcut
    }

    func shortcutConflict(for candidate: ShelfShortcut, changing action: ShelfShortcutAction) -> ShelfShortcutAction? {
        ShelfShortcutAction.allCases.first { $0 != action && shortcut(for: $0).sameBinding(as: candidate) }
    }

    func setShortcut(_ shortcut: ShelfShortcut, for action: ShelfShortcutAction) {
        shortcuts[action] = shortcut
        save(shortcut, forKey: action.rawValue)
    }

    func applyHistoryRetention(limit: Int, days: Int) {
        retention = Retention(limit: Self.clamp(limit, to: Self.historyLimits),
                              days: Self.clamp(days, to: Self.retentionRange))
    }

    func exclude(_ app: ExcludedApp) {
        if let current = excludedApps.firstIndex(where: { $0.id == app.id }) {
            if excludedApps[current] != app { excludedApps[current] = app }
        } else {
            excludedApps.append(app)
        }
    }

    func removeExcludedApp(_ id: ExcludedApp.ID) {
        excludedApps.removeAll { $0.id == id }
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: Key.rules)
        }
    }

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? PropertyListEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? PropertyListDecoder().decode(type, from: data)
    }

    private enum Key {
        static let retention = "historyRetention"
        static let excludedApps = "excludedApps"
        static let rules = "clipRules"
        static let copySound = "copySound"
        static let lastPasteTransform = "lastPasteTransform"
    }

    private struct Retention: Codable {
        let limit: Int
        let days: Int
    }
}
