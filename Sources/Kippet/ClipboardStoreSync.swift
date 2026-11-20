import Foundation

extension ClipboardStore {
    func syncLibrary() -> SyncLibrary {
        SyncLibrary(
            clips: clips.filter(\.isSyncSaved), groups: groups, tombstones: syncTombstones,
            privateIDs: Set(clips.lazy.filter { !$0.canSync }.map(\.id))
        )
    }

    func applySync(_ records: SyncRecords, blobs: [SyncBlob: Data]) {
        var incoming = Dictionary(uniqueKeysWithValues: records.clips.map { ($0.id, $0) })
        let deleted = Set(records.tombstones.lazy.filter { $0.kind == .clip }.map(\.id))
        let privateIDs = Set(clips.lazy.filter { !$0.canSync }.map(\.id))
        let localGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let liveGroupIDs = Set(records.groups.map(\.id))
        let deletedGroups = Set(records.tombstones.lazy.filter {
            $0.kind == .group && !liveGroupIDs.contains($0.id)
        }.map(\.id))
        let updatedGroups = records.groups.map { group in
            var order = group.cardOrder
            // Private cards can be arranged locally without publishing their identifiers.
            for (index, id) in (localGroups[group.id]?.cardOrder ?? []).enumerated() where privateIDs.contains(id) {
                var localOrder = order ?? []
                localOrder.insert(id, at: min(index, localOrder.count))
                order = localOrder
            }
            return ClipGroup(
                id: group.id, name: group.name, color: group.color, cardOrder: order,
                modifiedAt: group.modifiedAt, syncPosition: group.position, syncName: group.originalName
            )
        }
        var changed: [Clip] = []
        var removed: [Clip.ID] = []
        let existing = clips.compactMap { clip -> Clip? in
            var updated = clip
            let record = incoming.removeValue(forKey: clip.id)
            if !clip.canSync {
                if let membership = clip.groupIDs, !membership.isDisjoint(with: deletedGroups) {
                    let remaining = membership.subtracting(deletedGroups)
                    updated.groupIDs = remaining.isEmpty ? nil : remaining
                    if !updated.isSaved { updated.isFavorite = true }
                }
            } else if let record {
                updated = prepareSyncClip(record.materialize(existing: clip, blobs: blobs))
            } else if clip.isSaved, deleted.contains(clip.id) {
                if clip.syncOnly == true {
                    removed.append(clip.id)
                    return nil
                }
                updated.isFavorite = false
                updated.groupIDs = nil
            }
            if updated != clip { changed.append(updated) }
            return updated
        }
        let added = incoming.values.map { prepareSyncClip($0.materialize(existing: nil, blobs: blobs)) }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }
        changed.append(contentsOf: added)

        let groupsChanged = updatedGroups != groups
        if records.tombstones != syncTombstones {
            syncTombstones = records.tombstones
            syncTombstonesChanged = true
        }
        if groupsChanged { groups = updatedGroups }
        guard groupsChanged || syncTombstonesChanged || !changed.isEmpty || !removed.isEmpty else { return }
        if !changed.isEmpty || !removed.isEmpty { clips = added + existing }
        save(upserting: changed, removing: removed, groupsChanged: groupsChanged, restoringOrder: !changed.isEmpty)
        for clip in changed { queueOCR(clip) }
    }

    private func prepareSyncClip(_ incoming: Clip) -> Clip {
        var clip = archive.externalizingImages(incoming)
        if clip.contentHash == nil { clip.contentHash = clip.computeContentHash() }
        return clip
    }

    func recordSyncChange(to clip: inout Clip, replacing previous: Clip?) {
        guard clip.isSaved || previous?.isSaved == true else { return }
        let wasSaved = previous?.isSyncSaved == true
        let before = previous.map { $0.modifiedAt ?? $0.date } ?? clip.modifiedAt
        let date = syncDate(id: clip.id, kind: .clip, after: before)
        clip.modifiedAt = date
        if clip.isSyncSaved {
            markSyncChanged()
        } else if wasSaved {
            addSyncTombstone(id: clip.id, kind: .clip, at: date)
        }
    }

    func touchGroup(at index: Int) {
        groups[index].modifiedAt = syncDate(id: groups[index].id, kind: .group, after: groups[index].modifiedAt)
        markSyncChanged()
    }

    private func syncDate(id: UUID, kind: SyncTombstone.Kind, after previous: Date?) -> Date {
        let deleted = syncTombstones.first { $0.id == id && $0.kind == kind }?.deletedAt
        let last = max(previous ?? .distantPast, deleted ?? .distantPast)
        return max(.now, Date(timeIntervalSinceReferenceDate: last.timeIntervalSinceReferenceDate.nextUp))
    }

    func recordSyncDeletion(id: UUID, kind: SyncTombstone.Kind, after previous: Date?) {
        let date = syncDate(id: id, kind: kind, after: previous)
        addSyncTombstone(id: id, kind: kind, at: date)
    }

    private func addSyncTombstone(id: UUID, kind: SyncTombstone.Kind, at date: Date) {
        let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
        syncTombstones.removeAll { ($0.id == id && $0.kind == kind) || $0.deletedAt < cutoff }
        syncTombstones.append(.init(id: id, kind: kind, deletedAt: date))
        syncTombstonesChanged = true
        markSyncChanged()
    }

    func markSyncChanged() {
        syncRevision += 1
        onSavedStateChange?()
    }
}
