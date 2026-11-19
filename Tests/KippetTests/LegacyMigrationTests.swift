import Foundation
import Testing
@testable import Kippet

struct LegacyMigrationTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "KippetMigration-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func movesLegacyDataFolderOnlyWhenNewOneIsMissing() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appending(path: "ClipShelf")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: legacy.appending(path: "History.sqlite3"))

        #expect(LegacyMigration.dataFolder(in: base).lastPathComponent == "ClipShelf")
        #expect(LegacyMigration.moveDataFolder(in: base))
        #expect(LegacyMigration.dataFolder(in: base).lastPathComponent == "Kippet")
        #expect(try Data(contentsOf: base.appending(path: "Kippet/History.sqlite3")) == Data("db".utf8))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))

        // A legacy folder that reappears next to existing data is left alone.
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        #expect(!LegacyMigration.moveDataFolder(in: base))
        #expect(LegacyMigration.dataFolder(in: base).lastPathComponent == "Kippet")
    }

    @Test func freshInstallUsesNewFolder() throws {
        let base = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(!LegacyMigration.moveDataFolder(in: base))
        #expect(LegacyMigration.dataFolder(in: base).lastPathComponent == "Kippet")
    }

    @Test func adoptsLegacySyncFolderOnce() throws {
        let selected = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: selected) }
        try FileManager.default.createDirectory(at: selected.appending(path: "ClipShelf Sync/devices"), withIntermediateDirectories: true)

        #expect(LegacyMigration.adoptLegacySyncFolder(in: selected))
        #expect(FileManager.default.fileExists(atPath: selected.appending(path: "Kippet Sync/devices").path))
        #expect(!LegacyMigration.adoptLegacySyncFolder(in: selected))
    }

    @Test func copiesMissingPreferencesOnce() throws {
        let suite = "KippetMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5, forKey: "historyLimit")

        let copied = LegacyMigration.migrateDefaults(
            from: ["historyLimit": 99, "syncDeviceID": "A784", "copySound": true], into: defaults
        )
        #expect(copied == 2)
        #expect(defaults.integer(forKey: "historyLimit") == 5)
        #expect(defaults.string(forKey: "syncDeviceID") == "A784")
        #expect(defaults.bool(forKey: "copySound"))

        #expect(LegacyMigration.migrateDefaults(from: ["retentionDays": 30], into: defaults) == 0)
        #expect(defaults.object(forKey: "retentionDays") == nil)
    }
}
