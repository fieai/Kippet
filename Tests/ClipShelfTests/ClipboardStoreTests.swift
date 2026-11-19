import AppKit
import Testing
import UniformTypeIdentifiers
@testable import ClipShelf

@MainActor
struct ClipboardStoreTests {
    @Test func derivedTypeFilterTracksEditsAndKeepsTheTextKind() async throws {
        try await withStore { store, _, _, _ in
            let clip = try #require(store.createSnippet(title: "", content: "#14B8A6", in: nil))
            let browser = ShelfBrowser(store: store)
            browser.contentType = .color
            #expect(browser.results.map(\.id) == [clip.id])
            #expect(store.editText(clip.id, text: "验证码 482913")?.payload.kind == .text)
            #expect(browser.results.isEmpty)
            browser.contentType = .oneTimeCode
            #expect(browser.results.map(\.id) == [clip.id])
            browser.kind = .text
            #expect(browser.results.map(\.id) == [clip.id])
        }
    }

    @Test func transformedClipIsTemporaryUntilPlainTextCopyIsPolled() async throws {
        try await withStore { store, board, _, _ in
            let source = "https://example.com/page?utm_source=source#part"
            Self.copy(source, to: board)
            #expect(store.poll())
            let original = try #require(store.clips.first)
            let transformed = try #require(store.transformed(original, with: .cleanURL))
            #expect(transformed.id != original.id)
            #expect(transformed.payload == .link("https://example.com/page#part"))
            #expect(store.clips.map(\.id) == [original.id])
            #expect(board.string(forType: .string) == source)

            #expect(await store.copy(transformed, plainText: true) == .written(board.changeCount))
            #expect(board.string(forType: .string) == "https://example.com/page#part")
            #expect(board.string(forType: .URL) == nil)
            #expect(store.clips.map(\.id) == [original.id])
            #expect(store.poll())
            #expect(store.clips.first?.payload == transformed.payload)
            #expect(store.clips.first?.id != transformed.id)
            #expect(!store.poll())

            #expect(await store.copy(original) == .written(board.changeCount))
            #expect(!store.poll())
        }
    }

    @Test func transformAndFormatResultsDiscardRichRepresentations() async throws {
        try await withStore { store, board, _, _ in
            let html = "<b>https://example.com/page</b>"
            let text = Clip(
                id: UUID(), payload: .text("https://example.com/page", rtf: nil, html: Data(html.utf8)), date: .now
            )
            let transformed = try #require(store.transformed(text, with: .trimWhitespace))
            #expect(transformed.payload == .text("https://example.com/page", rtf: nil, html: nil))
            #expect(store.transformed(text, with: .jsonPretty) == nil)
            let markdown = try #require(store.markdown(text))
            #expect(markdown.payload == .text("**https://example.com/page**", rtf: nil, html: nil))
            let source = try #require(store.htmlSource(text))
            #expect(source.payload == .text(html, rtf: nil, html: nil))
            let file = Clip(id: UUID(), payload: .files([URL(fileURLWithPath: "/tmp/sample")]), date: .now)
            #expect(store.transformed(file, with: .uppercase) == nil)
            #expect(store.markdown(file) == nil)
            #expect(store.htmlSource(file) == nil)
            #expect(store.clips.isEmpty)
            #expect(board.string(forType: .string) == nil)
        }
    }

