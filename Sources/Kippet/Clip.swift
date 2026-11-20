import Foundation

enum ClipKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case text, link, image, files

    var id: Self { self }

    var label: String {
        switch self {
        case .text: L("文字")
        case .link: L("链接")
        case .image: L("图片")
        case .files: L("文件")
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }
}

enum ClipPayload: Codable, Equatable, Sendable {
    case text(String, rtf: Data?, html: Data?)
    case link(String)
    case image(Data, format: String)
    case files([URL])

    var kind: ClipKind {
        switch self {
        case .text: .text
        case .link: .link
        case .image: .image
        case .files: .files
        }
    }

    var previewText: String {
        switch self {
        case let .text(text, _, _): text
        case let .link(url): url
        case .image: kind.label
        case let .files(urls): urls.map(\.lastPathComponent).joined(separator: "\n")
        }
    }

    var size: Int {
        switch self {
        case let .text(text, rtf, html): text.utf8.count + (rtf?.count ?? 0) + (html?.count ?? 0)
        case let .link(url): url.utf8.count
        case let .image(data, _): data.count
        case let .files(urls): urls.reduce(0) { $0 + $1.absoluteString.utf8.count }
        }
    }

    var searchableText: String {
        switch self {
        // Keep the image token stable for the on-disk search index.
        case .image: "图片"
        case let .files(urls): urls.map(\.path).joined(separator: "\n")
        default: previewText
        }
    }

    var supportsPlainText: Bool {
        kind == .text || kind == .link
    }

    var singleImageFile: URL? {
        guard case let .files(urls) = self, urls.count == 1, let url = urls.first,
              url.isFileURL, ["jpg", "jpeg", "png", "tif", "tiff"].contains(url.pathExtension.lowercased())
        else { return nil }
        return url
    }
}

struct ClipImage: Codable, Equatable, Sendable {
    let data: Data
    let format: String

    var payload: ClipPayload { .image(data, format: format) }
}

enum ClipGroupColor: String, CaseIterable, Codable, Hashable, Sendable {
    case teal, blue, purple, pink, orange, green, yellow

    var label: String {
        switch self {
        case .teal: L("青色")
        case .blue: L("蓝色")
        case .purple: L("紫色")
        case .pink: L("粉色")
        case .orange: L("橙色")
        case .green: L("绿色")
        case .yellow: L("黄色")
        }
    }
}

struct ClipGroup: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var color: ClipGroupColor? = nil
    var cardOrder: [UUID]? = nil
    var modifiedAt: Date? = nil
    var syncPosition: Int? = nil
    // Keep the original name when the displayed name has a collision suffix.
    var syncName: String? = nil

    func ordered(_ clips: [Clip]) -> [Clip] {
        guard let cardOrder, !cardOrder.isEmpty, clips.count > 1 else { return clips }
        var remaining = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        let ranked = cardOrder.compactMap { remaining.removeValue(forKey: $0) }
        return ranked + clips.filter { remaining[$0.id] != nil }
    }
}

struct ClipSource: Identifiable, Hashable, Sendable {
    let name: String
    let bundleIdentifier: String?

    var id: String { bundleIdentifier.map { "bundle:\($0)" } ?? "name:\(name)" }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct Clip: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var storedPayload: ClipPayload
    var date: Date
    var sourceName: String?
    var isFavorite = false
    var imageSnapshot: ClipImage?
    var groupIDs: Set<UUID>? = nil
    var sourceBundleIdentifier: String? = nil
    var title: String? = nil
    var recognizedText: String? = nil
    var barcodePayloads: [String]? = nil
    var expiresAt: Date? = nil
    // Set on temporary transform results so the normal poll can capture a successful write.
    var capturesOnCopy: Bool? = nil
    var modifiedAt: Date? = nil
    var excludedFromSync: Bool? = nil
    var syncOnly: Bool? = nil
    var pendingSyncPayload: SyncPayload? = nil
    var contentHash: String? = nil
    var imageBlob: ClipImageReference? = nil
    var snapshotBlob: ClipImageReference? = nil
    var blobSource: ClipBlobSource? = nil

    private enum CodingKeys: String, CodingKey {
        case id, storedPayload = "payload", date, sourceName, isFavorite, imageSnapshot, groupIDs
        case sourceBundleIdentifier, title, recognizedText, barcodePayloads, expiresAt, capturesOnCopy
        case modifiedAt, excludedFromSync, syncOnly, pendingSyncPayload, contentHash, imageBlob, snapshotBlob
    }

