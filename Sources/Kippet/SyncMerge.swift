import CryptoKit
import Foundation

struct SyncBlob: Codable, Equatable, Hashable, Sendable {
    let hash: String

    init(_ data: Data) {
        hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        hash = try value.decode(String.self)
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid SHA-256 hash") }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(hash)
    }
}

enum SyncPayload: Codable, Equatable, Sendable {
    struct Image: Codable, Equatable, Sendable {
        let blob: SyncBlob
        let format: String
    }

    case text(String, rtf: SyncBlob?, html: SyncBlob?)
    case link(String)
    case image(Image)
    case files(paths: [String], mayBeMissing: Bool, image: Image?)

    var blobs: [SyncBlob] {
        switch self {
        case let .text(_, rtf, html): [rtf, html].compactMap { $0 }
        case .link: []
        case let .image(image): [image.blob]
        case let .files(_, _, image): image.map { [$0.blob] } ?? []
        }
    }
}

struct SyncClip: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let payload: SyncPayload
    let date: Date
    let title: String?
    var isFavorite: Bool
    var groupIDs: [UUID]
    let modifiedAt: Date

    var isSaved: Bool { isFavorite || !groupIDs.isEmpty }

    init?(_ clip: Clip, blobs: inout [SyncBlob: Data]) {
        guard clip.isSyncSaved else { return nil }
        func store(_ data: Data) -> SyncBlob {
            let blob = SyncBlob(data)
            blobs[blob] = data
            return blob
        }

        let available: SyncPayload
        switch clip.storedPayload {
        case let .text(text, rtf, html):
            available = .text(text, rtf: rtf.map(store), html: html.map(store))
        case let .link(link):
            available = .link(link)
        case let .image(data, format):
            if clip.hasPendingSyncImage, let pending = clip.pendingSyncPayload {
                available = pending
            } else {
                available = .image(.init(blob: store(data), format: format))
            }
        case let .files(urls):
            let image = clip.imageSnapshot.map { SyncPayload.Image(blob: store($0.data), format: $0.format) }
            available = .files(paths: urls.map(\.path), mayBeMissing: true, image: image)
        }
        id = clip.id
        payload = clip.pendingSyncPayload ?? available
        date = clip.date
        title = clip.title
        isFavorite = clip.isFavorite
        groupIDs = (clip.groupIDs ?? []).sorted { $0.uuidString < $1.uuidString }
        modifiedAt = clip.modifiedAt ?? clip.date
    }

    func materialize(existing: Clip?, blobs: [SyncBlob: Data]) -> Clip {
        var snapshot: ClipImage?
        let content: ClipPayload
        switch payload {
        case let .text(text, rtf, html):
            content = .text(text, rtf: rtf.flatMap { blobs[$0] }, html: html.flatMap { blobs[$0] })
        case let .link(link):
            content = .link(link)
        case let .image(image):
            content = .image(blobs[image.blob] ?? Data(), format: image.format)
        case let .files(paths, _, image):
            content = .files(paths.map { URL(fileURLWithPath: $0) })
            if let image, let data = blobs[image.blob] {
                snapshot = ClipImage(data: data, format: image.format)
            }
        }
        let keepsRecognition = existing.map {
            (try? $0.readPayload()) == content && (try? $0.readImageSnapshot()) == snapshot
        } ?? false
        var clip = Clip(
            id: id, payload: content, date: date, sourceName: existing?.sourceName, isFavorite: isFavorite,
            imageSnapshot: snapshot, groupIDs: groupIDs.isEmpty ? nil : Set(groupIDs),
            sourceBundleIdentifier: existing?.sourceBundleIdentifier, title: title,
            recognizedText: keepsRecognition ? existing?.recognizedText : nil,
            barcodePayloads: keepsRecognition ? existing?.barcodePayloads : nil,
            modifiedAt: modifiedAt, syncOnly: existing == nil ? true : existing?.syncOnly,
            pendingSyncPayload: payload.blobs.allSatisfy { blobs[$0] != nil } ? nil : payload
        )
        if keepsRecognition, let existing {
            clip.storedPayload = existing.storedPayload
            clip.imageSnapshot = existing.imageSnapshot
            clip.imageBlob = existing.imageBlob
            clip.snapshotBlob = existing.snapshotBlob
            clip.blobSource = existing.blobSource
            clip.contentHash = existing.contentHash
        }
        return clip
    }
}

struct SyncGroup: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var originalName: String?
    let color: ClipGroupColor?
    var cardOrder: [UUID]?
    let modifiedAt: Date
    var position: Int?

    init(_ group: ClipGroup, position: Int) {
        id = group.id
        name = group.name
        originalName = group.syncName
        color = group.color
        cardOrder = group.cardOrder
        modifiedAt = group.modifiedAt ?? .distantPast
        self.position = group.syncPosition ?? position
    }
}

struct SyncTombstone: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case clip, group }

    struct Key: Hashable, Sendable {
        let id: UUID
        let kind: Kind
    }

    let id: UUID
    let kind: Kind
    let deletedAt: Date
    var key: Key { Key(id: id, kind: kind) }
}

struct SyncRecords: Equatable, Sendable {
    var clips: [SyncClip] = []
    var groups: [SyncGroup] = []
    var tombstones: [SyncTombstone] = []
}

