import AppKit
import Carbon
import Testing
@testable import ClipShelf

@MainActor
struct ShelfBrowserTests {
    @Test func selectsAllMatchingCardsInVisibleOrder() throws {
        try withBrowser { browser, clips, _ in
            browser.search = "alpha"
            #expect(browser.selectAllCards())
            #expect(browser.selectedCards(in: browser.results).map(\.id) == [clips[0].id, clips[2].id])
            browser.clearMultiSelection()
            browser.search = "no matching card"
            #expect(!browser.selectAllCards())
        }
    }

    @Test func movesAcrossVisibleCardsAndStopsAtTheEnds() throws {
        try withBrowser { browser, clips, _ in
            browser.open()
            #expect(browser.selected?.id == clips[0].id)
            #expect(browser.move(keyCode: UInt16(kVK_LeftArrow), modifiers: [], editingSearch: true, composing: false))
            #expect(browser.selected?.id == clips[0].id)
            #expect(browser.move(keyCode: UInt16(kVK_RightArrow), modifiers: [], editingSearch: true, composing: false))
            #expect(browser.selected?.id == clips[1].id)
            #expect(browser.move(keyCode: UInt16(kVK_DownArrow), modifiers: [], editingSearch: false, composing: false))
            #expect(browser.selected?.id == clips[2].id)
            #expect(browser.move(keyCode: UInt16(kVK_RightArrow), modifiers: [], editingSearch: false, composing: false))
            #expect(browser.selected?.id == clips[2].id)
            #expect(browser.move(keyCode: UInt16(kVK_UpArrow), modifiers: .command, editingSearch: false, composing: false))
            #expect(browser.selected?.id == clips[0].id)
        }
    }

    @Test func searchKeepsCaretAndCompositionKeysAndMovesOnlyWithinResults() throws {
        try withBrowser { browser, clips, _ in
            browser.search = "alpha"
            browser.open()
            #expect(!browser.move(keyCode: UInt16(kVK_RightArrow), modifiers: [], editingSearch: true, composing: false))
            #expect(!browser.move(keyCode: UInt16(kVK_DownArrow), modifiers: [], editingSearch: true, composing: true))
            #expect(browser.selected?.id == clips[0].id)
            #expect(browser.move(keyCode: UInt16(kVK_DownArrow), modifiers: [], editingSearch: true, composing: false))
            #expect(browser.selected?.id == clips[2].id)

            browser.favoritesOnly = true
            #expect(browser.selected?.id == clips[0].id)
            #expect(browser.move(keyCode: UInt16(kVK_RightArrow), modifiers: [], editingSearch: false, composing: false))
            #expect(browser.selected?.id == clips[0].id)

            browser.search = "none"
            #expect(!browser.move(keyCode: UInt16(kVK_DownArrow), modifiers: [], editingSearch: false, composing: false))
            #expect(browser.selected == nil)
        }
    }

    @Test func quickPasteUsesTheCurrentFilteredOrder() throws {
        try withBrowser { browser, clips, _ in
            browser.selectedID = clips[2].id
            #expect(browser.quickPaste(keyCode: UInt16(kVK_ANSI_1), modifiers: .command)?.id == clips[0].id)
            #expect(browser.quickPaste(keyCode: UInt16(kVK_ANSI_9), modifiers: .command) == nil)
            #expect(browser.quickPaste(keyCode: UInt16(kVK_ANSI_0), modifiers: .command) == nil)
            #expect(browser.quickPaste(keyCode: UInt16(kVK_ANSI_1), modifiers: []) == nil)
            #expect(browser.quickPaste(keyCode: UInt16(kVK_ANSI_1), modifiers: [.command, .shift])?.id == clips[0].id)
            #expect(browser.quickPaste(keyCode: UInt16(kVK_ANSI_1), modifiers: [.command, .control]) == nil)

            browser.sourceName = "Notes"
            browser.search = "alpha"
            #expect(browser.quickPaste(keyCode: UInt16(kVK_ANSI_1), modifiers: .command)?.id == clips[2].id)
            #expect(browser.quickPaste(keyCode: UInt16(kVK_ANSI_2), modifiers: .command) == nil)
            browser.kind = .files
            #expect(browser.quickPaste(keyCode: UInt16(kVK_ANSI_1), modifiers: .command) == nil)
        }
    }

    @Test func shiftQuickPasteOnlyAcceptsTextAndLinks() throws {
        try withBrowser(payloads: [.image(Data(), format: "public.png"), .link("https://example.com")]) { browser, clips, _ in
            #expect(browser.quickPaste(keyCode: UInt16(kVK_ANSI_1), modifiers: .command)?.id == clips[0].id)
            #expect(browser.quickPaste(keyCode: UInt16(kVK_ANSI_1), modifiers: [.command, .shift]) == nil)
            #expect(browser.quickPaste(keyCode: UInt16(kVK_ANSI_2), modifiers: [.command, .shift])?.id == clips[1].id)
        }
    }

