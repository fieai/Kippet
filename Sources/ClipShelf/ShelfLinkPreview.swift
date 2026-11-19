import ImageIO
import LinkPresentation
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct ShelfLinkPreview: View {
    let url: String

    var body: some View {
        ShelfLinkPreviewContent(url: url)
            .id(url)
    }
}

private struct ShelfLinkPreviewContent: View {
    let url: String
    @State private var model: ShelfLinkPreviewModel

    init(url: String) {
        self.url = url
        _model = State(initialValue: ShelfLinkPreviewModel(rawURL: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let host = model.url?.host {
                Text(host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(verbatim: url)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(url)

            switch model.state {
            case .unavailable:
                EmptyView()
            case .idle:
                Button("加载链接预览") { model.load() }
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载预览…").foregroundStyle(.secondary)
                    Button("取消") { model.cancel() }
                }
                .font(.callout)
            case .failed:
                VStack(alignment: .leading, spacing: 6) {
                    Text("暂时无法加载预览").font(.callout).foregroundStyle(.secondary)
                    Button("重新加载") { model.load() }
                }
            case let .loaded(metadata):
                HStack(alignment: .center, spacing: 12) {
                    if let image = metadata.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 144, maxHeight: 92)
                    }
                    if let title = metadata.title {
                        Text(verbatim: title)
                            .font(.headline)
                            .lineLimit(3)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onDisappear { model.cancel() }
    }
}

struct ShelfLinkMetadata: Sendable {
    let title: String?
    let image: CGImage?

    @MainActor
    static func fetch(url: URL) async throws -> Self {
        try await LinkMetadataRequest().fetch(url: url)
    }
}

@MainActor
final class ShelfLinkPreviewCache {
    static let shared = ShelfLinkPreviewCache()

    private final class Entry {
        let metadata: ShelfLinkMetadata
        init(_ metadata: ShelfLinkMetadata) { self.metadata = metadata }
    }

    private let entries = NSCache<NSURL, Entry>()

    init() {
        entries.countLimit = 32
        entries.totalCostLimit = 8 * 1024 * 1024
    }

    subscript(url: URL) -> ShelfLinkMetadata? {
        get { entries.object(forKey: url as NSURL)?.metadata }
        set {
            guard let newValue else {
                entries.removeObject(forKey: url as NSURL)
                return
            }
            let imageBytes = newValue.image.map { $0.bytesPerRow * $0.height } ?? 0
            let textBytes = newValue.title?.utf8.count ?? 0
            entries.setObject(Entry(newValue), forKey: url as NSURL, cost: imageBytes + textBytes)
        }
    }
}

@MainActor
@Observable
final class ShelfLinkPreviewModel {
    enum State {
        case unavailable, idle, loading, loaded(ShelfLinkMetadata), failed
    }

    let url: URL?
    private(set) var state: State
    @ObservationIgnored private var request: Task<Void, Never>?
    private let cache: ShelfLinkPreviewCache
    private let fetch: @MainActor (URL) async throws -> ShelfLinkMetadata

    init(
        rawURL: String,
        cache: ShelfLinkPreviewCache = .shared,
        fetch: @escaping @MainActor (URL) async throws -> ShelfLinkMetadata = ShelfLinkMetadata.fetch
    ) {
        self.url = Self.previewURL(for: rawURL)
        self.cache = cache
        self.fetch = fetch
        if let url {
            state = cache[url].map(State.loaded) ?? .idle
        } else {
            state = .unavailable
        }
    }

    static func previewURL(for rawURL: String) -> URL? {
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    @discardableResult
    func load() -> Task<Void, Never>? {
        guard let url else { return nil }
        switch state {
        case .idle, .failed: break
        default: return nil
        }
        if let cached = cache[url] {
            state = .loaded(cached)
            return nil
        }
        state = .loading
        let task = Task { [weak self, fetch] in
            guard !Task.isCancelled else { return }
            do {
                let metadata = try await fetch(url)
                guard !Task.isCancelled, let self else { return }
                if metadata.title != nil || metadata.image != nil {
                    cache[url] = metadata
                    state = .loaded(metadata)
                } else {
                    state = .failed
                }
                request = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                state = .failed
                request = nil
            }
        }
        request = task
        return task
    }

    func cancel() {
        guard let request else { return }
        request.cancel()
        self.request = nil
        state = .idle
    }
}

@MainActor
private final class LinkMetadataRequest {
    private let metadataProvider = LPMetadataProvider()
    private var continuation: CheckedContinuation<ShelfLinkMetadata, Error>?
    private var imageProgress: Progress?
    private var imageTimeout: Task<Void, Never>?

    func fetch(url: URL) async throws -> ShelfLinkMetadata {
        metadataProvider.timeout = 8
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                metadataProvider.startFetchingMetadata(for: url) { @Sendable [weak self] metadata, error in
                    guard let metadata else {
                        Task { @MainActor in self?.finish(.failure(error ?? URLError(.badServerResponse))) }
                        return
                    }
                    let cleanedTitle = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = cleanedTitle.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) }
                    let candidates = [metadata.imageProvider, metadata.iconProvider].compactMap { $0 }
                    for candidate in candidates {
                        guard let type = candidate.registeredTypeIdentifiers.first(where: {
                            UTType($0)?.conforms(to: .image) == true
                        }) else { continue }
                        // Start the asset read while LinkPresentation's callback retains its temporary resources.
                        let progress = candidate.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, _ in
                            let image = data.flatMap(Self.thumbnail)
                            Task { @MainActor in self?.finish(.success(ShelfLinkMetadata(title: title, image: image))) }
                        }
                        Task { @MainActor in self?.trackImage(progress, title: title) }
                        return
                    }
                    Task { @MainActor in self?.finish(.success(ShelfLinkMetadata(title: title, image: nil))) }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(.failure(CancellationError()))
                self.metadataProvider.cancel()
            }
        }
    }

    private func trackImage(_ progress: Progress, title: String?) {
        guard continuation != nil else {
            progress.cancel()
            return
        }
        imageProgress = progress
        imageTimeout = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            finish(.success(ShelfLinkMetadata(title: title, image: nil)))
        }
    }

    private func finish(_ result: Result<ShelfLinkMetadata, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        imageTimeout?.cancel()
        imageTimeout = nil
        imageProgress?.cancel()
        imageProgress = nil
        continuation.resume(with: result)
    }

    private nonisolated static func thumbnail(_ data: Data) -> CGImage? {
        guard data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 320
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
    }
}
