import Foundation
import ImageIO

enum ClipBlobKind: String, CaseIterable, Sendable {
    case image, snapshot
}

struct ClipImageReference: Codable, Equatable, Sendable {
    let format: String
    let byteCount: Int
    let digest: SyncBlob
    let width: Int?
    let height: Int?

    init(_ image: ClipImage) {
        format = image.format
        byteCount = image.data.count
        digest = SyncBlob(image.data)
        let source = CGImageSourceCreateWithData(image.data as CFData, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
        width = properties?[kCGImagePropertyPixelWidth] as? Int
        height = properties?[kCGImagePropertyPixelHeight] as? Int
    }
}

// The writer and current card share the bytes until SQLite commits them.
final class ClipBlobSource: @unchecked Sendable {
    let archive: ClipArchive
    private let lock = NSLock()
    private var pending: [ClipBlobKind: Data]

    init(archive: ClipArchive, pending: [ClipBlobKind: Data] = [:]) {
        self.archive = archive
        self.pending = pending
    }

    func staged(_ kind: ClipBlobKind) -> Data? {
        lock.withLock { pending[kind] }
    }

    func didPersist() {
        lock.withLock { pending.removeAll() }
    }
}

extension Clip {
    func readPayload() throws -> ClipPayload {
        guard let imageBlob else { return storedPayload }
        return .image(try readBlob(.image, imageBlob), format: imageBlob.format)
    }

    func readImageSnapshot() throws -> ClipImage? {
        guard let snapshotBlob else { return imageSnapshot }
        return ClipImage(data: try readBlob(.snapshot, snapshotBlob), format: snapshotBlob.format)
    }

    func readPreviewImage() throws -> ClipImage? {
        if let snapshot = try readImageSnapshot() { return snapshot }
        guard case let .image(data, format) = try readPayload() else { return nil }
        return ClipImage(data: data, format: format)
    }

    var previewImageFormat: String? {
        guard hasPreviewImage else { return nil }
        if let format = snapshotBlob?.format ?? imageSnapshot?.format ?? imageBlob?.format { return format }
        if case let .image(_, format) = storedPayload { return format }
        return nil
    }

    func materializedImages() throws -> Clip {
        guard imageBlob != nil || snapshotBlob != nil else { return self }
        var copy = self
        copy.storedPayload = try readPayload()
        copy.imageSnapshot = try readImageSnapshot()
        copy.imageBlob = nil
        copy.snapshotBlob = nil
        copy.blobSource = nil
        return copy
    }

    func hasSamePreviewImage(as other: Clip) -> Bool {
        if let reference = snapshotBlob ?? imageBlob {
            return reference == (other.snapshotBlob ?? other.imageBlob)
        }
        return other.imageBlob == nil && other.snapshotBlob == nil && previewPayload == other.previewPayload
    }

    private func readBlob(_ kind: ClipBlobKind, _ reference: ClipImageReference) throws -> Data {
        guard let blobSource else { throw CocoaError(.fileReadNoSuchFile) }
        if let data = blobSource.staged(kind) { return data }
        return try blobSource.archive.readBlob(id: id, kind: kind, reference: reference)
    }
}
