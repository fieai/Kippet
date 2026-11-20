import AppKit
import SQLite3
import Testing
import UniformTypeIdentifiers
@testable import Kippet

@MainActor
struct HistoryStorageTests {
    @Test func oldSQLiteImagePastesWithOriginalBytes() async throws {
        let png = try imageBytes()
        let image = ClipImage(data: png, format: UTType.png.identifier)
        let original = Clip(id: UUID(), payload: image.payload, date: .now)
        let file = Clip(
            id: UUID(), payload: .files([URL(fileURLWithPath: "/missing.png")]),
            date: .now, imageSnapshot: image
        )
        try await withArchive { archive, databaseURL in
            try createOldLibrary([original, file], at: databaseURL)
            // Read-only consumers can open v1 rows before the app upgrades them.
            let old = try archive.load(readOnly: true, materializingImages: false).clips
            #expect(old.first?.storedPayload == image.payload)
            #expect(old.last?.imageSnapshot == image)

            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let store = ClipboardStore(board: board, archive: archive)
            let loaded = try #require(store.clips.first)
            let loadedFile = try #require(store.clips.last)
            #expect(loaded.id == original.id)
            #expect(await store.pastePayload(for: loaded) == image.payload)
            #expect(await store.pastePayload(for: loadedFile) == image.payload)
            #expect(await store.pastePayload(for: loadedFile, asFile: true) == file.storedPayload)
            if board.setString("可写", forType: .string) {
                let result = await store.copy(loaded)
                #expect(result == .written(board.changeCount))
                #expect(board.data(forType: .png) == png)
            }
        }
    }

    @Test func originalsAreReleasedAfterCommitAndLazyAfterReload() async throws {
        let png = try imageBytes()
        let image = ClipImage(data: png, format: UTType.png.identifier)
        try await withArchive { archive, _ in
            let store = ClipboardStore(board: nil, archive: archive)
            let original = Clip(id: UUID(), payload: image.payload, date: .now)
            let urls = [URL(fileURLWithPath: "/missing.png")]
            let file = Clip(id: UUID(), payload: .files(urls), date: .now, imageSnapshot: image)
            #expect(store.recordCapture(original))
            #expect(store.recordCapture(file))
            store.flush()
            let current = try #require(store.clips.first { $0.id == original.id })
            #expect(current.storedPayload.size == 0)
            #expect(current.blobSource?.staged(.image) == nil)

            let reloaded = ClipboardStore(board: nil, archive: archive)
            let loaded = try #require(reloaded.clips.first { $0.id == original.id })
            let loadedFile = try #require(reloaded.clips.first { $0.id == file.id })
            #expect(loaded.storedPayload == .image(Data(), format: image.format))
            #expect(loaded.imageBlob?.byteCount == png.count)
            #expect(loaded.imageBlob?.width == 1)
            #expect(loaded.imageBlob?.height == 1)
            #expect(loaded.size == original.size)
            #expect(loadedFile.imageSnapshot == nil)
            #expect(loadedFile.snapshotBlob?.byteCount == png.count)
            #expect(loadedFile.size == file.size)
            #expect(try loaded.readPreviewImage()?.data == png)
            #expect(try loadedFile.readImageSnapshot()?.data == png)

            if let type = UTType(image.format), type.conforms(to: .image) {
                let drag = try #require(ShelfDrag.writers(for: loaded).first as? NSFilePromiseProvider)
                #expect(drag.pasteboardPropertyList(forType: .png) as? Data == png)
            }
            let stack = PasteStack()
            #expect(stack.append([loaded, loadedFile]))
            reloaded.clearHistory()
            reloaded.flush()
            #expect((try? loaded.readPreviewImage()) == nil)
            #expect(try stack.next?.clip.readPreviewImage()?.data == png)
        }
    }