struct SyncLibrary: Sendable {
    let clips: [Clip]
    let groups: [ClipGroup]
    let tombstones: [SyncTombstone]
    let privateIDs: Set<UUID>

    func records(blobs: inout [SyncBlob: Data]) throws -> SyncRecords {
        try SyncRecords(
            clips: clips.compactMap { clip in SyncClip(try clip.materializedImages(), blobs: &blobs) },
            groups: groups.enumerated().map { SyncGroup($0.element, position: $0.offset) },
            tombstones: tombstones
        )
    }
}

struct SyncState: Codable, Equatable, Sendable {
    struct Device: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let name: String
        let updatedAt: Date
    }

    let format: Int
    let device: Device
    let clips: [SyncClip]
    let groups: [SyncGroup]
    let tombstones: [SyncTombstone]

    var records: SyncRecords { .init(clips: clips, groups: groups, tombstones: tombstones) }

    init(device: Device, records: SyncRecords) {
        format = 1
        self.device = device
        clips = records.clips
        groups = records.groups
        tombstones = records.tombstones
    }

    static func decode(_ data: Data) throws -> Self {
        let state = try JSONDecoder().decode(Self.self, from: data)
        guard state.format == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported sync format"))
        }
        return state
    }
}

enum SyncMerge {
    static func merge(_ states: [SyncState], now: Date = .now, privateIDs: Set<UUID> = []) -> SyncRecords {
        var groups: [UUID: SyncGroup] = [:]
        var clips: [UUID: SyncClip] = [:]
        var tombstones: [SyncTombstone.Key: SyncTombstone] = [:]
        let cutoff = now.addingTimeInterval(-30 * 86_400)

        // The device ID gives equal timestamps a stable winner on every Mac.
        for state in states.sorted(by: { $0.device.id.uuidString < $1.device.id.uuidString }) {
            for (position, record) in state.groups.enumerated() {
                var group = record
                group.position = group.position ?? position
                if groups[group.id].map({ $0.modifiedAt >= group.modifiedAt }) != true {
                    groups[group.id] = group
                }
            }
            for clip in state.clips where clip.isSaved && !privateIDs.contains(clip.id) {
                if clips[clip.id].map({ $0.modifiedAt >= clip.modifiedAt }) != true { clips[clip.id] = clip }
            }
            for tombstone in state.tombstones where tombstone.deletedAt >= cutoff {
                if tombstones[tombstone.key].map({ $0.deletedAt >= tombstone.deletedAt }) != true {
                    tombstones[tombstone.key] = tombstone
                }
            }
        }

        for tombstone in tombstones.values {
            switch tombstone.kind {
            case .clip:
                if clips[tombstone.id].map({ $0.modifiedAt <= tombstone.deletedAt }) == true {
                    clips.removeValue(forKey: tombstone.id)
                }
            case .group:
                if groups[tombstone.id].map({ $0.modifiedAt <= tombstone.deletedAt }) == true {
                    groups.removeValue(forKey: tombstone.id)
                }
            }
        }
        let deletedGroups = Set(tombstones.values.compactMap {
            $0.kind == .group && groups[$0.id] == nil ? $0.id : nil
        })
        let orderedGroups = groups.values.sorted {
            let lhs = $0.position ?? 0, rhs = $1.position ?? 0
            if lhs != rhs { return lhs < rhs }
            return $0.id.uuidString < $1.id.uuidString
        }.map { group in
            var group = group
            group.cardOrder?.removeAll { privateIDs.contains($0) }
            return group
        }

        return SyncRecords(
            clips: clips.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { clip in
                var clip = clip
                clip.groupIDs.removeAll { deletedGroups.contains($0) }
                if clip.groupIDs.isEmpty { clip.isFavorite = true }
                return clip
            },
            groups: resolveNames(orderedGroups),
            tombstones: tombstones.values.sorted {
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.id.uuidString < $1.id.uuidString
            }
        )
    }

    private static func resolveNames(_ records: [SyncGroup]) -> [SyncGroup] {
        func key(_ name: String) -> String {
            name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        }
        var reserved = Set(records.map { key($0.originalName ?? $0.name) })
        var seen: Set<String> = []
        var names: [UUID: String] = [:]
        let oldestFirst = records.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        for group in oldestFirst {
            let name = group.originalName ?? group.name
            if seen.insert(key(name)).inserted { continue }
            var number = 2
            while true {
                let candidate = name + "（\(number)）"
                if reserved.insert(key(candidate)).inserted {
                    names[group.id] = candidate
                    break
                }
                number += 1
            }
        }
        return records.map { group in
            var group = group
            let original = group.originalName ?? group.name
            group.name = names[group.id] ?? original
            group.originalName = names[group.id].map { _ in original }
            return group
        }
    }

    // Replace visible slots while retaining references to cards that haven't arrived yet.
    static func movingCards(_ visible: [UUID], in order: [UUID]?) -> [UUID] {
        let visibleIDs = Set(visible)
        var items = visible.makeIterator()
        let retained = (order ?? []).map { id in visibleIDs.contains(id) ? (items.next() ?? id) : id }
        return retained + Array(items)
    }
}
