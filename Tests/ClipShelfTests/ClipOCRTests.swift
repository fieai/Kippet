import Foundation
import Testing
@testable import ClipShelf

struct ClipOCRTests {
    @Test func detectsQRCodeAlongsideOCR() async throws {
        let payload = "https://example.com/ClipShelf-Barcode"
        // A real QR PNG with a quiet zone, so the test does not need a graphics renderer.
        let data = try #require(Data(base64Encoded: """
            iVBORw0KGgoAAAANSUhEUgAAALkAAAC5AQAAAABc1qPxAAABXUlEQVR42u2XQW6EMAxF/4hFljlCbgIXQwKJizE3yRFYZoFw
            v52o6pRu40rtsIgSHgsrtv83kJ+fFW/wh8EB4HEMYruw8xQcwSLyrLFsEnTnCWaE57FkPOTUHZI7GLJcccvyKwAozATcgeWj
            piLfE9UZWCXOiaFxuZVoX9CKMPNKhhxuzdkXHJaFRQhmlOlLPhyABjTGTSwzvJJFXIFYVHURNqJ4ghwuUAB4JelbuN1Ba4Mm
            AHyXxA/UdyfKyNDYgyeCH6hRramK7xhdAYuBAQ2CSc6EiVT8AG0WsFRQgcFPPAGXYgGNkZJ7xRWOgGpbwKP2AjuAR0egz4Um
            eMyML1CnU9tRyVW/dQVic12i52lox6vddQbmtVQBtsHahh1H0KYMacVghusGdL7SwWan55nyizP4HC9VD4I3WHLRfKj8J09g
            Hj9D9uq1r8XQG9hkyQ7YYx1rPcH73/mfgQ/cEAKTj1oHjwAAAABJRU5ErkJggg==
            """, options: .ignoreUnknownCharacters))

        let result = await ClipOCR.recognize(data)
        #expect(result.barcodePayloads == [payload])
        #expect(result.text != nil)

        let barcodeOnly = await ClipOCR.recognize(data, text: false)
        #expect(barcodeOnly.barcodePayloads == [payload])
        #expect(barcodeOnly.text == nil)
    }

    @Test func searchesBarcodePayloads() {
        var clip = Clip(id: UUID(), payload: .image(Data(), format: "public.png"), date: .now,
                        recognizedText: "An unrelated OCR result",
                        barcodePayloads: ["other", "https://example.com/ClipShelf-Barcode"])
        let search = HistoryFilter(search: "clipshelf-barcode", contentType: .kind(.image),
                                   favoritesOnly: false, sourceName: nil, groupID: nil,
                                   sourceBundleIdentifier: nil, locale: .current)
        #expect(search.includes(clip))
        clip.barcodePayloads = []
        #expect(!search.includes(clip))
    }

    @Test func unreadableImagesLeaveBothResultsUnprocessed() async {
        let result = await ClipOCR.recognize(Data([0, 1, 2]))
        #expect(result.text == nil)
        #expect(result.barcodePayloads == nil)
    }
}
