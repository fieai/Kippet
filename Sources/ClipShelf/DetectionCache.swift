import Foundation

@MainActor
final class DetectionCache {
    nonisolated static let maxTextBytes = 20_000

    private final class Entry {
        let byteCount: Int
        let sourceBundleIdentifier: String?
        let result: DetectedContent?

        init(byteCount: Int, sourceBundleIdentifier: String?, result: DetectedContent?) {
            self.byteCount = byteCount
            self.sourceBundleIdentifier = sourceBundleIdentifier
            self.result = result
        }
    }

    private let entries = NSCache<NSUUID, Entry>()

    init() {
        entries.countLimit = 500
    }

    func result(for clip: Clip) -> DetectedContent? {
        guard case let .text(text, _, _) = clip.payload else { return nil }

        let byteCount = text.utf8.count
        guard byteCount <= Self.maxTextBytes else { return nil }
        // Edits invalidate the ID. Recapture can change its source without changing the text.
        let source = clip.sourceBundleIdentifier
        let key = clip.id as NSUUID
        if let entry = entries.object(forKey: key),
           entry.byteCount == byteCount, entry.sourceBundleIdentifier == source {
            return entry.result
        }
        let result = ContentDetector.detect(text, sourceBundleIdentifier: source)
        entries.setObject(Entry(byteCount: byteCount, sourceBundleIdentifier: source, result: result), forKey: key)
        return result
    }

    func invalidate(_ id: Clip.ID) {
        entries.removeObject(forKey: id as NSUUID)
    }
}
