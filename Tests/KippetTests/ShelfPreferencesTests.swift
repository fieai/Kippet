import AppKit
import Carbon
import Testing
@testable import Kippet

@MainActor
struct ShelfPreferencesTests {
    @Test func automationPermissionsDefaultOffAndPersistIndependently() throws {
        let suite = "KippetPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ShelfPreferences(defaults: defaults)
        #expect(!preferences.mcpEnabled)
        #expect(!preferences.mcpSnippetsEnabled)
        #expect(!preferences.urlCopyEnabled)
        defaults.register(defaults: [ShelfAutomation.mcpEnabled: true])
        #expect(!ShelfPreferences.mcpAccess(from: defaults, domain: suite).enabled)

        preferences.mcpEnabled = true
        preferences.mcpSnippetsEnabled = true
        preferences.urlCopyEnabled = true
        let reopened = ShelfPreferences(defaults: defaults)
        #expect(reopened.mcpEnabled)
        #expect(reopened.mcpSnippetsEnabled)
        #expect(reopened.urlCopyEnabled)

        let excluded = ExcludedApp(id: "test.excluded", name: "Excluded")
        preferences.exclude(excluded)
        preferences.rules.removeAll()
        let access = ShelfPreferences.mcpAccess(from: defaults, domain: suite)
        #expect(access.enabled && access.snippetsEnabled)
        #expect(access.excludedApps == [excluded])
        #expect(access.rules.isEmpty)

        reopened.mcpEnabled = false
        #expect(ShelfPreferences(defaults: defaults).mcpSnippetsEnabled)
        #expect(ShelfPreferences(defaults: defaults).urlCopyEnabled)
        #expect(!ShelfPreferences.mcpAccess(from: defaults, domain: suite).enabled)
    }

    @Test func rulesSeedOnceAndPersistOrderAndDeletion() throws {
        let suite = "KippetPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ShelfPreferences(defaults: defaults)
        #expect(preferences.rules == ClipRule.presets)
        let data = try #require(defaults.data(forKey: "clipRules"))
        #expect(try JSONDecoder().decode([ClipRule].self, from: data) == ClipRule.presets)

        preferences.rules.reverse()
        preferences.rules[0].isEnabled = true
        preferences.rules.removeLast()
        #expect(ShelfPreferences(defaults: defaults).rules == preferences.rules)
        preferences.rules.removeAll()
        #expect(ShelfPreferences(defaults: defaults).rules.isEmpty)
    }

    @Test func lastPasteTransformPersists() throws {
        let suite = "KippetPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ShelfPreferences(defaults: defaults)
        #expect(preferences.lastPasteTransform == nil)
        preferences.lastPasteTransform = .jsonPretty
        #expect(ShelfPreferences(defaults: defaults).lastPasteTransform == .jsonPretty)
        preferences.lastPasteTransform = nil
        #expect(ShelfPreferences(defaults: defaults).lastPasteTransform == nil)
    }

    @Test func transformPickerShortcutIsReserved() {
        for key in [kVK_Return, kVK_ANSI_KeypadEnter] {
            let shortcut = ShelfShortcut(keyCode: UInt16(key), modifiers: UInt32(optionKey), keyLabel: "↩")
            #expect(shortcut.isReserved)
        }
    }

