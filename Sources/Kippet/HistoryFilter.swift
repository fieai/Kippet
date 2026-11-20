import Foundation
import os

struct HistoryFilter: Equatable, Sendable {
    let search: String
    let contentType: HistoryContentType?
    let favoritesOnly: Bool
    let sourceName: String?
    let groupID: ClipGroup.ID?
    let sourceBundleIdentifier: String?
    let locale: Locale?

    func includes(_ clip: Clip) -> Bool {
        let sourceMatches: Bool
        if let expected = sourceBundleIdentifier, let actual = clip.sourceBundleIdentifier {
            sourceMatches = actual == expected
        } else if let sourceName {
            sourceMatches = clip.sourceName == sourceName
        } else {
            sourceMatches = sourceBundleIdentifier == nil
        }
        return sourceMatches &&
            (!favoritesOnly || clip.isSaved) &&
            (groupID.map { clip.groupIDs?.contains($0) == true } ?? true) &&
            matchesPayloadKind(clip.storedPayload.kind) &&
            (search.isEmpty ||
             (clip.title?.localizedStandardContains(search) ?? false) ||
             (clip.recognizedText?.localizedStandardContains(search) ?? false) ||
             (clip.barcodePayloads?.contains { $0.localizedStandardContains(search) } ?? false) ||
             clip.storedPayload.searchableText.localizedStandardContains(search) ||
             ((clip.sourceName ?? clip.sourceBundleIdentifier)?.localizedStandardContains(search) ?? false))
    }

    private func matchesPayloadKind(_ kind: ClipKind) -> Bool {
        switch contentType {
        case nil: true
        case let .kind(expected): kind == expected
        default: kind == .text
        }
    }

    @MainActor
    func matchingDetectedType(in clips: [Clip], cache: DetectionCache) -> [Clip] {
        switch contentType {
        case .color, .code, .oneTimeCode:
            clips.filter { clip in
                switch (contentType, cache.result(for: clip)) {
                case (.color, .color), (.code, .code), (.oneTimeCode, .oneTimeCode): true
                default: false
                }
            }
        case nil, .kind:
            clips
        }
    }
}

extension ClipboardStore {
    var sourceNames: [String] {
        Set(clips.compactMap(\.sourceName)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var sources: [ClipSource] {
        var distinct: [String: ClipSource] = [:]
        for clip in clips {
            guard let source = clip.source, distinct[source.id] == nil else { continue }
            distinct[source.id] = source
        }
        let namesWithBundleIDs = Set(distinct.values.compactMap { source in
            source.bundleIdentifier == nil ? nil : source.name
        })
        return distinct.values.filter {
            $0.bundleIdentifier != nil || !namesWithBundleIDs.contains($0.name)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func filtered(
        query: String, kind: ClipKind?, favoritesOnly: Bool, sourceName: String? = nil,
        groupID: UUID? = nil, sourceBundleIdentifier: String? = nil
    ) -> [Clip] {
        filtered(
            query: query, contentType: kind.map(HistoryContentType.kind), favoritesOnly: favoritesOnly,
            sourceName: sourceName, groupID: groupID, sourceBundleIdentifier: sourceBundleIdentifier
        )
    }

    func filtered(
        query: String, contentType: HistoryContentType?, favoritesOnly: Bool, sourceName: String? = nil,
        groupID: UUID? = nil, sourceBundleIdentifier: String? = nil
    ) -> [Clip] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if search.isEmpty, contentType == nil, !favoritesOnly, sourceName == nil,
           groupID == nil, sourceBundleIdentifier == nil { return clips }

        let filter = HistoryFilter(
            search: search, contentType: contentType, favoritesOnly: favoritesOnly, sourceName: sourceName,
            groupID: groupID, sourceBundleIdentifier: sourceBundleIdentifier,
            locale: search.isEmpty ? nil : .current
        )
        if let lastFilter, lastFilter.filter == filter { return lastFilter.results }
        let snapshot = searchToken.flatMap {
            archive.searchCandidates(for: search, historyCount: clips.count, token: $0)
        }.map { candidates in clips.filter { candidates.contains($0.id) } } ?? clips
        let group = groupID.flatMap { id in groups.first { $0.id == id } }

        let workers = search.isEmpty ? 1 : min(Self.searchWorkerLimit, max(1, snapshot.count / 625))
        let matches: [Clip]
        if workers == 1 {
            matches = snapshot.filter(filter.includes)
        } else {
            // Workers search immutable slices. Gathering by slice keeps the original history order.
            let batches = OSAllocatedUnfairLock(initialState: [[Clip]](repeating: [], count: workers))
            DispatchQueue.concurrentPerform(iterations: workers) { batch in
                let start = batch * snapshot.count / workers
                let end = (batch + 1) * snapshot.count / workers
                let matches = snapshot[start..<end].filter(filter.includes)
                batches.withLock { $0[batch] = matches }
            }
            matches = batches.withLock { $0.flatMap { $0 } }
        }
        let filtered = filter.matchingDetectedType(in: matches, cache: detectionCache)
        let results = group?.ordered(filtered) ?? filtered
        lastFilter = (filter, results)
        return results
    }

    private static let searchWorkerLimit = min(8, ProcessInfo.processInfo.activeProcessorCount)
}
