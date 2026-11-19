import Foundation
import Testing
@testable import ClipShelf

struct SyncMergeTests {
    private let time = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test func lastWriterWinsFromEitherDeviceAndBreaksTiesConsistently() throws {
        let id = UUID()
        let old = try clip(id: id, text: "old", at: time)
        let edited = try clip(id: id, text: "edited", at: time + 1)
        for (left, right) in [(old, edited), (edited, old)] {
            let states = [state(a, clips: [left]), state(b, clips: [right])]
            #expect(SyncMerge.merge(states, now: time).clips == [edited])
            #expect(SyncMerge.merge(states.reversed(), now: time).clips == [edited])
        }
        let tied = try clip(id: id, text: "same time", at: time)
        let states = [state(b, clips: [tied]), state(a, clips: [old])]
        #expect(SyncMerge.merge(states, now: time).clips == [old])
    }

    @Test func newerTombstonesDeleteAndNewerRecordsResurrect() throws {
        let id = UUID(), boardID = UUID()
        let old = try clip(id: id, text: "old", at: time)
        let edited = try clip(id: id, text: "edited", at: time + 2)
        let board = SyncGroup(ClipGroup(id: boardID, name: "原钉板", modifiedAt: time), position: 0)
        let renamed = SyncGroup(ClipGroup(id: boardID, name: "新钉板", modifiedAt: time + 2), position: 0)
        let deletions = [
            SyncTombstone(id: id, kind: .clip, deletedAt: time + 1),
            SyncTombstone(id: boardID, kind: .group, deletedAt: time + 1),
        ]
        let deleted = state(b, tombstones: deletions)
        let removed = SyncMerge.merge([state(a, clips: [old], groups: [board]), deleted], now: time + 2)
        #expect(removed.clips.isEmpty)
        #expect(removed.groups.isEmpty)
        #expect(removed.tombstones == deletions)

        let restored = SyncMerge.merge([state(a, clips: [edited], groups: [renamed]), deleted], now: time + 2)
        #expect(restored.clips == [edited])
        #expect(restored.groups == [renamed])
        #expect(restored.tombstones == deletions)
    }

    @Test func expiresTombstonesAfterThirtyDays() {
        let deletion = SyncTombstone(id: UUID(), kind: .clip, deletedAt: time)
        let states = [state(a, tombstones: [deletion])]
        #expect(SyncMerge.merge(states, now: time + 30 * 86_400).tombstones == [deletion])
        #expect(SyncMerge.merge(states, now: time + 30 * 86_400 + 1).tombstones.isEmpty)
    }

    @Test func groupCollisionAddsSuffixToNewerNameAcrossRepeatedMerges() {
        let older = SyncGroup(ClipGroup(id: UUID(), name: "项目", modifiedAt: time), position: 1)
        let newer = SyncGroup(ClipGroup(id: UUID(), name: "项目", modifiedAt: time + 1), position: 0)
        let merged = SyncMerge.merge([state(a, groups: [older]), state(b, groups: [newer])], now: time)
        #expect(merged.groups.map(\.id) == [newer.id, older.id])
        #expect(merged.groups.map(\.name) == ["项目（2）", "项目"])
        let repeated = SyncMerge.merge([state(a, groups: merged.groups), state(b, groups: [newer])], now: time)
        #expect(repeated.groups == merged.groups)
        let suffix = SyncGroup(ClipGroup(id: UUID(), name: "项目（2）", modifiedAt: time + 2), position: 2)
        let third = SyncMerge.merge([state(a, groups: merged.groups), state(b, groups: [suffix])], now: time)
        #expect(third.groups.map(\.name) == ["项目（3）", "项目", "项目（2）"])
    }