    @Test func preferencesPersistAcrossReopen() throws {
        let suite = "KippetPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = ShelfPreferences(defaults: defaults)
        #expect(preferences.shortcut(for: .showShelf) == ShelfShortcutAction.showShelf.defaultShortcut)
        #expect(preferences.historyLimit == 1_000)
        #expect(preferences.retentionDays == 0)
        #expect(!preferences.copySound)

        let event = try #require(makeKeyEvent(keyCode: kVK_ANSI_K, flags: [.command, .shift]))
        let shortcut = try #require(ShelfShortcut.recorded(from: event))
        preferences.setShortcut(shortcut, for: .showShelf)
        preferences.applyHistoryRetention(limit: 99, days: 400)
        preferences.copySound = true

        let app = ExcludedApp(id: "example.plaintext", name: "Text Editor")
        preferences.exclude(app)
        preferences.exclude(app)
        preferences.exclude(ExcludedApp(id: "example.temporary", name: "Temporary"))
        preferences.removeExcludedApp("example.temporary")

        let reopened = ShelfPreferences(defaults: defaults)
        #expect(reopened.shortcut(for: .showShelf) == shortcut)
        #expect(reopened.shortcut(for: .showShelf).keyCode == UInt16(kVK_ANSI_K))
        #expect(reopened.shortcut(for: .showShelf).modifiers == UInt32(cmdKey | shiftKey))
        #expect(reopened.historyLimit == 100)
        #expect(reopened.retentionDays == 365)
        #expect(reopened.copySound)
        #expect(reopened.excludedApps == [app])
    }

    @Test func bareKeysAndShiftAloneAreNotGlobalShortcuts() throws {
        let bare = try #require(makeKeyEvent(keyCode: kVK_ANSI_K, flags: []))
        let shifted = try #require(makeKeyEvent(keyCode: kVK_ANSI_K, flags: [.shift]))
        #expect(ShelfShortcut.recorded(from: bare) == nil)
        #expect(ShelfShortcut.recorded(from: shifted) == nil)
    }

    @Test func loadsLegacyPanelShortcutAndPersistsIndependentBindings() throws {
        let suite = "KippetPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = ShelfShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: UInt32(optionKey | cmdKey), keyLabel: "K")
        defaults.set(try PropertyListEncoder().encode(legacy), forKey: "globalShortcut")
        let preferences = ShelfPreferences(defaults: defaults)
        #expect(preferences.shortcut(for: .showShelf) == legacy)
        #expect(preferences.shortcut(for: .pasteStack).label == "⌃⌥V")
        #expect(preferences.shortcutConflict(for: legacy, changing: .pasteStack) == .showShelf)
        #expect(preferences.shortcutConflict(for: legacy, changing: .showShelf) == nil)

        let stack = ShelfShortcut(keyCode: UInt16(kVK_ANSI_B), modifiers: UInt32(optionKey | controlKey), keyLabel: "B")
        let search = ShelfShortcut(keyCode: UInt16(kVK_ANSI_F), modifiers: UInt32(controlKey | shiftKey), keyLabel: "F")
        preferences.setShortcut(stack, for: .pasteStack)
        preferences.setShortcut(search, for: .search)
        let reopened = ShelfPreferences(defaults: defaults)
        #expect(reopened.shortcut(for: .showShelf) == legacy)
        #expect(reopened.shortcut(for: .pasteStack) == stack)
        #expect(reopened.shortcut(for: .search) == search)
        #expect(reopened.shortcut(for: .newSnippet).label == "⌘N")
    }

    @Test func comparesResolvedBindingsAndProtectsBuiltInCommands() throws {
        let builtIn = ShelfShortcutAction.pasteStack.defaultShortcut
        let recorded = ShelfShortcut(keyCode: builtIn.resolvedKeyCode, modifiers: builtIn.modifiers, keyLabel: "V")
        #expect(builtIn.sameBinding(as: recorded))
        let event = try #require(makeKeyEvent(keyCode: kVK_ANSI_K, flags: [.command, .shift, .capsLock]))
        let shortcut = try #require(ShelfShortcut.recorded(from: event))
        #expect(shortcut.matches(event))
        let paste = ShelfShortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: UInt32(cmdKey), keyLabel: "V")
        let fastPaste = ShelfShortcut(keyCode: UInt16(kVK_ANSI_4), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "4")
        #expect(paste.isReserved)
        #expect(fastPaste.isReserved)
        #expect(!shortcut.isReserved)
    }

    private func makeKeyEvent(keyCode: Int, flags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: UInt16(keyCode)
        )
    }
}
