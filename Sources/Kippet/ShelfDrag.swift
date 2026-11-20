import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum ShelfDrag {
    nonisolated static let cardType = NSPasteboard.PasteboardType("com.fieai.kippet.local-card-id")
    nonisolated static let pinboardType = "com.fieai.kippet.local-pinboard-id"

    static func pinboardWriter(for id: ClipGroup.ID) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(Data(id.uuidString.utf8), forType: .init(pinboardType))
        return item
    }

    static func receiveID(
        from providers: [NSItemProvider], type: String, perform: @escaping @MainActor @Sendable (UUID) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
            guard let data, let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value)
            else { return }
            Task { @MainActor in perform(id) }
        }
        return true
    }

    static func writers(for clip: Clip) -> [any NSPasteboardWriting] {
        let image = clip.hasPreviewImage ? (try? clip.readPreviewImage()) : nil
        if let image, let type = UTType(image.format), type.conforms(to: .image) {
            return [ImagePromise(clipID: clip.id, data: image.data, type: type)]
        }

        let item = NSPasteboardItem()
        item.setData(Data(clip.id.uuidString.utf8), forType: cardType)
        switch clip.storedPayload {
        case let .text(text, rtf, html):
            item.setString(text, forType: .string)
            if let rtf { item.setData(rtf, forType: .rtf) }
            if let html { item.setData(html, forType: .html) }
        case let .link(url):
            item.setString(url, forType: .string)
            item.setString(url, forType: .URL)
        case let .files(urls):
            return urls.enumerated().map { index, url -> any NSPasteboardWriting in
                if index == 0 { return FileItem(url: url, clipID: clip.id) }
                return url as NSURL
            }
        case .image:
            if let image { item.setData(image.data, forType: NSPasteboard.PasteboardType(image.format)) }
        }
        return [item]
    }

    private final class FileItem: NSObject, NSPasteboardWriting {
        let url: NSURL
        let clipID: Clip.ID

        init(url: URL, clipID: Clip.ID) {
            self.url = url as NSURL
            self.clipID = clipID
        }

        func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
            url.writableTypes(for: pasteboard) + [ShelfDrag.cardType]
        }

        func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
            type == ShelfDrag.cardType ? [] : url.writingOptions(forType: type, pasteboard: pasteboard)
        }

        func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
            type == ShelfDrag.cardType ? Data(clipID.uuidString.utf8) : url.pasteboardPropertyList(forType: type)
        }
    }

    private final class ImagePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
        let clipID: Clip.ID
        let data: Data
        let type: UTType

        init(clipID: Clip.ID, data: Data, type: UTType) {
            self.clipID = clipID
            self.data = data
            self.type = type
            super.init()
            fileType = type.identifier
            delegate = self
        }

        private var imageType: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(type.identifier) }

        override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
            super.writableTypes(for: pasteboard) + [imageType, ShelfDrag.cardType]
        }

        override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
            if type == imageType { return data }
            if type == ShelfDrag.cardType { return Data(clipID.uuidString.utf8) }
            return super.pasteboardPropertyList(forType: type)
        }

        override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
            if type == imageType || type == ShelfDrag.cardType { return .promised }
            return super.writingOptions(forType: type, pasteboard: pasteboard)
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            L("Kippet 图片.%@", type.preferredFilenameExtension ?? "image")
        }

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            Self.exportQueue
        }

        nonisolated func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) {
            do {
                try data.write(to: url, options: .atomic)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }

        private static let exportQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return queue
        }()
    }
}

struct ShelfDragHandle: NSViewRepresentable {
    enum Item {
        case card(Clip)
        case pinboard(ClipGroup.ID)

        var label: String {
            switch self {
            case .card: L("拖出卡片")
            case .pinboard: L("拖动排序钉板")
            }
        }

        var symbol: String {
            switch self {
            case let .card(clip): clip.storedPayload.kind.symbol
            case .pinboard: "folder"
            }
        }

        @MainActor var writers: [any NSPasteboardWriting] {
            switch self {
            case let .card(clip): ShelfDrag.writers(for: clip)
            case let .pinboard(id): [ShelfDrag.pinboardWriter(for: id)]
            }
        }
    }

    let item: Item
    let onDragState: (Bool) -> Void

    func makeNSView(context: Context) -> Region {
        let region = Region()
        region.setAccessibilityLabel(item.label)
        updateNSView(region, context: context)
        return region
    }

    func updateNSView(_ region: Region, context: Context) {
        region.item = item
        region.onDragState = onDragState
    }

    final class Region: NSView, NSDraggingSource {
        var item: Item?
        var onDragState: ((Bool) -> Void)?
        private var dragInProgress = false

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            guard !dragInProgress, let item else { return }
            let position = convert(event.locationInWindow, from: nil)
            let thumbnail = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            let items = item.writers.enumerated().map { index, writer in
                let item = NSDraggingItem(pasteboardWriter: writer)
                let offset = CGFloat(min(index, 3) * 3)
                item.setDraggingFrame(
                    NSRect(x: position.x - 14 + offset, y: position.y - 14 - offset, width: 28, height: 28),
                    contents: thumbnail
                )
                return item
            }
            guard !items.isEmpty else { return }
            dragInProgress = true
            onDragState?(true)
            beginDraggingSession(with: items, event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            if case .pinboard = item, context == .outsideApplication { return [] }
            return .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragInProgress = false
            onDragState?(false)
        }
    }
}