    @Test func snippetsKeepWhitespaceRecognizeLinksAndSaveWithoutWritingClipboard() async throws {
        try await withStore { store, board, archive, preferences in
            Self.copy("clipboard contents", to: board)
            let group = try #require(store.createGroup(name: "常用片段"))
            let command = "\n  swift test\n  swift build\n"
            let text = try #require(store.createSnippet(title: "  测试命令  ", content: command, in: group.id))
            let link = try #require(store.createSnippet(title: "", content: " https://example.com/help\n", in: nil))

            #expect(store.createSnippet(title: "empty", content: " \n", in: nil) == nil)
            #expect(store.createSnippet(title: "", content: "unknown board", in: UUID()) == nil)
            #expect(text.payload == .text(command, rtf: nil, html: nil))
            #expect(text.title == "测试命令")
            #expect(text.groupIDs == [group.id])
            #expect(link.payload == .link("https://example.com/help"))
            #expect(link.isFavorite)
            #expect(board.string(forType: .string) == "clipboard contents")

            store.flush()
            let saved = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            #expect(saved.filtered(query: "测试命令", kind: nil, favoritesOnly: true, groupID: group.id).map(\.id) == [text.id])
            #expect(saved.clips.map(\.id) == [link.id, text.id])
        }
    }

    @Test func pinboardAndCardOrderingPersistIndependentlyIncludingUndo() async throws {
        try await withStore { store, board, archive, preferences in
            let first = try #require(store.createGroup(name: "常用"))
            let second = try #require(store.createGroup(name: "命令"))
            let a = try #require(store.createSnippet(title: "", content: "echo A", in: nil))
            let b = try #require(store.createSnippet(title: "", content: "echo B", in: nil))
            let c = try #require(store.createSnippet(title: "", content: "echo C", in: nil))

            #expect(!store.addCards([a.id, UUID()], to: first.id))
            #expect(store.addCards([a.id, b.id, c.id], to: first.id))
            #expect(store.addCards([a.id, b.id], to: second.id))
            #expect(store.addCards([a.id], to: second.id))
            store.moveGroup(second.id, onto: first.id)
            #expect(store.moveCard(a.id, onto: c.id, in: first.id))
            #expect(!store.moveCard(c.id, onto: b.id, in: second.id))

            #expect(store.filtered(query: "echo", kind: .text, favoritesOnly: true, groupID: first.id).map(\.id)
                == [a.id, c.id, b.id])
            #expect(store.filtered(query: "", kind: nil, favoritesOnly: true, groupID: second.id).map(\.id)
                == [b.id, a.id])
            let deletion = try #require(store.remove(c.id))
            #expect(store.restore(deletion))

