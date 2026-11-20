import AppKit
import SwiftUI

extension ShelfDelegate: NSMenuDelegate {
    func applyRetention() {
        store.updateRetention(limit: preferences.historyLimit, days: preferences.retentionDays)
    }

    @objc func showPreferences() {
        if status.shelfIsOpen { hideShelf(restoreApplication: false) }
        if preferencesWindow == nil {
            let content = ShelfPreferencesView(
                store: store,
                sync: sync,
                updateChecker: updateChecker,
                onApplyShortcut: { [weak self] action, shortcut in self?.applyShortcut(shortcut, for: action) },
                onRecordingChange: { [weak self] in self?.setRecordingShortcut($0) }
            )
            .onChange(of: [preferences.historyLimit, preferences.retentionDays]) { [weak self] _, _ in
                self?.applyRetention()
            }
            let settings = NSWindow(contentViewController: NSHostingController(rootView: content))
            settings.title = L("Kippet 设置")
            settings.styleMask = [.titled, .closable, .resizable]
            settings.isReleasedWhenClosed = false
            settings.center()
            preferencesWindow = settings
        }
        NSApp.activate()
        preferencesWindow?.makeKeyAndOrderFront(nil)
        updateChecker.checkAutomatically(enabled: preferences.autoCheckUpdates)
    }

    func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusItemImage()
        item.button?.toolTip = "Kippet"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(menuItem(L("打开 Kippet"), action: #selector(showShelf)))
        menu.addItem(menuItem(L("暂停记录"), action: #selector(toggleCapture)))
        menu.addItem(menuItem(L("开启直接粘贴…"), action: #selector(requestAccess)))
        menu.addItem(.separator())
        menu.addItem(menuItem(L("设置…"), action: #selector(showPreferences)))
        menu.addItem(menuItem(L("使用引导…"), action: #selector(showUsageGuide)))
        let stack = menuItem(L("粘贴栈…"), action: #selector(openPasteStack))
        stack.tag = 11
        menu.addItem(stack)
        let snippet = menuItem(L("新建片段…"), action: #selector(newSnippet))
        snippet.tag = 12
        menu.addItem(snippet)
        menu.addItem(.separator())
        menu.addItem(menuItem(L("退出 Kippet"), action: #selector(NSApplication.terminate(_:)), target: NSApp))
        item.menu = menu
        statusItem = item
    }

    private static func statusItemImage() -> NSImage {
        // A small keep tag, tilted like the app icon's tag, with an eyelet and two label lines cut out.
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: 3, y: 6.2))
            mark.line(to: NSPoint(x: 6.4, y: 2))
            mark.line(to: NSPoint(x: 9.6, y: 2))
            mark.line(to: NSPoint(x: 13, y: 6.2))
            mark.line(to: NSPoint(x: 13, y: 13.2))
            mark.curve(to: NSPoint(x: 11.8, y: 14.5), controlPoint1: NSPoint(x: 13, y: 14), controlPoint2: NSPoint(x: 12.6, y: 14.5))
            mark.line(to: NSPoint(x: 4.2, y: 14.5))
            mark.curve(to: NSPoint(x: 3, y: 13.2), controlPoint1: NSPoint(x: 3.4, y: 14.5), controlPoint2: NSPoint(x: 3, y: 14))
            mark.close()
            mark.append(NSBezierPath(ovalIn: NSRect(x: 6.6, y: 4, width: 2.8, height: 2.8)))
            mark.append(NSBezierPath(roundedRect: NSRect(x: 5.2, y: 8.6, width: 5.6, height: 1.5), xRadius: 0.75, yRadius: 0.75))
            mark.append(NSBezierPath(roundedRect: NSRect(x: 5.2, y: 11.2, width: 4, height: 1.5), xRadius: 0.75, yRadius: 0.75))
            mark.windingRule = .evenOdd
            var tilt = AffineTransform(translationByX: 8, byY: 8)
            tilt.rotate(byDegrees: -14)
            tilt.translate(x: -8, y: -8)
            mark.transform(using: tilt)
            NSColor.black.setFill()
            mark.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Kippet"
        return image
    }

    func configureMainMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        let settings = menuItem(L("设置…"), action: #selector(showPreferences))
        settings.keyEquivalent = ","
        app.submenu?.addItem(settings)
        app.submenu?.addItem(withTitle: L("退出 Kippet"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)

        let edit = NSMenuItem()
        let editMenu = NSMenu(title: L("编辑"))
        for (title, action, key) in [
            (L("撤销"), Selector(("undo:")), "z"),
            (L("剪切"), #selector(NSText.cut(_:)), "x"),
            (L("复制"), #selector(NSText.copy(_:)), "c"),
            (L("粘贴"), #selector(NSText.paste(_:)), "v"),
        ] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let selectAll = menuItem(L("全选"), action: #selector(selectAllFromEditMenu(_:)))
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

    @objc private func selectAllFromEditMenu(_ sender: NSMenuItem) {
        if window.isKeyWindow, window.attachedSheet == nil, searchField?.currentEditor() == nil,
           !status.isEditingClip, !status.showsSnippetEditor, !status.showsStack, !browser.isPreviewing,
           status.transformClip == nil, status.ruleDraft == nil,
           browser.selectAllCards() { return }
        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: sender)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(at: 0)?.title = status.shortcutAvailable
            ? L("打开 Kippet   %@", status.shortcutLabel) : L("打开 Kippet")
        menu.item(at: 1)?.title = store.isPaused ? L("恢复记录") : L("暂停记录")
        updatePasteAccess()
        menu.item(at: 2)?.isHidden = status.directPasteAccess == .ready
        menu.item(withTag: 11)?.title = L("粘贴栈 · %lld 项", pasteStack.entries.count)
    }
}
