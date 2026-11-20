import ImageIO
import SwiftUI

struct ShelfThumbnail: View {
    let clip: Clip
    let maxPixelSize: Int
    var fills = false

    @State private var rendered: Rendered?

    var body: some View {
        let key = ThumbnailKey(clip: clip, maxPixelSize: maxPixelSize)
        Group {
            if clip.hasPendingSyncImage {
                Label("图片尚未同步", systemImage: "photo")
                    .foregroundStyle(.secondary)
            } else if let rendered, rendered.key == key {
                if fills {
                    // Fill mode must never report the image's own size, or the card grows past its slot.
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            Image(decorative: rendered.image, scale: 1)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipped()
                        .transition(.opacity)
                        .accessibilityLabel("剪贴板图片")
                } else {
                    Image(decorative: rendered.image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                        .accessibilityLabel("剪贴板图片")
                }
            } else {
                Label("图片", systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: clip.hasPendingSyncImage ? nil : key, priority: .utility) {
            guard rendered?.key != key, !Task.isCancelled,
                  !clip.hasPendingSyncImage,
                  let image = await ThumbnailRenderer.shared.image(for: key, clip: clip),
                  !Task.isCancelled
            else { return }
            withAnimation(.easeOut(duration: 0.18)) { rendered = Rendered(key: key, image: image) }
        }
        // Offscreen lazy cells should not keep evicted thumbnails alive.
        .onDisappear { rendered = nil }
    }

    private struct Rendered {
        let key: ThumbnailKey
        let image: CGImage
    }
}

private struct ThumbnailKey: Hashable, Sendable {
    let clipID: Clip.ID
    let revisedAt: Date
    let digest: SyncBlob?
    let maxPixelSize: Int

    init(clip: Clip, maxPixelSize: Int) {
        clipID = clip.id
        // The original payload is immutable and repairing a file's image snapshot updates its date.
        revisedAt = clip.date
        digest = (clip.snapshotBlob ?? clip.imageBlob)?.digest
        self.maxPixelSize = maxPixelSize
    }

    var cacheKey: NSString {
        "\(clipID.uuidString)/\(digest?.hash ?? String(revisedAt.timeIntervalSinceReferenceDate.bitPattern))/\(maxPixelSize)" as NSString
    }
}

private actor ThumbnailRenderer {
    static let shared = ThumbnailRenderer()

    private let cache: NSCache<NSString, CachedThumbnail> = {
        let cache = NSCache<NSString, CachedThumbnail>()
        cache.totalCostLimit = 32 * 1_024 * 1_024
        cache.countLimit = 80
        return cache
    }()

    func image(for key: ThumbnailKey, clip: Clip) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let cacheKey = key.cacheKey
        if let cached = cache.object(forKey: cacheKey) { return cached.image }
        guard let original = try? clip.readPreviewImage() else { return nil }

        let image = autoreleasepool {
            Self.decode(original.data, maxPixelSize: key.maxPixelSize)
        }
        cache.setObject(
            CachedThumbnail(image: image), forKey: cacheKey,
            cost: image.map { $0.bytesPerRow * $0.height } ?? 1
        )
        return image
    }

    private static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }

    private final class CachedThumbnail {
        let image: CGImage?

        init(image: CGImage?) {
            self.image = image
        }
    }
}