    @Test func syncAndMCPReadPersistedImageContent() async throws {
        let image = ClipImage(data: try imageBytes(), format: UTType.png.identifier)
        try await withArchive { archive, _ in
            let clip = Clip(id: UUID(), payload: image.payload, date: .now, isFavorite: true)
            try archive.write(upserting: [clip], removing: [])
            let store = ClipboardStore(board: nil, archive: archive)
            let saved = try #require(store.clips.first)
            #expect(saved.storedPayload.size == 0)
            #expect(saved == clip)
            var blobs: [SyncBlob: Data] = [:]
            let records = try store.syncLibrary().records(blobs: &blobs)
            #expect(records.clips.first?.payload == .image(.init(blob: SyncBlob(image.data), format: image.format)))
            #expect(blobs[SyncBlob(image.data)] == image.data)

            let server = MCPServer(
                version: "test", access: { .init(enabled: true) },
                loadHistory: { try archive.load(readOnly: true, materializingImages: false) },
                sendSnippet: { _ in false }
            )
            let request = """
                {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_clip","arguments":{"id":"\(clip.id)"}}}
                """
            let reply = try #require(server.handle(request).first)
            let envelope = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            let result = try #require(envelope["result"] as? [String: Any])
            let content = try #require(result["content"] as? [[String: Any]])
            let text = try #require(content.first?["text"] as? String)
            let detail = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(detail["image_size"] as? [String: Int] == ["width": 1, "height": 1, "bytes": image.data.count])
        }
    }

    @Test func deletingImageRemovesBlobAndUndoRestoresIt() async throws {
        let image = ClipImage(data: try imageBytes(), format: UTType.png.identifier)
        try await withArchive { archive, databaseURL in
            let original = Clip(id: UUID(), payload: image.payload, date: .now)
            try archive.write(upserting: [original], removing: [])
            let store = ClipboardStore(board: nil, archive: archive)
            #expect(try blobCount(at: databaseURL) == 1)
            let deleted = try #require(store.remove(original.id))
            store.flush()
            #expect(try blobCount(at: databaseURL) == 0)
            #expect(store.restore(deleted))
            store.flush()
            #expect(try blobCount(at: databaseURL) == 1)
            let reloaded = try #require(try archive.loadLibrary().clips.first)
            #expect(try reloaded.readPreviewImage() == image)
        }
    }

    @Test func failedImageMigrationLeavesLegacyBytesReadable() async throws {
        let image = ClipImage(data: try imageBytes(), format: UTType.png.identifier)
        let original = Clip(id: UUID(), payload: image.payload, date: .now)
        try await withArchive { archive, databaseURL in
            try createOldLibrary([original], at: databaseURL)
            let trigger = """
                CREATE TRIGGER deny_migration BEFORE UPDATE ON clips
                BEGIN SELECT RAISE(ABORT, 'fixture'); END
                """
            try withDatabase(databaseURL) { db in
                try #require(sqlite3_exec(db, trigger, nil, nil, nil) == SQLITE_OK)
            }
            let inline = try #require(try archive.loadLibrary().clips.first)
            #expect(inline.storedPayload == image.payload)
            #expect(inline.imageBlob == nil)
            let new = Clip(id: UUID(), payload: .link("https://example.com"), date: .now)
            try archive.write(upserting: [new], removing: [])
            #expect(try archive.loadLibrary().clips.map(\.id) == [new.id, original.id])
            try withDatabase(databaseURL) { db in
                try #require(sqlite3_exec(db, "DROP TRIGGER deny_migration", nil, nil, nil) == SQLITE_OK)
            }
            let migrated = try #require(try archive.loadLibrary().clips.last)
            #expect(migrated.imageBlob != nil)
            #expect(try migrated.readPreviewImage() == image)
        }
    }

