import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Kippet

@MainActor
struct ShelfDragTests {
    @Test func textDragKeepsRichTextAndPinboardIdentifier() throws {
        let html = Data("<b>example</b>".utf8)
        let clip = Clip(id: UUID(), payload: .text("example", rtf: nil, html: html), date: .now)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(board.writeObjects(ShelfDrag.writers(for: clip)))
        #expect(board.string(forType: .string) == "example")
        #expect(board.data(forType: .html) == html)
        #expect(board.data(forType: ShelfDrag.cardType) == Data(clip.id.uuidString.utf8))
    }

    @Test func fileDragExportsEveryFileAsASeparateItem() {
        let urls = ["file-a.txt", "file-b.txt"].map {
            FileManager.default.temporaryDirectory.appending(path: $0)
        }
        let clip = Clip(id: UUID(), payload: .files(urls), date: .now)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(board.writeObjects(ShelfDrag.writers(for: clip)))
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(files == urls)
        #expect(board.pasteboardItems?.first?.data(forType: ShelfDrag.cardType) == Data(clip.id.uuidString.utf8))
    }

    @Test func imageDragAdvertisesNativeBytesAndAFilePromise() throws {
        let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII="))
        let clip = Clip(id: UUID(), payload: .image(bytes, format: UTType.png.identifier), date: .now)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let provider = try #require(ShelfDrag.writers(for: clip).first as? NSFilePromiseProvider)
        #expect(provider.fileType == UTType.png.identifier)
        #expect(provider.writableTypes(for: board).contains(.png))
        #expect(provider.pasteboardPropertyList(forType: .png) as? Data == bytes)
    }
}