    @Test func winningCardOrderRetainsUnknownIDsOnDiskAndDropsThemFromVisibleCards() throws {
        let known = UUID(), other = UUID(), unknown = UUID(), id = UUID()
        let first = Clip(id: known, payload: .link("https://example.test/1"), date: time)
        let second = Clip(id: other, payload: .link("https://example.test/2"), date: time)
        let early = SyncGroup(ClipGroup(id: id, name: "A", cardOrder: [known, other], modifiedAt: time), position: 0)
        let later = SyncGroup(
            ClipGroup(id: id, name: "A", cardOrder: [other, unknown, known], modifiedAt: time + 1), position: 0
        )
        let merged = SyncMerge.merge([state(a, groups: [early]), state(b, groups: [later])], now: time)
        let data = try JSONEncoder().encode(state(a, groups: merged.groups))
        let stored = try #require(SyncState.decode(data).groups.first)
        let local = ClipGroup(id: id, name: stored.name, cardOrder: stored.cardOrder)
        #expect(stored.cardOrder == [other, unknown, known])
        #expect(local.ordered([first, second]).map(\.id) == [other, known])
        #expect(SyncMerge.movingCards([known, other], in: local.cardOrder) == [known, unknown, other])
    }

    @Test func deletedBoardKeepsItsLastCardsAsFavoritesEvenWithStaleMembership() throws {
        let board = UUID()
        let source = Clip(
            id: UUID(), payload: .link("https://example.test"), date: time, groupIDs: [board]
        )
        var blobs: [SyncBlob: Data] = [:]
        let member = try #require(SyncClip(source, blobs: &blobs))
        let deletion = SyncTombstone(id: board, kind: .group, deletedAt: time + 1)
        let merged = SyncMerge.merge([state(a, clips: [member]), state(b, tombstones: [deletion])], now: time)
        let retained = try #require(merged.clips.first)
        #expect(retained.isFavorite)
        #expect(retained.groupIDs.isEmpty)
    }

    @Test func blobReferencesAndFilePathsRoundTrip() throws {
        let data = Data("abc".utf8)
        let image = ClipImage(data: data, format: "public.png")
        let originals = [
            Clip(id: UUID(), payload: image.payload, date: time, isFavorite: true),
            Clip(id: UUID(), payload: .text("inline", rtf: data, html: Data("html".utf8)),
                 date: time, isFavorite: true),
            Clip(id: UUID(), payload: .files([URL(fileURLWithPath: "/tmp/image.png")]),
                 date: time, isFavorite: true, imageSnapshot: image),
        ]
        var blobs: [SyncBlob: Data] = [:]
        let records = originals.compactMap { SyncClip($0, blobs: &blobs) }
        let encoded = try JSONEncoder().encode(state(a, clips: records))
        let restored = try SyncState.decode(encoded).clips
        #expect(restored == records)
        #expect(blobs.count == 2)
        #expect(SyncBlob(data).hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        for (original, record) in zip(originals, restored) {
            let clip = record.materialize(existing: nil, blobs: blobs)
            #expect(clip.payload == original.payload)
            #expect(clip.imageSnapshot == original.imageSnapshot)
            #expect(clip.pendingSyncPayload == nil)
        }
        guard case let .files(paths, mayBeMissing, _) = restored.last?.payload else {
            Issue.record("Expected a file payload")
            return
        }
        #expect(paths == ["/tmp/image.png"])
        #expect(mayBeMissing)
    }

    @Test func olderPartialAndInvalidBlobStateAreRejected() throws {
        let valid = try JSONEncoder().encode(state(a))
        let json = String(decoding: valid, as: UTF8.self)
        let older = Data(json.replacingOccurrences(of: "\"format\":1", with: "\"format\":0").utf8)
        let partial = Data(json.dropLast().utf8)
        #expect(throws: DecodingError.self) { try SyncState.decode(older) }
        #expect(throws: DecodingError.self) { try SyncState.decode(partial) }
        #expect(throws: DecodingError.self) {
            try SyncState.decode(Data("{\"format\":1,\"clips\":[]}".utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SyncBlob.self, from: Data("\"../private\"".utf8))
        }
    }

    private func clip(id: UUID, text: String, at modifiedAt: Date) throws -> SyncClip {
        var blobs: [SyncBlob: Data] = [:]
        return try #require(SyncClip(Clip(
            id: id, payload: .text(text, rtf: nil, html: nil), date: time,
            isFavorite: true, modifiedAt: modifiedAt
        ), blobs: &blobs))
    }

    private func state(
        _ id: UUID, clips: [SyncClip] = [], groups: [SyncGroup] = [], tombstones: [SyncTombstone] = []
    ) -> SyncState {
        SyncState(
            device: .init(id: id, name: id.uuidString, updatedAt: time),
            records: .init(clips: clips, groups: groups, tombstones: tombstones)
        )
    }
}