    @Test func repeatedCaptureReusesCardAndBackfillsLegacyHash() async throws {
        let image = ClipImage(data: try imageBytes(), format: UTType.png.identifier)
        try await withArchive { archive, databaseURL in
            let original = Clip(id: UUID(), payload: image.payload, date: .distantPast)
            try createOldLibrary([original], at: databaseURL)
            let store = ClipboardStore(board: nil, archive: archive)
            #expect(store.clips.first?.contentHash == nil)

            let duplicate = Clip(id: UUID(), payload: image.payload, date: .now, sourceName: "测试")
            #expect(store.recordCapture(duplicate))
            #expect(store.recordCapture(duplicate))
            #expect(store.clips.map(\.id) == [original.id])
            #expect(store.clips.first?.contentHash?.count == 64)
            store.flush()
            let loaded = try #require(try archive.loadLibrary().clips.first)
            #expect(loaded.contentHash == store.clips.first?.contentHash)
            #expect(try loaded.readPayload() == image.payload)

            let new = Clip(id: UUID(), payload: .text("新卡片", rtf: nil, html: nil), date: .now)
            #expect(store.recordCapture(new))
            #expect(store.recordCapture(Clip(id: UUID(), payload: new.payload, date: .now)))
            #expect(store.clips.map(\.id) == [new.id, original.id])
            store.flush()
        }
    }

    @Test func hashRespectsCanonicalTextEqualityAndChecksEqualDigest() {
        func clip(_ text: String, rtf: Data? = nil) -> Clip {
            var result = Clip(id: UUID(), payload: .text(text, rtf: rtf, html: nil), date: .now)
            result.contentHash = result.computeContentHash()
            return result
        }
        let canonical = clip("caf\u{e9}")
        let decomposed = clip("cafe\u{301}")
        #expect(canonical.contentHash == decomposed.contentHash)
        #expect(canonical.matchesCapture(decomposed))
        #expect(canonical.contentHash != clip("caf\u{e9}", rtf: Data()).contentHash)
        var collision = clip("other")
        collision.contentHash = canonical.contentHash
        #expect(!canonical.matchesCapture(collision))
    }

    @Test func ftsBackfillAndUpdatesMatchMemoryScanInHistoryOrder() async throws {
        try await withArchive { archive, databaseURL in
            let groupID = UUID()
            let title = Clip(id: UUID(), payload: .link("placeholder"), date: .now, groupIDs: [groupID],
                             title: "Search Needle")
            let plain = Clip(id: UUID(), payload: .text("Search Needle 搜索片段", rtf: nil, html: nil), date: .now,
                             groupIDs: [groupID])
            let ocr = Clip(id: UUID(), payload: .image(Data([42]), format: "public.png"), date: .now,
                           recognizedText: "OCR文本命中")
            let barcode = Clip(id: UUID(), payload: .image(Data([7]), format: "public.png"), date: .now,
                               barcodePayloads: ["scan barcode", "条码文本"])
            let source = Clip(id: UUID(), payload: .link("placeholder"), date: .now,
                              sourceBundleIdentifier: "Source Match")
            let unicode = Clip(id: UUID(), payload: .text("Cafe\u{301} ＡＢＣ Straße", rtf: nil, html: nil), date: .now)
            let quoted = Clip(id: UUID(), payload: .text("an \"AND\"", rtf: nil, html: nil), date: .now)
            let fillers = (0...HistorySearchIndex.minimumHistoryCount).map { number in
                Clip(id: UUID(), payload: .text("记录 filler \(number)", rtf: nil, html: nil), date: .distantPast)
            }
            try createOldLibrary([title, plain, ocr, barcode, source, unicode, quoted] + fillers, at: databaseURL)
            let store = ClipboardStore(board: nil, archive: archive)
            let group = ClipGroup(id: groupID, name: "收藏", cardOrder: [plain.id, title.id])
            store.groups = [group]

            @MainActor func check(_ query: String, group: ClipGroup? = nil, kind: ClipKind? = nil) {
                let filter = HistoryFilter(
                    search: query, contentType: kind.map(HistoryContentType.kind), favoritesOnly: false,
                    sourceName: nil, groupID: group?.id, sourceBundleIdentifier: nil, locale: .current
                )
                let expected = store.clips.filter(filter.includes)
                let actual = store.filtered(query: query, kind: kind, favoritesOnly: false, groupID: group?.id)
                #expect(actual.map(\.id) == (group?.ordered(expected) ?? expected).map(\.id))
            }

            @MainActor func candidates(_ query: String) -> Set<UUID>? {
                store.searchToken.flatMap { archive.searchCandidates(for: query, historyCount: store.clips.count, token: $0) }
            }

            if HistorySearchIndex.isAvailable {
                let english = try #require(candidates("search needle"))
                #expect(english.isSuperset(of: [title.id, plain.id]))
                #expect(english.count < 10)
                let chinese = try #require(candidates("搜索片段"))
                #expect(chinese.contains(plain.id))
                #expect(chinese.count < 10)
                #expect(candidates("文本命")?.contains(ocr.id) == true)
                #expect(candidates("scan barcode")?.contains(barcode.id) == true)
                #expect(candidates("source match")?.contains(source.id) == true)
                #expect(candidates("cafe")?.contains(unicode.id) == true)
            }
            #expect(candidates("搜") == nil)
            #expect(candidates("搜索") == nil)
            for query in [
                "search needle", "SEARCH", "搜索片段", "文本命", "scan barcode", "条码文本", "source match",
                "cafe", "abc", "strasse", "\"AND\"", "未命中", "搜", "搜索",
            ] {
                check(query)
            }
            check("search needle", group: group)
            check("文本命", kind: .image)
            check("文本命", kind: .text)

            #expect(store.rename(title.id, title: "updated title"))
            _ = store.remove(plain.id)
            // The live snapshot already includes changes still on the writer queue.
            check("updated title")
            check("search needle")
            store.flush()
            if HistorySearchIndex.isAvailable {
                #expect(candidates("search needle")?.contains(title.id) == false)
                #expect(candidates("search needle")?.contains(plain.id) == false)
                #expect(candidates("updated title")?.contains(title.id) == true)
            }
            check("updated Title")
            check("SEARCH NEEDLE")
        }
    }

