import Foundation

/// One-time hand-over from the app's earlier ClipShelf identity: data folder, preferences and sync folder.
enum LegacyMigration {
    static let legacyBundleID = "com.clipshelf.macos"
    static let urlScheme = "clipshelf"
    static let folderName = "Kippet"
    static let legacyFolderName = "ClipShelf"
    static let syncFolderName = "Kippet Sync"
    static let legacySyncFolderName = "ClipShelf Sync"
    static let defaultsMigratedKey = "migratedLegacyDefaults"

    /// The folder that currently holds history: the new one, or the legacy one until it has been moved.
    static func dataFolder(in base: URL, fileManager: FileManager = .default) -> URL {
        let current = base.appending(path: folderName, directoryHint: .isDirectory)
        let legacy = base.appending(path: legacyFolderName, directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: legacy.path) { return legacy }
        return current
    }

    /// Moves the legacy data folder into place when the new one doesn't exist yet. Never merges or overwrites.
    @discardableResult
    static func moveDataFolder(in base: URL, fileManager: FileManager = .default) -> Bool {
        move(base.appending(path: legacyFolderName), to: base.appending(path: folderName), fileManager: fileManager)
    }

    /// Renames the shared sync folder once; other Macs follow because they look for the new name first.
    @discardableResult
    static func adoptLegacySyncFolder(in selected: URL, fileManager: FileManager = .default) -> Bool {
        move(selected.appending(path: legacySyncFolderName), to: selected.appending(path: syncFolderName), fileManager: fileManager)
    }

    /// Copies preferences the new identity doesn't have yet. Runs once; keys already set are kept.
    @discardableResult
    static func migrateDefaults(from legacy: [String: Any]?, into defaults: UserDefaults) -> Int {
        guard !defaults.bool(forKey: defaultsMigratedKey) else { return 0 }
        defer { defaults.set(true, forKey: defaultsMigratedKey) }
        guard let legacy else { return 0 }
        var copied = 0
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    private static func move(_ source: URL, to destination: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) else { return false }
        return (try? fileManager.moveItem(at: source, to: destination)) != nil
    }
}
