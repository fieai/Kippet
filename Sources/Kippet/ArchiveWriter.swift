import Foundation

final class ArchiveWriter: @unchecked Sendable {
    private let archive: ClipArchive
    private let queue = DispatchQueue(label: "Kippet.archive", qos: .utility)
    // Pending changes belong to the serial writer queue and survive a failed transaction.
    private var upserts: [Clip.ID: Clip] = [:]
    private var deletions: Set<Clip.ID> = []
    private var groups: [ClipGroup]?
    private var order: [Clip.ID]?
    private var tombstones: [SyncTombstone]?
    private var searchToken: String?

    init(archive: ClipArchive) {
        self.archive = archive
    }

    func save(
        upserting: [Clip], removing: [Clip.ID], groups: [ClipGroup]?, currentOrder: [Clip.ID]?, restoringOrder: Bool,
        tombstones: [SyncTombstone]?, searchToken: String?,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        queue.async {
            for clip in upserting {
                self.upserts[clip.id] = clip
                self.deletions.remove(clip.id)
            }
            for id in removing {
                self.upserts.removeValue(forKey: id)
                self.deletions.insert(id)
            }
            if let groups { self.groups = groups }
            if let tombstones { self.tombstones = tombstones }
            if let searchToken { self.searchToken = searchToken }
            if let currentOrder, restoringOrder || self.order != nil { self.order = currentOrder }
            completion(self.commit())
        }
    }

    func flush() {
        queue.sync { _ = commit() }
    }

    private func commit() -> Bool {
        guard !upserts.isEmpty || !deletions.isEmpty || groups != nil || tombstones != nil else { return true }
        do {
            let newestFirst = upserts.values.sorted { $0.date > $1.date }
            try archive.write(
                upserting: newestFirst, removing: Array(deletions), groups: groups, order: order, tombstones: tombstones,
                searchToken: searchToken ?? UUID().uuidString
            )
            upserts.removeAll()
            deletions.removeAll()
            groups = nil
            order = nil
            tombstones = nil
            searchToken = nil
            return true
        } catch {
            return false
        }
    }
}