    private func imageBytes() throws -> Data {
        try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII="))
    }

    private func withArchive(_ body: @MainActor (ClipArchive, URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "HistoryStorageTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(ClipArchive(legacyURL: folder.appending(path: "History.plist")),
                       folder.appending(path: "History.sqlite3"))
    }

    private func withDatabase<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let status = sqlite3_open(url.path, &handle)
        defer { if let handle { sqlite3_close(handle) } }
        try #require(status == SQLITE_OK)
        return try body(#require(handle))
    }

    private func createOldLibrary(_ clips: [Clip], at url: URL) throws {
        try withDatabase(url) { db in
            let schema = """
                PRAGMA user_version = 1;
                CREATE TABLE clips (
                    position INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, date REAL NOT NULL, content BLOB NOT NULL
                );
                CREATE TABLE metadata (key TEXT NOT NULL PRIMARY KEY, content BLOB NOT NULL);
                """
            try #require(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
            try #require(sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK)
            var handle: OpaquePointer?
            let status = sqlite3_prepare_v2(db, "INSERT INTO clips (id, date, content) VALUES (?, ?, ?)", -1, &handle, nil)
            defer { sqlite3_finalize(handle) }
            try #require(status == SQLITE_OK)
            let statement = try #require(handle)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            for clip in clips.reversed() {
                let bytes = try encoder.encode(clip)
                try #require(sqlite3_bind_text(statement, 1, clip.id.uuidString, -1, Database.transient) == SQLITE_OK)
                try #require(sqlite3_bind_double(statement, 2, clip.date.timeIntervalSinceReferenceDate) == SQLITE_OK)
                let bound = bytes.withUnsafeBytes {
                    sqlite3_bind_blob64(statement, 3, $0.baseAddress, UInt64($0.count), Database.transient)
                }
                try #require(bound == SQLITE_OK)
                try #require(sqlite3_step(statement) == SQLITE_DONE)
                try #require(sqlite3_reset(statement) == SQLITE_OK)
            }
            try #require(sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK)
        }
    }

    private func blobCount(at url: URL) throws -> Int {
        try withDatabase(url) { db in
            var statement: OpaquePointer?
            let status = sqlite3_prepare_v2(db, "SELECT count(*) FROM clip_blobs", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            try #require(status == SQLITE_OK)
            try #require(sqlite3_step(statement) == SQLITE_ROW)
            return Int(sqlite3_column_int(statement, 0))
        }
    }
}
