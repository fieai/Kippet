import Foundation

enum ClipKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case text, link, image, files

    var id: Self { self }

    var label: String {
        switch self {
        case .text: "文字"
        case .link: "链接"
        case .image: "图片"
        case .files: "文件"
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
        case .image: "图片"
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
        case .teal: "青色"
        case .blue: "蓝色"
        case .purple: "紫色"
        case .pink: "粉色"
        case .orange: "橙色"
        case .green: "绿色"
        case .yellow: "黄色"
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
    var payload: ClipPayload
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

    var size: Int { payload.size + (imageSnapshot?.data.count ?? 0) }
    var isSaved: Bool { isFavorite || groupIDs?.isEmpty == false }
    var canSync: Bool { expiresAt == nil && excludedFromSync != true }
    var isSyncSaved: Bool { isSaved && canSync }
    var hasPendingSyncImage: Bool {
        switch pendingSyncPayload {
        case .image: true
        case let .files(_, _, image): image != nil && imageSnapshot == nil
        default: false
        }
    }
    var previewPayload: ClipPayload { imageSnapshot?.payload ?? payload }
    var ocrImageData: Data? {
        guard !hasPendingSyncImage else { return nil }
        guard case let .image(data, _) = previewPayload else { return nil }
        return data
    }

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
