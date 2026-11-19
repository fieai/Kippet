import Foundation
import Testing
@testable import ClipShelf

@MainActor
struct SyncEngineTests {
    @Test func devicesExchangeStarsBoardRenamesOrderAndDeletions() async throws {
        let plain = history("this stays local")
        let starred = history("shared star")
        let rightHistory = history("right history")
        let left = try Device(name: "Left", history: [plain, starred])
        defer { left.cleanUp() }
        let right = try Device(name: "Right", history: [rightHistory])
        defer { right.cleanUp() }
        #expect(left.engine.deviceID != right.engine.deviceID)

        let group = try #require(left.store.createGroup(name: "原钉板", color: .teal))
        let otherGroup = try #require(left.store.createGroup(name: "第二个钉板"))
        let first = try #require(left.store.createSnippet(title: "第一张", content: "first snippet", in: group.id))
        let second = try #require(left.store.createSnippet(title: "第二张", content: "second snippet", in: group.id))
        #expect(left.store.toggleFavorite(starred.id))
        #expect(left.store.moveCard(first.id, onto: second.id, in: group.id))
        await left.engine.syncNow()
        try left.deliver(to: right)
        await right.engine.syncNow()

        let leftState = try left.state()
        #expect(leftState.format == 1)
        #expect(Set(leftState.clips.map(\.id)) == [starred.id, first.id, second.id])
        #expect(!String(decoding: try Data(contentsOf: left.stateFile), as: UTF8.self).contains("this stays local"))
        #expect(right.engine.otherDevices.map(\.name) == ["Left"])
        #expect(right.store.clips.first { $0.id == starred.id }?.isFavorite == true)
        #expect(right.store.groups.map(\.id) == [group.id, otherGroup.id])
        #expect(cards(in: group.id, on: right) == [first.id, second.id])

        #expect(right.store.renameGroup(group.id, name: "跨设备钉板", color: .blue))
        right.store.moveGroup(otherGroup.id, onto: group.id)
        #expect(right.store.moveCard(second.id, onto: first.id, in: group.id))
        #expect(right.store.rename(first.id, title: "跨设备备注"))
        #expect(right.store.editText(first.id, text: "updated snippet") != nil)
        await right.engine.syncNow()
        try right.deliver(to: left)
        await left.engine.syncNow()
        #expect(left.store.groups.map(\.id) == [otherGroup.id, group.id])
        #expect(left.store.groups.last?.name == "跨设备钉板")
        #expect(left.store.groups.last?.color == .blue)
        #expect(cards(in: group.id, on: left) == [second.id, first.id])
        #expect(left.store.clips.first { $0.id == first.id }?.title == "跨设备备注")
        #expect(left.store.clips.first { $0.id == first.id }?.payload.previewText == "updated snippet")

        left.store.removeGroup(group.id)
        #expect(left.store.toggleFavorite(starred.id))
        await left.engine.syncNow()
        try left.deliver(to: right)
        await right.engine.syncNow()
        #expect(right.store.groups.map(\.id) == [otherGroup.id])
        #expect(right.store.clips.first { $0.id == first.id }?.isFavorite == true)
        #expect(right.store.clips.first { $0.id == second.id }?.isFavorite == true)
        #expect(!right.store.clips.contains { $0.id == starred.id })
        #expect(right.store.clips.first { $0.id == rightHistory.id } == rightHistory)
        #expect(left.store.clips.first { $0.id == starred.id }?.isSaved == false)
        #expect(try right.state().tombstones.contains { $0.kind == .group && $0.id == group.id })

        right.store.flush()
        let stored = try right.archive.loadLibrary()
        #expect(stored.groups == right.store.groups)
        #expect(stored.tombstones == (try right.state().tombstones))
    }

    @Test func unsaveKeepsAnExistingHistoryCardAndTombstoneSurvivesRestart() async throws {
        let same = history("already in both histories")
        let left = try Device(name: "Left", history: [same])
        defer { left.cleanUp() }
        let right = try Device(name: "Right", history: [same])
        defer { right.cleanUp() }

        #expect(left.store.toggleFavorite(same.id))
        await left.engine.syncNow()
        try left.deliver(to: right)
        await right.engine.syncNow()
        #expect(right.store.clips.first?.isFavorite == true)
        #expect(right.store.clips.first?.syncOnly == nil)

        #expect(left.store.toggleFavorite(same.id))
        // Quit during the debounce window must still publish the pending deletion.
        left.engine.flush()
        left.store.flush()
        let archive = try left.archive.loadLibrary()
        #expect(archive.tombstones.map(\.id) == [same.id])
        let restarted = ClipboardStore(board: nil, archive: left.archive, preferences: left.defaults)
        let engine = SyncEngine(store: restarted, defaults: left.defaults, deviceName: "Left")
        defer { engine.stop() }
        engine.start()
        await engine.syncNow()
        #expect(engine.deviceID == left.engine.deviceID)
        #expect(engine.folder?.resolvingSymlinksInPath() == left.folder.resolvingSymlinksInPath())
        try left.deliver(to: right)
        await right.engine.syncNow()
        #expect(right.store.clips.first?.id == same.id)
        #expect(right.store.clips.first?.isSaved == false)
        #expect(right.store.clips.first?.payload == same.payload)
    }

