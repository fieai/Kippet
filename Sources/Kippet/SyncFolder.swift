import Foundation

struct SyncFolder: Sendable {
    let selected: URL
    let deviceID: UUID

    private var devices: URL {
        root.appending(path: "devices", directoryHint: .isDirectory)
    }

    private var root: URL { selected.appending(path: LegacyMigration.syncFolderName, directoryHint: .isDirectory) }

    private var own: URL { devices.appending(path: deviceID.uuidString, directoryHint: .isDirectory) }

    struct ReadResult: Sendable {
        let records: SyncRecords
        let blobs: [SyncBlob: Data]
        let peers: [SyncState.Device]
        let watchDirectories: [URL]
    }

    func read(local: SyncLibrary, device: SyncState.Device) throws -> ReadResult {
        let manager = FileManager.default
        try checkSelectedFolder()
        try manager.createDirectory(at: devices, withIntermediateDirectories: true)
        let entries = try manager.contentsOfDirectory(
            at: devices, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        let peerFolders = entries.filter {
            guard let id = UUID(uuidString: $0.lastPathComponent), id != deviceID,
                  (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return false }
            return true
        }
        let states = peerFolders.compactMap { folder -> SyncState? in
            guard let data = Self.readAvailable(folder.appending(path: "state.json")),
                  let state = try? SyncState.decode(data),
                  state.device.id == UUID(uuidString: folder.lastPathComponent) else { return nil }
            return state
        }
        var blobs: [SyncBlob: Data] = [:]
        let ownState = try SyncState(device: device, records: local.records(blobs: &blobs))
        let merged = SyncMerge.merge(states + [ownState], now: device.updatedAt, privateIDs: local.privateIDs)
        let references = Set(merged.clips.flatMap(\.payload.blobs))
        let blobFolders = ([own] + peerFolders).map { $0.appending(path: "blobs", directoryHint: .isDirectory) }
        for blob in references where blobs[blob] == nil {
            for folder in blobFolders {
                guard let data = Self.readAvailable(folder.appending(path: blob.hash)),
                      SyncBlob(data) == blob else { continue }
                blobs[blob] = data
                break
            }
        }
        return ReadResult(
            records: merged, blobs: blobs, peers: states.map(\.device),
            watchDirectories: [selected, devices] + peerFolders + Array(blobFolders.dropFirst())
        )
    }

    func write(_ records: SyncRecords, blobs: [SyncBlob: Data], device: SyncState.Device, force: Bool = false) throws {
        let manager = FileManager.default
        try checkSelectedFolder()
        let blobFolder = own.appending(path: "blobs", directoryHint: .isDirectory)
        try manager.createDirectory(at: blobFolder, withIntermediateDirectories: true)
        let references = Set(records.clips.flatMap(\.payload.blobs))
        var available: Set<SyncBlob> = []
        for blob in references {
            let url = blobFolder.appending(path: blob.hash)
            if let data = Self.readAvailable(url), SyncBlob(data) == blob {
                available.insert(blob)
            } else if let data = blobs[blob] {
                try data.write(to: url, options: .atomic)
                available.insert(blob)
            }
        }

        var ready = records
        // A partial card stays in the local archive and in its source manifest until its blobs arrive.
        ready.clips.removeAll { !available.isSuperset(of: $0.payload.blobs) }
        let url = own.appending(path: "state.json")
        if !force, let old = Self.readAvailable(url).flatMap({ try? SyncState.decode($0) }),
           old.device.id == device.id, old.device.name == device.name, old.records == ready { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(SyncState(device: device, records: ready)).write(to: url, options: .atomic)
    }

    private func checkSelectedFolder() throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw CocoaError(.fileNoSuchFile, userInfo: [NSURLErrorKey: selected]) }
        LegacyMigration.adoptLegacySyncFolder(in: selected)
    }

    private static func readAvailable(_ url: URL) -> Data? {
        let manager = FileManager.default
        if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .notDownloaded {
            try? manager.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        if manager.fileExists(atPath: placeholder.path) {
            do {
                try manager.startDownloadingUbiquitousItem(at: url)
            } catch {
                try? manager.startDownloadingUbiquitousItem(at: placeholder)
            }
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
