import Foundation

extension ClipboardStore {
    func createGroup(name: String, color: ClipGroupColor? = nil) -> ClipGroup? {
        guard let name = availableGroupName(name) else { return nil }
        let position = groups.last.map { $0.syncPosition ?? groups.count - 1 } ?? -1
        let group = ClipGroup(id: UUID(), name: name, color: color, modifiedAt: .now,
                              syncPosition: position < Int.max ? position + 1 : position)
        groups.append(group)
        markSyncChanged()
        save(groupsChanged: true)
        return group
    }

    func renameGroup(_ id: UUID, name: String, color: ClipGroupColor? = nil) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return false }
        let input = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = input == groups[index].name ? input : availableGroupName(input, excluding: id)
        else { return false }
        guard groups[index].name != name || (color != nil && groups[index].color != color) else { return true }
        if groups[index].name != name {
            groups[index].name = name
            groups[index].syncName = nil
        }
        if let color { groups[index].color = color }
        touchGroup(at: index)
        save(groupsChanged: true)
        return true
    }

    func moveGroup(_ id: ClipGroup.ID, onto destination: ClipGroup.ID) {
        guard id != destination, let from = groups.firstIndex(where: { $0.id == id }),
              let to = groups.firstIndex(where: { $0.id == destination }) else { return }
        let group = groups.remove(at: from)
        groups.insert(group, at: to)
        for index in groups.indices where groups[index].syncPosition != index {
            groups[index].syncPosition = index
            touchGroup(at: index)
        }
        save(groupsChanged: true)
    }

    func moveCard(_ id: Clip.ID, onto destination: Clip.ID, in groupID: ClipGroup.ID) -> Bool {
        guard id != destination, let index = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        var order = filtered(query: "", kind: nil, favoritesOnly: true, groupID: groupID).map(\.id)
        guard let from = order.firstIndex(of: id), let to = order.firstIndex(of: destination) else { return false }
        order.remove(at: from)
        order.insert(id, at: to)
        groups[index].cardOrder = SyncMerge.movingCards(order, in: groups[index].cardOrder)
        touchGroup(at: index)
        save(groupsChanged: true)
        return true
    }

    func removeGroup(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let removed = groups.remove(at: index)
        recordSyncDeletion(id: id, kind: .group, after: removed.modifiedAt)
        var changed: [Clip] = []
        for index in clips.indices where clips[index].groupIDs?.contains(id) == true {
            let original = clips[index]
            var clip = original
            clip.groupIDs?.remove(id)
            if clip.groupIDs?.isEmpty == true { clip.groupIDs = nil }
            if !clip.isSaved { clip.isFavorite = true }
            recordSyncChange(to: &clip, replacing: original)
            clips[index] = clip
            changed.append(clip)
        }
        save(upserting: changed, groupsChanged: true)
    }

    func toggleGroup(_ groupID: UUID, for clipID: Clip.ID) -> Bool {
        guard let board = groups.firstIndex(where: { $0.id == groupID }),
              let index = clips.firstIndex(where: { $0.id == clipID })
        else { return false }
        var clip = clips[index]
        var membership = clip.groupIDs ?? []
        guard membership.remove(groupID) != nil else { return addCards([clipID], to: groupID) }
        if membership.isEmpty { clip.isFavorite = true }
        clip.groupIDs = membership.isEmpty ? nil : membership
        recordSyncChange(to: &clip, replacing: clips[index])
        clips[index] = clip
        let position = groups[board].cardOrder?.firstIndex(of: clipID)
        if let position {
            groups[board].cardOrder?.remove(at: position)
            touchGroup(at: board)
        }
        save(upserting: [clip], groupsChanged: position != nil)
        return true
    }

    func addCards(_ ids: Set<Clip.ID>, to groupID: ClipGroup.ID) -> Bool {
        guard !ids.isEmpty, groups.contains(where: { $0.id == groupID }) else { return false }
        let selected = clips.indices.filter { ids.contains(clips[$0].id) }
        guard selected.count == ids.count else { return false }
        let additions = selected.filter { clips[$0].groupIDs?.contains(groupID) != true }
        let extra = additions.reduce(0) { $0 + (clips[$1].isSaved ? 0 : clips[$1].size) }
        guard extra == 0 || savedSize() + extra <= Self.favoriteSize else { return false }
        guard !additions.isEmpty else { return true }
        var updated = clips
        let changed = additions.map { index in
            var clip = updated[index]
            clip.groupIDs = (clip.groupIDs ?? []).union([groupID])
            clip.cancelExpiryIfSaved()
            recordSyncChange(to: &clip, replacing: updated[index])
            updated[index] = clip
            return clip
        }
        clips = updated
        save(upserting: changed)
        return true
    }

    private func availableGroupName(_ input: String, excluding id: UUID? = nil) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40,
              !groups.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        return name
    }

    func fitsFavorites(_ clip: Clip) -> Bool {
        savedSize(excluding: clip.id) + clip.size <= Self.favoriteSize
    }

    private func savedSize(excluding id: Clip.ID? = nil) -> Int {
        clips.lazy.filter { $0.isSaved && $0.id != id }.reduce(0) { $0 + $1.size }
    }
}