    @Test func expiringCardNeverEntersStateEvenWhenStarredDuringSyncAndThenUnstarred() async throws {
        var expiring = history("验证码 482913")
        expiring.expiresAt = .now + 120
        let legacySaved = Clip(
            id: UUID(), payload: .text("private legacy", rtf: nil, html: nil), date: .now,
            isFavorite: true, expiresAt: .now + 120
        )
        let device = try Device(name: "Private", history: [expiring, legacySaved])
        defer { device.cleanUp() }
        let regular = try #require(device.store.createSnippet(title: "", content: "regular saved", in: nil))

        #expect(device.store.toggleFavorite(expiring.id))
        #expect(device.store.clips.first { $0.id == expiring.id }?.expiresAt == nil)
        await device.engine.syncNow()
        try expectOnly(regular.id, in: device, excluding: [expiring, legacySaved])

        let group = try #require(device.store.createGroup(name: "测试"))
        #expect(device.store.addCards([regular.id, expiring.id], to: group.id))
        let order = cards(in: group.id, on: device)
        try #require(order.count == 2)
        #expect(device.store.moveCard(order[0], onto: order[1], in: group.id))
        await device.engine.syncNow()
        try expectOnly(regular.id, in: device, excluding: [expiring, legacySaved])
        #expect(cards(in: group.id, on: device) == Array(order.reversed()))

        #expect(device.store.toggleFavorite(expiring.id))
        let sync = Task { await device.engine.syncNow() }
        await Task.yield()
        #expect(device.store.toggleGroup(group.id, for: expiring.id))
        #expect(device.store.toggleFavorite(expiring.id))
        await sync.value
        try expectOnly(regular.id, in: device, excluding: [expiring, legacySaved])
        #expect(device.store.clips.first { $0.id == expiring.id }?.isSaved == false)

        device.store.flush()
        let reopened = ClipboardStore(board: nil, archive: device.archive, preferences: device.defaults)
        #expect(reopened.clips.first { $0.id == expiring.id }?.excludedFromSync == true)
        #expect(reopened.toggleFavorite(expiring.id))
        let engine = SyncEngine(store: reopened, defaults: device.defaults, deviceName: "Private")
        device.engine.flush()
        engine.start()
        await engine.syncNow()
        defer { engine.stop() }
        try expectOnly(regular.id, in: device, excluding: [expiring, legacySaved])

        #expect(reopened.addCards([expiring.id], to: group.id))
        let peer = try Device(name: "Peer")
        defer { peer.cleanUp() }
        try device.deliver(to: peer)
        await peer.engine.syncNow()
        peer.store.removeGroup(group.id)
        await peer.engine.syncNow()
        try peer.deliver(to: device)
        await engine.syncNow()
        let localCard = try #require(reopened.clips.first { $0.id == expiring.id })
        #expect(localCard.groupIDs == nil)
        #expect(localCard.isFavorite)
        try expectOnly(regular.id, in: device, excluding: [expiring, legacySaved])
    }

