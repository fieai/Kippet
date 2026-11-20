import AppKit

@main
struct KippetApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPStdio.run()
            return
        }
        migrateLegacyIdentity()
        let app = NSApplication.shared
        let delegate = ShelfDelegate()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    /// Takes over history and preferences from the ClipShelf build, but never while that build is still writing them.
    private static func migrateLegacyIdentity() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: LegacyMigration.legacyBundleID).isEmpty
        else { return }
        LegacyMigration.moveDataFolder(in: URL.applicationSupportDirectory)
        LegacyMigration.migrateDefaults(
            from: UserDefaults.standard.persistentDomain(forName: LegacyMigration.legacyBundleID),
            into: .standard
        )
    }
}