    static func == (lhs: Clip, rhs: Clip) -> Bool {
        guard lhs.id == rhs.id, lhs.date == rhs.date, lhs.sourceName == rhs.sourceName,
              lhs.isFavorite == rhs.isFavorite, lhs.groupIDs == rhs.groupIDs,
              lhs.sourceBundleIdentifier == rhs.sourceBundleIdentifier, lhs.title == rhs.title,
              lhs.recognizedText == rhs.recognizedText, lhs.barcodePayloads == rhs.barcodePayloads,
              lhs.expiresAt == rhs.expiresAt, lhs.capturesOnCopy == rhs.capturesOnCopy,
              lhs.modifiedAt == rhs.modifiedAt, lhs.excludedFromSync == rhs.excludedFromSync,
              lhs.syncOnly == rhs.syncOnly, lhs.pendingSyncPayload == rhs.pendingSyncPayload else { return false }
        // Hashes and blob references are derived from the original content.
        if lhs.imageBlob == rhs.imageBlob, lhs.snapshotBlob == rhs.snapshotBlob {
            return lhs.storedPayload == rhs.storedPayload && lhs.imageSnapshot == rhs.imageSnapshot
        }
        if lhs.imageBlob != nil, rhs.imageBlob != nil, lhs.imageBlob != rhs.imageBlob { return false }
        if lhs.snapshotBlob != nil, rhs.snapshotBlob != nil, lhs.snapshotBlob != rhs.snapshotBlob { return false }
        do {
            return try lhs.readPayload() == rhs.readPayload() && lhs.readImageSnapshot() == rhs.readImageSnapshot()
        } catch {
            return false
        }
    }

    var payload: ClipPayload {
        get { (try? readPayload()) ?? storedPayload }
        set {
            storedPayload = newValue
            contentHash = nil
            imageBlob = nil
            if snapshotBlob == nil { blobSource = nil }
        }
    }
    var size: Int {
        (imageBlob?.byteCount ?? storedPayload.size) + (snapshotBlob?.byteCount ?? imageSnapshot?.data.count ?? 0)
    }

    var isSaved: Bool { isFavorite || groupIDs?.isEmpty == false }
    var canSync: Bool { expiresAt == nil && excludedFromSync != true }
    var isSyncSaved: Bool { isSaved && canSync }
    var hasPendingSyncImage: Bool {
        switch pendingSyncPayload {
        case .image: true
        case let .files(_, _, image): image != nil && !hasImageSnapshot
        default: false
        }
    }
    var hasImageSnapshot: Bool { snapshotBlob != nil || imageSnapshot != nil }
    var hasPreviewImage: Bool { !hasPendingSyncImage && (hasImageSnapshot || storedPayload.kind == .image) }
    var previewPayload: ClipPayload { (try? readPreviewImage())?.payload ?? storedPayload }

    mutating func cancelExpiryIfSaved() {
        // Saving cancels local expiry. The sync exclusion follows the card for its lifetime.
        if expiresAt != nil { excludedFromSync = true }
        if isSaved { expiresAt = nil }
    }

    var source: ClipSource? {
        guard let name = sourceName ?? sourceBundleIdentifier else { return nil }
        return ClipSource(name: name, bundleIdentifier: sourceBundleIdentifier)
    }
}

extension Clip {
    init(
        id: UUID, payload: ClipPayload, date: Date, sourceName: String? = nil, isFavorite: Bool = false,
        imageSnapshot: ClipImage? = nil, groupIDs: Set<UUID>? = nil, sourceBundleIdentifier: String? = nil,
        title: String? = nil, recognizedText: String? = nil, barcodePayloads: [String]? = nil,
        expiresAt: Date? = nil, capturesOnCopy: Bool? = nil, modifiedAt: Date? = nil,
        excludedFromSync: Bool? = nil, syncOnly: Bool? = nil, pendingSyncPayload: SyncPayload? = nil
    ) {
        self.init(
            id: id, storedPayload: payload, date: date, sourceName: sourceName, isFavorite: isFavorite,
            imageSnapshot: imageSnapshot, groupIDs: groupIDs, sourceBundleIdentifier: sourceBundleIdentifier,
            title: title, recognizedText: recognizedText, barcodePayloads: barcodePayloads, expiresAt: expiresAt,
            capturesOnCopy: capturesOnCopy, modifiedAt: modifiedAt, excludedFromSync: excludedFromSync,
            syncOnly: syncOnly, pendingSyncPayload: pendingSyncPayload
        )
    }
}