    @Test func partialDownloadsAndMissingBlobsRecoverOnFolderChange() async throws {
        let bytes = Data("image data".utf8)
        let image = Clip(id: UUID(), payload: .image(bytes, format: "public.png"), date: .now, isFavorite: true)
        let source = try Device(name: "Source", history: [image])
        defer { source.cleanUp() }
        let target = try Device(name: "Target")
        defer { target.cleanUp() }
        await source.engine.syncNow()
        let received = target.peerFolder(source.engine.deviceID)
        try FileManager.default.createDirectory(at: received, withIntermediateDirectories: true)
        let manifest = received.appending(path: "state.json")
        try Data("{\"format\":".utf8).write(to: manifest, options: .atomic)
        await target.engine.syncNow()
        #expect(target.engine.otherDevices.isEmpty)
        #expect(target.store.clips.isEmpty)

        try Data(contentsOf: source.stateFile).write(to: manifest, options: .atomic)
        await target.engine.syncNow()
        let pending = try #require(target.store.clips.first)
        #expect(pending.id == image.id)
        #expect(pending.hasPendingSyncImage)
        #expect(await target.store.copy(pending) == .imagePendingSync)
        #expect(try target.state().clips.isEmpty)
        target.store.flush()
        #expect(try target.archive.load().clips.first?.hasPendingSyncImage == true)

        let blobs = received.appending(path: "blobs")
        try FileManager.default.copyItem(at: source.deviceFolder.appending(path: "blobs"), to: blobs)
        for _ in 0..<60 {
            if target.store.clips.first?.payload == image.payload, target.engine.status != .syncing { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(target.store.clips.first?.payload == image.payload)
        #expect(try target.state().clips.map(\.id) == [image.id])
        let publishedBlob = target.deviceFolder.appending(path: "blobs").appending(path: SyncBlob(bytes).hash)
        #expect(try Data(contentsOf: publishedBlob) == bytes)

        // A partially replaced peer file must not erase an already seen device.
        try Data().write(to: manifest, options: .atomic)
        await target.engine.syncNow()
        #expect(target.engine.otherDevices.map(\.name) == ["Source"])
        target.engine.stop()
        #expect(!target.engine.isEnabled)
        #expect(target.store.clips.first?.id == image.id)
        #expect(FileManager.default.fileExists(atPath: target.stateFile.path))
    }

    @Test func debouncesSavedChangesAndFollowsRenamedFolder() async throws {
        let device = try Device(name: "Renamed")
        defer { device.cleanUp() }
        await device.engine.syncNow()
        let snippet = try #require(device.store.createSnippet(title: "", content: "after debounce", in: nil))
        device.engine.requestSync()
        #expect(try device.state().clips.isEmpty)
        for _ in 0..<80 {
            if try device.state().clips.first?.id == snippet.id { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try device.state().clips.map(\.id) == [snippet.id])

        let renamed = device.root.appending(path: "renamed", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: device.folder, to: renamed)
        await device.engine.syncNow()
        #expect(device.engine.folder?.resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath())
        #expect(!FileManager.default.fileExists(atPath: device.folder.path))
        #expect(device.store.rename(snippet.id, title: "after rename"))
        await device.engine.syncNow()
        let movedFile = renamed.appending(path: "ClipShelf Sync/devices/\(device.engine.deviceID.uuidString)/state.json")
        #expect(try SyncState.decode(Data(contentsOf: movedFile)).clips.first?.title == "after rename")
    }

    private func history(_ text: String) -> Clip {
        Clip(id: UUID(), payload: .text(text, rtf: nil, html: nil), date: .now)
    }

    private func cards(in group: UUID, on device: Device) -> [UUID] {
        device.store.filtered(query: "", kind: nil, favoritesOnly: true, groupID: group).map(\.id)
    }

    private func expectOnly(_ saved: UUID, in device: Device, excluding privateClips: [Clip]) throws {
        let data = try Data(contentsOf: device.stateFile)
        #expect(try SyncState.decode(data).clips.map(\.id) == [saved])
        let json = String(decoding: data, as: UTF8.self)
        for clip in privateClips {
            #expect(!json.contains(clip.payload.previewText))
            #expect(!json.contains(clip.id.uuidString))
        }
    }

    @MainActor
    private struct Device {
        let root: URL
        let folder: URL
        let archive: ClipArchive
        let defaults: UserDefaults
        let store: ClipboardStore
        let engine: SyncEngine
        private let suite: String

        init(name: String, history: [Clip] = []) throws {
            let id = UUID().uuidString
            root = FileManager.default.temporaryDirectory.appending(path: "tapv-sync-\(id)")
            folder = root.appending(path: "exchange", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            archive = ClipArchive(legacyURL: root.appending(path: "History.plist"))
            try archive.write(upserting: history, removing: [])
            suite = "TapV.SyncEngineTests.\(id)"
            defaults = try #require(UserDefaults(suiteName: suite))
            store = ClipboardStore(board: nil, archive: archive, preferences: defaults)
            engine = SyncEngine(store: store, defaults: defaults, deviceName: name)
            engine.selectFolder(folder)
        }

        var deviceFolder: URL { peerFolder(engine.deviceID) }
        var stateFile: URL { deviceFolder.appending(path: "state.json") }

        func peerFolder(_ deviceID: UUID) -> URL {
            folder.appending(path: "ClipShelf Sync").appending(path: "devices").appending(path: deviceID.uuidString)
        }

        func state() throws -> SyncState { try SyncState.decode(Data(contentsOf: stateFile)) }

        func deliver(to peer: Device) throws {
            let destination = peer.peerFolder(engine.deviceID)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try Data(contentsOf: stateFile).write(to: destination.appending(path: "state.json"), options: .atomic)
        }

        func cleanUp() {
            engine.stop()
            store.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