    @Test func previewFollowsSelectionAndResetsWhenTheShelfOpens() throws {
        try withBrowser { browser, clips, _ in
            browser.open()
            browser.togglePreview()
            #expect(browser.isPreviewing)
            #expect(browser.move(keyCode: UInt16(kVK_RightArrow), modifiers: [], editingSearch: false, composing: false))
            #expect(browser.selected?.id == clips[1].id)
            #expect(browser.isPreviewing)
            browser.togglePreview()
            #expect(!browser.isPreviewing)
            browser.togglePreview()
            browser.open()
            #expect(!browser.isPreviewing)
            browser.search = "no matching card"
            browser.togglePreview()
            #expect(!browser.isPreviewing)
        }
    }

    @Test func groupAndSourceFiltersCombineWithoutChangingHistory() throws {
        try withBrowser { browser, clips, _ in
            let group = try #require(browser.store.createGroup(name: "工作"))
            #expect(browser.store.toggleGroup(group.id, for: clips[1].id))
            #expect(browser.store.toggleGroup(group.id, for: clips[2].id))
            browser.favoritesOnly = true
            #expect(browser.results.map(\.id) == clips.map(\.id))
            browser.groupID = group.id
            #expect(browser.results.map(\.id) == [clips[1].id, clips[2].id])
            browser.sourceName = "Notes"
            #expect(browser.results.map(\.id) == [clips[2].id])
            browser.favoritesOnly = false
            browser.sourceName = nil
            #expect(browser.results.map(\.id) == clips.map(\.id))
        }
    }

    @Test func groupSwitchingKeepsFiltersAndStopsAtTheEnds() throws {
        try withBrowser { browser, clips, _ in
            let group = try #require(browser.store.createGroup(name: "工作"))
            #expect(browser.store.toggleGroup(group.id, for: clips[2].id))
            browser.search = "alpha"
            #expect(!browser.switchGroup(-1))
            #expect(browser.switchGroup(1))
            #expect(browser.favoritesOnly)
            #expect(browser.groupID == nil)
            #expect(browser.switchGroup(1))
            #expect(browser.groupID == group.id)
            #expect(browser.selected?.id == clips[2].id)
            #expect(!browser.switchGroup(1))
            #expect(browser.switchGroup(-1))
            #expect(browser.switchGroup(-1))
            #expect(!browser.favoritesOnly)
            #expect(browser.search == "alpha")
        }
    }

    @Test func undoRestoresTheDeletedCardAndItsArchiveOrder() throws {
        try withBrowser { browser, clips, archiveURL in
            let group = try #require(browser.store.createGroup(name: "工作"))
            #expect(browser.store.toggleGroup(group.id, for: clips[1].id))
            #expect(browser.store.toggleFavorite(clips[1].id))
            browser.selectedID = clips[1].id

            #expect(!browser.canUndoDeletion)
            #expect(browser.deleteSelected())
            #expect(browser.canUndoDeletion)
            #expect(browser.selected?.id == clips[2].id)
            browser.store.flush()
            let archive = ClipArchive(legacyURL: archiveURL)
            #expect(try archive.load().clips.map(\.id) == [clips[0].id, clips[2].id])

            #expect(browser.undoDeletion())
            #expect(!browser.canUndoDeletion)
            #expect(browser.selected?.id == clips[1].id)
            #expect(browser.results.map(\.id) == clips.map(\.id))
            browser.store.flush()
            let saved = try archive.load().clips
            #expect(saved.map(\.id) == clips.map(\.id))
            #expect(saved[1].groupIDs == [group.id])
            #expect(saved[1].isFavorite)
            #expect(saved[1].date == clips[1].date)
        }
    }

    private func withBrowser(
        payloads: [ClipPayload] = ["alpha one", "beta", "alpha two"].map { .text($0, rtf: nil, html: nil) },
        _ run: (ShelfBrowser, [Clip], URL) throws -> Void
    ) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClipShelfBrowser-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let archive = folder.appending(path: "History.plist")
        let board = NSPasteboard.withUniqueName()
        defer {
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: folder)
        }

        let now = Date()
        let clips = payloads.enumerated().map { index, payload in
            Clip(id: UUID(), payload: payload,
                 date: now.addingTimeInterval(-Double(index)),
                 sourceName: index == 2 ? "Notes" : "Safari", isFavorite: index == 0)
        }
        try PropertyListEncoder().encode(clips).write(to: archive)
        let browser = ShelfBrowser(store: ClipboardStore(board: board, archiveURL: archive))
        defer { browser.store.flush() }
        try run(browser, clips, archive)
    }

    @Test func extendsAndCombinesSelectionInVisibleOrder() throws {
        try withBrowser { browser, clips, _ in
            browser.selectCard(clips[2].id)
            browser.selectCard(clips[0].id, extending: true)
            #expect(browser.selectedCards(in: browser.results).map(\.id) == clips.map(\.id))
            browser.selectCard(clips[1].id, toggling: true)
            let selected = browser.selectedCards(in: browser.results)
            #expect(selected.map(\.id) == [clips[0].id, clips[2].id])
            let merged = try #require(browser.joined(selected, separator: "\n"))
            #expect(merged.payload == .text("alpha one\nalpha two", rtf: nil, html: nil))
            #expect(browser.joined(selected, separator: " ")?.payload.previewText == "alpha one alpha two")
            let image = Clip(id: UUID(), payload: .image(Data(), format: "public.png"), date: .now)
            #expect(browser.joined([selected[0], image], separator: "\n") == nil)
            browser.open()
            #expect(browser.multiSelection.isEmpty)
        }
    }
}
