import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ClipboardStore {
    func attachImage(from url: URL, to id: Clip.ID) async -> Clip? {
        let image = await processImage { Self.readImageFile(url) }
        guard let index = clips.firstIndex(where: { $0.id == id }),
              clips[index].storedPayload.singleImageFile != nil, let image, !Task.isCancelled
        else { return nil }
        var clip = clips[index]
        if (try? clip.readImageSnapshot()) != image {
            clip.recognizedText = nil
            clip.barcodePayloads = nil
        }
        clip.imageSnapshot = image
        clip.snapshotBlob = nil
        clip.pendingSyncPayload = nil
        guard clip.size <= Self.maxPayloadSize else { return nil }
        guard !clip.isSaved || fitsFavorites(clip) else { return nil }
        clip.date = .now
        recordSyncChange(to: &clip, replacing: clips[index])
        clip = archive.externalizingImages(clip)
        clip.contentHash = clip.computeContentHash()
        clips.remove(at: index)
        clips.insert(clip, at: 0)
        save(upserting: [clip], removing: trimHistory())
        queueOCR(clip)
        return clip
    }

    func prewarmImage(_ clip: Clip, for captureID: Clip.ID? = nil) {
        guard let format = clip.previewImageFormat, format != UTType.png.identifier else { return }
        let id = captureID ?? clip.id
        Task(priority: .utility) { [weak self] in
            guard let self, pngTasks.isEmpty, preparedPNGs.object(forKey: id as NSUUID) == nil,
                  !Task.isCancelled, let image = await processImage({ try? clip.readPreviewImage() }) else { return }
            _ = await preparedPNG(for: id, data: image.data)
        }
    }

    func preparedPNG(for id: Clip.ID, data: Data) async -> Data? {
        let key = id as NSUUID
        if let cached = preparedPNGs.object(forKey: key) { return cached.data }
        if let task = pngTasks[id] { return await task.value }
        // A card's non-PNG bytes are immutable. A replacement file is saved as PNG.
        let task = Task {
            await processImage { Self.pngImage(from: data) }
        }
        pngTasks[id] = task
        let png = await task.value
        pngTasks.removeValue(forKey: id)
        preparedPNGs.setObject(PreparedPNG(data: png), forKey: key, cost: png?.count ?? 1)
        return png
    }

    nonisolated func processImage<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            imageQueue.async { continuation.resume(returning: work()) }
        }
    }

    nonisolated static func readImageFile(_ url: URL) -> ClipImage? {
        guard url.isFileURL,
              let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              metadata.isRegularFile == true, let size = metadata.fileSize, (1...maxPayloadSize).contains(size),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxPayloadSize + 1),
              data.count <= maxPayloadSize, let png = pngImage(from: data)
        else { return nil }
        return ClipImage(data: png, format: UTType.png.identifier)
    }

    private nonisolated static func pngImage(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png, .jpeg, .tiff].contains(where: { $0.identifier == type }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height),
              width * height <= 32_000_000
        else { return nil }

        if type == UTType.png.identifier, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete {
            return data
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maxPayloadSize else { return nil }
        return output as Data
    }
}

final class PreparedPNG {
    let data: Data?

    init(data: Data?) { self.data = data }
}
