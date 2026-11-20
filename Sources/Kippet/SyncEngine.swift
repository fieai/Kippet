import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class SyncEngine {
    enum Status: Equatable {
        case idle, syncing, synced(Date), error(String)
    }

    private(set) var folder: URL?
    private(set) var isEnabled = false
    private(set) var status: Status = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var otherDevices: [SyncState.Device] = []

    let deviceID: UUID
    private let deviceName: String
    private let defaults: UserDefaults
    private let store: ClipboardStore
    private let queue = DispatchQueue(label: "Kippet.sync", qos: .utility)
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var watch: [any DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var needsRead = false
    @ObservationIgnored private var hasScopedAccess = false

    private static let bookmarkKey = "syncFolderBookmark"
    private static let deviceKey = "syncDeviceID"

    init(store: ClipboardStore, defaults: UserDefaults = .standard, deviceName: String? = Host.current().localizedName) {
        self.store = store
        self.defaults = defaults
        self.deviceName = deviceName ?? ProcessInfo.processInfo.hostName
        deviceID = defaults.string(forKey: Self.deviceKey).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(deviceID.uuidString, forKey: Self.deviceKey)
        store.onSavedStateChange = { [weak self] in self?.scheduleSave() }
    }

    func start() {
        guard folder == nil, let data = defaults.data(forKey: Self.bookmarkKey) else { return }
        isEnabled = true
        do {
            var stale = false
            let url = try Self.resolve(data, stale: &stale)
            connect(url)
            if stale { defaults.set(try Self.bookmark(for: url), forKey: Self.bookmarkKey) }
        } catch {
            status = .error(L("无法打开同步文件夹。%@", error.localizedDescription))
        }
    }

    func selectFolder(_ url: URL) {
        do {
            let data = try Self.bookmark(for: url)
            disconnect()
            defaults.set(data, forKey: Self.bookmarkKey)
            connect(url)
        } catch {
            status = .error(L("无法保存同步文件夹。%@", error.localizedDescription))
        }
    }

    func stop() {
        disconnect()
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    func requestSync() {
        guard folder != nil else { return }
        if running != nil {
            needsRead = true
        } else if debounce == nil {
            beginSync()
        }
    }

    func syncNow() async {
        if folder == nil, isEnabled { start() }
        debounce?.cancel()
        debounce = nil
        if running != nil { needsRead = true } else { beginSync() }
        while let running { await running.value }
    }

    func flush() {
        guard let folder, store.canReadSyncLibrary else { return }
        cancelWork()
        let selected = movedFolder(from: folder) ?? folder
        let accessedMovedFolder = selected != folder && selected.startAccessingSecurityScopedResource()
        defer {
            if accessedMovedFolder { selected.stopAccessingSecurityScopedResource() }
            if hasScopedAccess { folder.stopAccessingSecurityScopedResource() }
            hasScopedAccess = false
        }
        let destination = SyncFolder(selected: selected, deviceID: deviceID)
        let library = store.syncLibrary()
        let device = device()
        do {
            try queue.sync {
                var blobs: [SyncBlob: Data] = [:]
                let local = try SyncState(device: device, records: library.records(blobs: &blobs))
                let records = SyncMerge.merge([local], now: device.updatedAt, privateIDs: library.privateIDs)
                try destination.write(records, blobs: blobs, device: device, force: true)
            }
        } catch {
            status = .error(L("同步失败。%@", error.localizedDescription))
        }
    }

    private func connect(_ url: URL) {
        folder = url
        isEnabled = true
        hasScopedAccess = url.startAccessingSecurityScopedResource()
        requestSync()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                self.requestSync()
            }
        }
    }

    private func disconnect() {
        cancelWork()
        // Finish a write already dispatched before giving up the folder's access.
        queue.sync {}
        if hasScopedAccess { folder?.stopAccessingSecurityScopedResource() }
        hasScopedAccess = false
        folder = nil
        isEnabled = false
        status = .idle
        lastSyncedAt = nil
        otherDevices = []
    }

    private func cancelWork() {
        generation = UUID()
        debounce?.cancel()
        debounce = nil
        poll?.cancel()
        poll = nil
        running?.cancel()
        running = nil
        needsRead = false
        watch.forEach { $0.cancel() }
        watch.removeAll()
    }

    private func scheduleSave() {
        guard folder != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.debounce = nil
            self.requestSync()
        }
    }

    private func device() -> SyncState.Device {
        .init(id: deviceID, name: deviceName, updatedAt: .now)
    }

    private func beginSync() {
        guard let folder else { return }
        guard store.canReadSyncLibrary else {
            status = .error(L("无法读取本机收藏，暂时无法同步。"))
            return
        }

        status = .syncing
        needsRead = false
        let generation = self.generation
        let destination = SyncFolder(selected: folder, deviceID: deviceID)
        let library = store.syncLibrary()
        let revision = store.syncRevision
        let device = device()
        running = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await runIO { try destination.read(local: library, device: device) }
                guard self.generation == generation else { return }
                installWatch(result.watchDirectories)
                var devices = Dictionary(uniqueKeysWithValues: otherDevices.map { ($0.id, $0) })
                for peer in result.peers where devices[peer.id].map({ $0.updatedAt > peer.updatedAt }) != true {
                    devices[peer.id] = peer
                }
                otherDevices = devices.values.sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
                if store.syncRevision == revision {
                    store.applySync(result.records, blobs: result.blobs)
                    try await runIO {
                        try destination.write(result.records, blobs: result.blobs, device: device)
                    }
                    guard self.generation == generation else { return }
                    let date = Date.now
                    status = .synced(date)
                    lastSyncedAt = date
                } else if debounce == nil {
                    needsRead = true
                }
            } catch {
                guard self.generation == generation else { return }
                if (error as? CocoaError)?.code == .fileNoSuchFile, let moved = movedFolder(from: folder) {
                    disconnect()
                    connect(moved)
                    return
                }
                status = .error(L("同步失败。%@", error.localizedDescription))
            }
            running = nil
            if needsRead, debounce == nil { beginSync() }
            if running == nil, status == .syncing { status = lastSyncedAt.map(Status.synced) ?? .idle }
        }
    }

    private func runIO<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }

    private func installWatch(_ directories: [URL]) {
        watch.forEach { $0.cancel() }
        let generation = self.generation
        watch = directories.compactMap { url in
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete, .attrib, .revoke], queue: queue
            )
            source.setEventHandler { @Sendable [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.requestSync()
                }
            }
            source.setCancelHandler { @Sendable in close(descriptor) }
            source.resume()
            return source
        }
    }

    private static func bookmark(for url: URL) throws -> Data {
        if let scoped = try? url.bookmarkData(options: .withSecurityScope) { return scoped }
        // An unsigned, unsandboxed SwiftPM binary can still resolve a regular file bookmark.
        return try url.bookmarkData()
    }

    private func movedFolder(from previous: URL) -> URL? {
        guard !FileManager.default.fileExists(atPath: previous.path),
              let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
        var stale = false
        guard let moved = try? Self.resolve(data, stale: &stale), moved.path != previous.path else { return nil }
        if stale, let renewed = try? Self.bookmark(for: moved) { defaults.set(renewed, forKey: Self.bookmarkKey) }
        return moved
    }

    private static func resolve(_ data: Data, stale: inout Bool) throws -> URL {
        if let scoped = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                 bookmarkDataIsStale: &stale) { return scoped }
        return try URL(resolvingBookmarkData: data, options: .withoutUI, bookmarkDataIsStale: &stale)
    }
}
