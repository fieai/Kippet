import Foundation
import SQLite3
import Testing
@testable import Kippet

struct ClipArchiveTests {
    @Test func readOnlyLoadDoesNotCreateOrMigrateAnArchive() throws {
        try withArchive { archive, legacyURL in
            let legacy = Clip(id: UUID(), payload: .link("https://example.com"), date: .now)
            try PropertyListEncoder().encode([legacy]).write(to: legacyURL)
            let databaseURL = legacyURL.deletingPathExtension().appendingPathExtension("sqlite3")
            #expect(try archive.load(readOnly: true).clips.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
            #expect(try archive.load().clips.map(\.id) == [legacy.id])
            let contents = try Data(contentsOf: databaseURL)
            #expect(try archive.load(readOnly: true).clips.map(\.id) == [legacy.id])
            #expect(try Data(contentsOf: databaseURL) == contents)
        }
    }

    @Test func readOnlyLoadReflectsCommittedWALChanges() throws {
        try withArchive { archive, legacyURL in
            _ = try archive.load()
            let databaseURL = legacyURL.deletingPathExtension().appendingPathExtension("sqlite3")
            var writer: OpaquePointer?
            let openResult = sqlite3_open(databaseURL.path, &writer)
            defer { if let writer { sqlite3_close(writer) } }
            try #require(openResult == SQLITE_OK)
            try #require(sqlite3_exec(writer, "PRAGMA journal_mode = WAL", nil, nil, nil) == SQLITE_OK)

            let clip = Clip(id: UUID(), payload: .link("https://example.com/new"), date: .now)
            try archive.write(upserting: [clip], removing: [])
            #expect(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
            #expect(try archive.load(readOnly: true).clips.map(\.id) == [clip.id])
            try archive.write(upserting: [], removing: [clip.id])
            #expect(try archive.load(readOnly: true).clips.isEmpty)
        }
    }

    @Test func optionalExpiryRoundTripsAlongsideRowsWithoutExpiry() throws {
        try withArchive { archive, _ in
            let original = Clip(id: UUID(), payload: .link("https://example.com"), date: .now)
            let deadline = Date(timeIntervalSinceReferenceDate: 10_000)
            let expiring = Clip(id: UUID(), payload: .text("482913", rtf: nil, html: nil),
                                date: deadline.addingTimeInterval(-120), expiresAt: deadline)
            try archive.write(upserting: [original, expiring], removing: [])
            #expect(try archive.load().clips.map(\.expiresAt) == [nil, deadline])
        }
    }

    @Test func barcodePayloadsRoundTripAndOldRowsStillDecode() throws {
        try withArchive { archive, _ in
            let image = ClipPayload.image(Data([0, 1, 2]), format: "public.png")
            let legacy = Clip(id: UUID(), payload: image, date: .now, recognizedText: "Existing OCR")
            let scanned = Clip(id: UUID(), payload: image, date: .now, barcodePayloads: [])
            let qr = Clip(id: UUID(), payload: image, date: .now, barcodePayloads: ["https://example.com", "label"])
            try archive.write(upserting: [qr, scanned, legacy], removing: [])

            let clips = try archive.load().clips
            #expect(clips.map(\.barcodePayloads) == [["https://example.com", "label"], [], nil])
            #expect(clips.last?.recognizedText == "Existing OCR")
        }
    }

    @Test func migrationPreservesLegacyOrderAndDoesNotImportAgainAfterClearing() throws {
        try withArchive { archive, legacyURL in
            let date = Date(timeIntervalSinceReferenceDate: 100)
            let bytes = Data([0, 2, 255, 7])
            let image = Clip(id: UUID(), payload: .image(bytes, format: "public.png"), date: date, isFavorite: true)
            let file = Clip(id: UUID(), payload: .files([URL(fileURLWithPath: "/tmp/clip.jpg")]), date: date,
                            sourceName: "Fixture", imageSnapshot: ClipImage(data: bytes, format: "public.png"))
            let legacyBytes = try PropertyListEncoder().encode([image, file])
            try legacyBytes.write(to: legacyURL)

            let migrated = try archive.load()
            #expect(migrated.clips.map(\.id) == [image.id, file.id])
            #expect(migrated.clips.first?.isFavorite == true)
            #expect(migrated.clips.first?.payload == .image(bytes, format: "public.png"))
            #expect(migrated.clips.last?.imageSnapshot?.data == bytes)
            #expect(migrated.clips.last?.sourceName == "Fixture")
            #expect(migrated.groups.isEmpty)

            try archive.write(upserting: [], removing: [image.id, file.id])
            #expect(try archive.load().clips.isEmpty)
            #expect(try Data(contentsOf: legacyURL) == legacyBytes)
        }
    }

    @Test func writesOnlyChangedClipsAndKeepsGroupsAndVisibleOrder() throws {
        try withArchive { archive, _ in
            let date = Date(timeIntervalSinceReferenceDate: 100)
            let first = Clip(id: UUID(), payload: .link("https://example.com"), date: date)
            var second = Clip(id: UUID(), payload: .text("example", rtf: nil, html: nil), date: date)
            try archive.write(upserting: [first, second], removing: [])
            #expect(try archive.load().clips.map(\.id) == [first.id, second.id])

            var group = ClipGroup(id: UUID(), name: "保存的链接")
            second.groupIDs = [group.id]
            try archive.write(upserting: [second], removing: [], groups: [group])
            let saved = try archive.load()
            #expect(saved.clips.map(\.id) == [first.id, second.id])
            #expect(saved.clips.last?.groupIDs == [group.id])
            #expect(saved.clips.first?.payload == first.payload)
            #expect(saved.groups == [group])

            second.date = date.addingTimeInterval(1)
            try archive.write(upserting: [second], removing: [])
            #expect(try archive.load().clips.map(\.id) == [second.id, first.id])
            #expect(try archive.load().groups == [group])

            group.name = "新名称"
            try archive.write(upserting: [], removing: [first.id], groups: [group])
            let updated = try archive.load()
            #expect(updated.clips.map(\.id) == [second.id])
            #expect(updated.groups == [group])
        }
    }

    @Test func invalidLegacyArchiveCanBeRetriedAfterRestoration() throws {
        try withArchive { archive, legacyURL in
            let invalid = Data([0, 42, 0])
            try invalid.write(to: legacyURL)
            #expect(throws: (any Error).self) { try archive.load() }
            #expect(try Data(contentsOf: legacyURL) == invalid)

            let clip = Clip(id: UUID(), payload: .link("https://example.com"), date: .now)
            try PropertyListEncoder().encode([clip]).write(to: legacyURL)
            #expect(try archive.load().clips.map(\.id) == [clip.id])
        }
    }

    private func withArchive(_ body: (ClipArchive, URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ClipArchiveTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacyURL = folder.appending(path: "History.plist")
        try body(ClipArchive(legacyURL: legacyURL), legacyURL)
    }
}