            store.flush()
            let saved = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            #expect(saved.groups.map(\.id) == [second.id, first.id])
            #expect(saved.filtered(query: "", kind: nil, favoritesOnly: true, groupID: first.id).map(\.id)
                == [a.id, c.id, b.id])
            #expect(saved.clips.map(\.id) == [c.id, b.id, a.id])
        }
    }

    @Test func pinningOverCapacityLeavesTheWholeSelectionUnchanged() async throws {
        try await withStore { _, board, archive, preferences in
            let group = ClipGroup(id: UUID(), name: "保存的卡片")
            let saved = (0..<4).map { _ in
                Clip(id: UUID(), payload: .image(Data(count: 8 * 1_024 * 1_024 - 2), format: "public.png"),
                     date: .now, isFavorite: true)
            }
            let candidates = ["small", "this overflows the remaining capacity"].map {
                Clip(id: UUID(), payload: .text($0, rtf: nil, html: nil), date: .now)
            }
            try ClipArchive(legacyURL: archive).write(upserting: candidates + saved, removing: [], groups: [group])
            let store = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            #expect(!store.addCards(Set(candidates.map(\.id)), to: group.id))
            #expect(store.filtered(query: "", kind: nil, favoritesOnly: true, groupID: group.id).isEmpty)
            #expect(store.addCards([candidates[0].id], to: group.id))
        }
    }

    @Test func imageTextIsSearchableAfterLocalRecognitionAndReload() async throws {
        try await withStore { store, board, archive, preferences in
            let png = try Self.ocrSample()
            board.clearContents()
            #expect(board.setData(png, forType: .png))
            #expect(store.poll(sourceName: "Screenshot"))
            let clip = try #require(store.clips.first)
            #expect(store.filtered(query: "苹果", kind: nil, favoritesOnly: false).isEmpty)
            let recognized = try #require(await store.recognizeText(clip.id))
            #expect(store.filtered(query: "苹果", kind: nil, favoritesOnly: false).map(\.id) == [clip.id])
            #expect(recognized.localizedStandardContains("LANTERN"))
            #expect(recognized.contains("苹果手机"))
            #expect(store.filtered(query: "lantern", kind: .image, favoritesOnly: false).map(\.id) == [clip.id])

            store.flush()
            let restored = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            #expect(restored.clips.first?.recognizedText == recognized)
            #expect(restored.filtered(query: "手机", kind: .image, favoritesOnly: false).map(\.id) == [clip.id])
        }
    }

    @Test func largeHistorySearchKeepsLocalizedMatchesInOrderAndRefreshesAfterEdits() async throws {
        try await withStore { _, board, archive, preferences in
            let items = (0..<1_260).map { index in
                var clip = Clip(id: UUID(), payload: .text("记录 \(index)", rtf: nil, html: nil), date: .now)
                switch index % 4 {
                case 0: clip.title = "中文 Café"
                case 1:
                    clip.payload = .image(Data([1]), format: UTType.png.identifier)
                    clip.recognizedText = "中文 OCR cafe\u{301}"
                case 2:
                    clip.payload = .files([URL(fileURLWithPath: "/tmp/中文/Café.txt")])
                default: clip.sourceBundleIdentifier = "中文.CAFÉ"
                }
                return clip
            }
            try ClipArchive(legacyURL: archive).write(upserting: items, removing: [])
            let store = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            store.updateRetention(limit: items.count, days: 0)
            #expect(store.clips.count == items.count)
            for query in ["中文", "cafe", "OCR", "未出现"] {
                let expected = store.clips.filter { clip in
                    [clip.title, clip.recognizedText, clip.payload.searchableText, clip.source?.name]
                        .contains { $0?.localizedStandardContains(query) == true }
                }.map(\.id)
                #expect(store.filtered(query: " \(query) ", kind: nil, favoritesOnly: false).map(\.id) == expected)
                #expect(store.filtered(query: query, kind: nil, favoritesOnly: false).map(\.id) == expected)
            }

            let clip = try #require(store.clips.first { $0.title != nil })
            #expect(store.filtered(query: "改名", kind: nil, favoritesOnly: false).isEmpty)
            #expect(store.rename(clip.id, title: "改名"))
            #expect(store.filtered(query: "改名", kind: nil, favoritesOnly: false).map(\.id) == [clip.id])
            let deletion = try #require(store.remove(clip.id))
            #expect(store.filtered(query: "改名", kind: nil, favoritesOnly: false).isEmpty)
            #expect(store.restore(deletion))
            #expect(store.filtered(query: "改名", kind: nil, favoritesOnly: false).map(\.id) == [clip.id])
        }
    }

    @Test func warmingLegacyHistoryRecognizesImagesWithoutReadingFileOnlyCards() async throws {
        try await withStore { _, board, archive, preferences in
            let png = try Self.ocrSample()
            let image = Clip(id: UUID(), payload: .image(png, format: UTType.png.identifier), date: .now)
            let file = Clip(id: UUID(), payload: .files([URL(fileURLWithPath: "/tmp/unavailable.png")]), date: .now)
            try ClipArchive(legacyURL: archive).write(upserting: [image, file], removing: [])
            let store = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            #expect(store.clips.allSatisfy { $0.recognizedText == nil })
            store.prewarmOCR()
            let deadline = ContinuousClock.now + .seconds(8)
            while store.clips.first?.recognizedText == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(store.clips.first?.recognizedText?.localizedStandardContains("LANTERN") == true)
            #expect(store.clips.last?.recognizedText == nil)
            #expect(await store.recognizeText(file.id) == nil)
        }
    }

    private static func ocrSample() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1_160, pixelsHigh: 320, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1_160, height: 320)).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 72, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        ("CLIPSHELF LANTERN" as NSString).draw(at: NSPoint(x: 45, y: 187), withAttributes: attributes)
        ("苹果手机" as NSString).draw(at: NSPoint(x: 45, y: 55), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func captureSearchAndRestoreFavorites() async throws {
        try await withStore { store, board, archive, preferences in
            Self.copy("alpha report", to: board)
            store.poll(sourceName: "Writer")
            let first = try #require(store.clips.first)
            #expect(store.toggleFavorite(first.id))

            Self.copy("https://example.com/notes", to: board)
            store.poll(sourceName: "Safari")
            #expect(store.filtered(query: "NOTES", kind: .link, favoritesOnly: false).count == 1)
            #expect(store.filtered(query: "writer", kind: .text, favoritesOnly: true).count == 1)

            Self.copy("alpha report", to: board)
            store.poll()
            #expect(store.clips.count == 2)
            #expect(store.clips.first?.id == first.id)
            #expect(store.clips.first?.isFavorite == true)
            store.clearHistory()
            store.flush()

            let restored = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            #expect(restored.clips.map(\.id) == [first.id])
            #expect(restored.storageError == nil)
        }
    }

    @Test func pauseAndConcealedContentAreSkipped() async throws {
        try await withStore { store, board, _, _ in
            store.toggleCapture()
            Self.copy("paused", to: board)
            store.toggleCapture()
            store.poll()
            #expect(store.clips.isEmpty)

            Self.copy("concealed", to: board, concealed: true)
            store.poll()
            #expect(store.clips.isEmpty)

            Self.copy("record after resume", to: board)
            store.poll()
            #expect(store.clips.first?.payload.previewText == "record after resume")
        }
    }

    @Test func groupsKeepCardsAcrossClearRenameAndDeletion() async throws {
        try await withStore { store, board, archive, preferences in
            Self.copy("in two groups", to: board)
            store.poll(sourceName: "Editor")
            let card = try #require(store.clips.first)
            let work = try #require(store.createGroup(name: "Work"))
            let links = try #require(store.createGroup(name: "Links"))
            #expect(store.createGroup(name: " work ") == nil)
            #expect(store.toggleGroup(work.id, for: card.id))
            #expect(store.toggleGroup(links.id, for: card.id))
            #expect(store.renameGroup(work.id, name: "  Daily  "))
            #expect(store.clips.first?.isFavorite == false)

            Self.copy("unfiled", to: board)
            store.poll(sourceName: "Other")
            store.clearHistory()
            store.flush()
            let restored = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            #expect(restored.groups.map(\.name) == ["Daily", "Links"])
            #expect(restored.clips.map(\.id) == [card.id])
            #expect(restored.clips.first?.groupIDs == Set([work.id, links.id]))
            restored.removeGroup(work.id)
            #expect(restored.clips.first?.isFavorite == false)
            restored.removeGroup(links.id)
            restored.flush()

            let afterDeletion = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            #expect(afterDeletion.groups.isEmpty)
            #expect(afterDeletion.clips.first?.groupIDs == nil)
            #expect(afterDeletion.clips.first?.isFavorite == true)
        }
    }

    @Test func keepsOneThousandHistoryCardsAndPersistsEviction() async throws {
        try await withStore { _, board, archive, preferences in
            let items = (0..<1_000).map { index in
                Clip(id: UUID(), payload: .text("entry \(index)", rtf: nil, html: nil), date: .now)
            }
            try ClipArchive(legacyURL: archive).write(upserting: items, removing: [])
            let store = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            #expect(store.clips.count == 1_000)
            Self.copy("new entry", to: board)
            store.poll()
            store.flush()
            let restored = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            #expect(restored.clips.count == 1_000)
            #expect(restored.clips.first?.payload.previewText == "new entry")
            #expect(restored.clips.last?.id == items[998].id)
        }
    }

    @Test func copyPreservesFormatsAndDoesNotRecordItself() async throws {
        try await withStore { store, board, _, _ in
            let html = Data("<strong>sample</strong>".utf8)
            let item = NSPasteboardItem()
            item.setString("sample", forType: .string)
            item.setData(html, forType: .html)
            board.clearContents()
            board.writeObjects([item])
            store.poll()
            let clip = try #require(store.clips.first)
            #expect(await store.copy(clip) == .written(board.changeCount))
            #expect(store.pendingChange == nil)
            #expect(board.data(forType: .html) == html)
            store.poll()
            #expect(store.clips.first?.date == clip.date)

            #expect(await store.copy(clip, plainText: true) == .written(board.changeCount))
            #expect(board.data(forType: .html) == nil)
            #expect(board.string(forType: .string) == "sample")
        }
    }

    @Test func delayedCaptureDoesNotReadANewerChangeUnderAnOlderSource() async throws {
        try await withStore { store, board, _, _ in
            Self.copy("first", to: board)
            let first = try #require(store.pendingChange)
            Self.copy("second", to: board)
            let second = try #require(store.pendingChange)
            #expect(first != second)

            store.poll(sourceName: "Old app", expectedChange: first)
            #expect(store.clips.isEmpty)
            #expect(store.pendingChange == second)

            store.poll(sourceName: "New app", expectedChange: second)
            #expect(store.clips.first?.payload.previewText == "second")
            #expect(store.clips.first?.sourceName == "New app")
            #expect(store.pendingChange == nil)
        }
    }

    @Test func excludedChangeIsAcknowledgedWithoutCreatingAClip() async throws {
        try await withStore { store, board, _, _ in
            Self.copy("private", to: board)
            let excluded = try #require(store.pendingChange)
            #expect(!store.poll(
                sourceBundleIdentifier: "app.excluded", expectedChange: excluded, captureAllowed: false
            ))
            #expect(store.pendingChange == nil)

            #expect(!store.poll(sourceBundleIdentifier: "app.allowed"))
            #expect(store.clips.isEmpty)
            #expect(board.string(forType: .string) == "private")

            Self.copy("public", to: board)
            #expect(store.poll(sourceName: "Editor", sourceBundleIdentifier: "app.allowed"))
            #expect(store.clips.first?.source == ClipSource(name: "Editor", bundleIdentifier: "app.allowed"))
        }
    }

    @Test func sourceFilterDistinguishesAppsWithMatchingNames() async throws {
        try await withStore { store, board, _, _ in
            Self.copy("legacy clipboard", to: board)
            store.poll(sourceName: "Editor")
            Self.copy("first editor", to: board)
            store.poll(sourceName: "Editor", sourceBundleIdentifier: "app.first")
            Self.copy("second editor", to: board)
            store.poll(sourceName: "Editor", sourceBundleIdentifier: "app.second")

            #expect(store.sources.count == 2)
            let results = store.filtered(
                query: "", kind: nil, favoritesOnly: false, sourceName: "Editor", sourceBundleIdentifier: "app.first"
            )
            #expect(results.map(\.payload.previewText) == ["first editor", "legacy clipboard"])
            #expect(store.filtered(query: "", kind: nil, favoritesOnly: false, sourceName: "Editor").count == 3)
        }
    }

    @Test func cardTitleAndTextEditKeepSavedIdentityAndDiscardStaleFormats() async throws {
        try await withStore { store, board, archive, preferences in
            let item = NSPasteboardItem()
            item.setString("before", forType: .string)
            item.setData(Data("<strong>before</strong>".utf8), forType: .html)
            board.clearContents()
            board.writeObjects([item])
            store.poll(sourceName: "Editor", sourceBundleIdentifier: "app.editor")

            let original = try #require(store.clips.first)
            let group = try #require(store.createGroup(name: "Snippets", color: .purple))
            #expect(store.renameGroup(group.id, name: "Drafts"))
            #expect(store.toggleGroup(group.id, for: original.id))
            #expect(store.rename(original.id, title: "  Template  "))
            #expect(store.editText(original.id, text: "before")?.payload == original.payload)
            #expect(store.editText(original.id, text: "") == nil)

            Self.copy("newer", to: board)
            store.poll()
            let edited = try #require(store.editText(original.id, text: "after"))
            #expect(edited.date == original.date)
            #expect(edited.sourceBundleIdentifier == "app.editor")
            #expect(edited.groupIDs == [group.id])
            #expect(store.filtered(query: "template", kind: nil, favoritesOnly: false).first?.id == original.id)
            #expect(await store.copy(edited) == .written(board.changeCount))
            #expect(board.string(forType: .string) == "after")
            #expect(board.data(forType: .html) == nil)

            store.flush()
            let reloaded = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            #expect(reloaded.clips.last?.id == original.id)
            #expect(reloaded.clips.last?.title == "Template")
            #expect(reloaded.clips.last?.payload == .text("after", rtf: nil, html: nil))
            #expect(reloaded.groups.first?.color == .purple)

            Self.copy("after", to: board)
            store.poll(sourceName: "Terminal", sourceBundleIdentifier: "app.terminal")
            #expect(store.clips.first?.id == original.id)
            #expect(store.clips.first?.title == "Template")
            #expect(store.clips.first?.groupIDs == [group.id])
            #expect(store.clips.first?.sourceBundleIdentifier == "app.terminal")
        }
    }

    @Test func retentionRulesExpiresOrdinaryCardsAndKeepsFavoritesAndPinboards() async throws {
        try await withStore { _, board, archive, preferences in
            let group = ClipGroup(id: UUID(), name: "Keep")
            let oldDate = Date.now.addingTimeInterval(-5 * 86_400)
            let saved = [
                Clip(id: UUID(), payload: .link("https://example.com/pinned"), date: oldDate, groupIDs: [group.id]),
                Clip(id: UUID(), payload: .link("https://example.com/starred"), date: oldDate, isFavorite: true),
            ]
            let recent = (0..<103).map { index in
                Clip(id: UUID(), payload: .text("recent \(index)", rtf: nil, html: nil), date: .now)
            }
            let tooOld = Clip(id: UUID(), payload: .link("https://example.com/expired"), date: oldDate)
            try ClipArchive(legacyURL: archive).write(upserting: recent + saved + [tooOld], removing: [], groups: [group])
            let store = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            store.updateRetention(limit: 100, days: 2)
            store.flush()

            let reloaded = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            #expect(reloaded.clips.map(\.id) == (Array(recent.prefix(100)) + saved).map(\.id))
        }
    }

    @Test func ruleExpirySweepsHistoryAndKeepsStarredAndPinnedClips() async throws {
        try await withStore { store, board, archiveURL, _ in
            for code in ["482913", "440217", "310427"] {
                Self.copy("验证码 \(code)", to: board)
                #expect(store.poll())
            }
            let expiring = try #require(store.clips.last)
            let deadline = try #require(expiring.expiresAt)
            #expect(deadline.timeIntervalSince(expiring.date) == 120)
            let starred = store.clips[0], pinned = store.clips[1]
            let group = try #require(store.createGroup(name: "保留"))
            #expect(store.toggleFavorite(starred.id))
            #expect(store.addCards([pinned.id], to: group.id))
            #expect(store.clips.filter(\.isSaved).allSatisfy { $0.expiresAt == nil })

            store.flush()
            let archive = ClipArchive(legacyURL: archiveURL)
            #expect(try archive.load().clips.last?.expiresAt == deadline)
            store.sweepExpired(now: deadline)
            #expect(store.clips.map(\.id) == [starred.id, pinned.id])
            store.flush()
            #expect(try archive.load().clips.map(\.id) == [starred.id, pinned.id])
        }
    }

    @Test func expirySweepsOnStoreLaunch() async throws {
        try await withStore { _, board, archiveURL, preferences in
            let expired = Clip(id: UUID(), payload: .link("https://example.com/expired"), date: .distantPast,
                               expiresAt: .distantPast)
            let oldFavorite = Clip(id: UUID(), payload: .link("https://example.com/saved"), date: .distantPast,
                                   isFavorite: true, expiresAt: .distantPast)
            let archive = ClipArchive(legacyURL: archiveURL)
            try archive.write(upserting: [oldFavorite, expired], removing: [])
            let store = ClipboardStore(board: board, archiveURL: archiveURL, preferences: preferences)
            #expect(store.clips.map(\.id) == [oldFavorite.id])
            store.flush()
            #expect(try archive.load().clips.map(\.id) == [oldFavorite.id])
        }
    }

    @Test func skipsPasswordManagerRecaptureAndFilesNewFigmaCopies() async throws {
        try await withStore { store, board, _, _ in
            let group = try #require(store.createGroup(name: "设计"))
            let source = "com.figma.Desktop"
            store.shelfPreferences.rules.append(
                ClipRule(id: UUID(), name: "设计", isEnabled: true,
                         match: .init(sourceBundleIdentifiers: [source]), action: .addToGroup(group.id))
            )
            Self.copy("existing note", to: board)
            #expect(store.poll(sourceBundleIdentifier: "com.apple.Notes"))
            let original = try #require(store.clips.first)
            Self.copy("existing note", to: board)
            #expect(!store.poll(sourceBundleIdentifier: "com.bitwarden.desktop"))
            #expect(store.clips.map(\.id) == [original.id])
            #expect(store.clips.first?.sourceBundleIdentifier == original.sourceBundleIdentifier)

            Self.copy("design notes", to: board)
            #expect(store.poll(sourceBundleIdentifier: source))
            #expect(store.clips.first?.groupIDs == [group.id])
            store.removeGroup(group.id)
            Self.copy("design revision", to: board)
            #expect(store.poll(sourceBundleIdentifier: source))
            #expect(store.clips.first?.isSaved == false)
        }
    }

    @Test func enablingColorPresetCreatesItsPinboard() async throws {
        try await withStore { store, board, archiveURL, _ in
            #expect(store.groups.isEmpty)
            store.setRuleEnabled(ClipRule.colorPresetID, enabled: true)
            let group = try #require(store.groups.first)
            #expect(group.name == "颜色")
            store.setRuleEnabled(ClipRule.colorPresetID, enabled: false)
            store.setRuleEnabled(ClipRule.colorPresetID, enabled: true)
            #expect(store.groups == [group])
            Self.copy("#14B8A6", to: board)
            #expect(store.poll())
            #expect(store.clips.first?.groupIDs == [group.id])
            store.flush()
            #expect(try ClipArchive(legacyURL: archiveURL).load().groups == [group])
        }
    }

    @Test func roundTripsImagesAndMultipleFileURLs() async throws {
        try await withStore { store, board, _, _ in
            let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII="))
            board.clearContents()
            board.setData(png, forType: .png)
            store.poll()
            let image = try #require(store.clips.first)
            #expect(image.payload.kind == .image)
            #expect(await store.copy(image) == .written(board.changeCount))
            #expect(board.data(forType: .png) == png)

            let files = [URL(fileURLWithPath: "/tmp/ClipShelf-A.txt"), URL(fileURLWithPath: "/tmp/ClipShelf-B.txt")]
            board.clearContents()
            board.writeObjects(files.map { $0 as NSURL })
            store.poll()
            let clip = try #require(store.clips.first)
            #expect(clip.payload == .files(files))
            #expect(await store.copy(clip) == .written(board.changeCount))
            let written = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            #expect(written == files)
        }
    }

    @Test func legacyJPGCardWritesImageDataAndCanStillCopyOriginalFile() async throws {
        try await withStore { store, board, archive, preferences in
            let folder = archive.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "sample.JPG")
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 6, pixelsHigh: 4, bitsPerSample: 8,
                samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            bitmap.bitmapData?.initialize(repeating: 127, count: bitmap.bytesPerPlane)
            let jpeg = try #require(bitmap.representation(using: .jpeg, properties: [:]))
            try jpeg.write(to: file)
            board.clearContents()
            board.writeObjects([file as NSURL])
            store.poll(sourceName: "Fixture")
            let oldCard = try #require(store.clips.first)
            #expect(oldCard.imageSnapshot == nil)

            #expect(await store.copy(oldCard) == .written(board.changeCount))
            let image = try #require(NSImage(pasteboard: board))
            #expect(image.size.width == 6)
            #expect(image.size.height == 4)
            #expect(board.data(forType: .png) != nil)
            #expect(board.string(forType: .fileURL) == nil)

            #expect(await store.copy(oldCard, asFile: true) == .written(board.changeCount))
            #expect(board.string(forType: .fileURL) == file.absoluteString)
            let originalImage = Clip(id: UUID(), payload: .image(jpeg, format: UTType.jpeg.identifier), date: .now)
            #expect(await store.copy(originalImage) == .written(board.changeCount))
            let png = try #require(board.data(forType: .png))
            #expect(board.data(forType: .init(UTType.jpeg.identifier)) == jpeg)
            #expect(await store.copy(originalImage) == .written(board.changeCount))
            #expect(board.data(forType: .png) == png)

            #expect(store.toggleFavorite(oldCard.id))
            let repaired = try #require(await store.attachImage(from: file, to: oldCard.id))
            #expect(repaired.id == oldCard.id)
            #expect(repaired.isFavorite)
            #expect(repaired.payload == oldCard.payload)
            #expect(store.clips.count == 1)
            store.flush()
            let reloaded = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)
            let saved = try #require(reloaded.clips.first)
            try FileManager.default.removeItem(at: file)
            #expect(await store.copy(saved) == .written(board.changeCount))
            let previousImage = try #require(board.data(forType: .png))
            #expect(await store.copy(oldCard) == .imageUnavailable)
            #expect(board.data(forType: .png) == previousImage)
        }
    }

    @Test func clipboardImageSurvivesWhenItsFileURLIsAlsoPresent() async throws {
        try await withStore { store, board, archive, _ in
            let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII="))
            let file = archive.deletingLastPathComponent().appending(path: "original.jpg")
            let item = NSPasteboardItem()
            item.setString(file.absoluteString, forType: .fileURL)
            item.setData(png, forType: .png)
            board.clearContents()
            board.writeObjects([item])
            store.poll()
            let captured = try #require(store.clips.first)
            #expect(captured.payload == .files([file]))
            #expect(captured.previewPayload == .image(png, format: UTType.png.identifier))
            #expect(await store.copy(captured) == .written(board.changeCount))
            #expect(board.data(forType: .png) == png)
            #expect(await store.copy(captured, asFile: true) == .written(board.changeCount))
            #expect(board.string(forType: .fileURL) == file.absoluteString)

            // A later copy from the same path may represent a different file.
            board.clearContents()
            board.writeObjects([file as NSURL])
            store.poll()
            #expect(store.clips.count == 2)
            #expect(store.clips.first?.imageSnapshot == nil)
            #expect(store.clips.last?.id == captured.id)
        }
    }

    private static func copy(_ text: String, to board: NSPasteboard, concealed: Bool = false) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if concealed {
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
        board.clearContents()
        board.writeObjects([item])
    }

    private func withStore(
        _ run: @MainActor (ClipboardStore, NSPasteboard, URL, UserDefaults) async throws -> Void
    ) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClipShelfTests-\(UUID())")
        let archive = folder.appending(path: "History.plist")
        let board = NSPasteboard.withUniqueName()
        let suite = "ClipShelfTests-\(UUID())"
        let preferences = try #require(UserDefaults(suiteName: suite))
        let store = ClipboardStore(board: board, archiveURL: archive, preferences: preferences)

        defer {
            store.flush()
            board.releaseGlobally()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        try await run(store, board, archive, preferences)
    }
}
