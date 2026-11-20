import Foundation
import Observation

@MainActor
@Observable
final class PasteStack {
    struct Entry: Identifiable {
        let id = UUID()
        let clip: Clip
    }

    private(set) var entries: [Entry] = []
    var isCollecting = false
    private var lastPasted: Entry?

    var canUndoPaste: Bool {
        guard let lastPasted else { return false }
        return entries.count < 50 &&
            entries.reduce(lastPasted.clip.size, { $0 + $1.clip.size }) <= 64 * 1_024 * 1_024
    }
    var next: Entry? { entries.first }

    @discardableResult
    func append(_ clips: [Clip]) -> Bool {
        let totalSize = entries.reduce(0) { $0 + $1.clip.size } + clips.reduce(0) { $0 + $1.size }
        guard entries.count + clips.count <= 50, totalSize <= 64 * 1_024 * 1_024 else { return false }
        guard let entriesToAppend = try? clips.map({ Entry(clip: try $0.materializedImages()) }) else { return false }
        entries.append(contentsOf: entriesToAppend)
        return true
    }

    func didSend(_ id: Entry.ID) -> Bool {
        guard next?.id == id else { return false }
        lastPasted = entries.removeFirst()
        return true
    }

    func undoLastPaste() {
        guard canUndoPaste, let lastPasted else { return }
        entries.insert(lastPasted, at: 0)
        self.lastPasted = nil
    }

    func remove(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
    }

    func move(_ id: Entry.ID, by offset: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries.indices.contains(index + offset) else { return }
        entries.swapAt(index, index + offset)
    }

    func clear() {
        entries.removeAll()
        lastPasted = nil
        isCollecting = false
    }
}
