import Foundation
import Testing
@testable import Kippet

@MainActor
struct ShelfLinkPreviewTests {
    @Test func validatesExplicitWebLinksWithoutCredentials() {
        for valid in ["https://example.invalid/path?a=1#section", "http://example.invalid"] {
            #expect(ShelfLinkPreviewModel.previewURL(for: valid) != nil)
        }
        for invalid in [
            "file:///tmp/example.html", "javascript:alert(1)", "ftp://example.invalid",
            "https://user@example.invalid", "https://user:secret@example.invalid",
            "https:///relative", "//example.invalid"
        ] {
            #expect(ShelfLinkPreviewModel.previewURL(for: invalid) == nil)
        }
    }

    @Test func loadsOnlyOnRequestAndUsesLocalCacheWhenReopened() async throws {
        let url = "https://example.invalid/page"
        let cache = ShelfLinkPreviewCache()
        var requests = 0
        let fetch: @MainActor (URL) async throws -> ShelfLinkMetadata = { requested in
            #expect(requested.absoluteString == url)
            requests += 1
            return ShelfLinkMetadata(title: "标题", image: nil)
        }
        let model = ShelfLinkPreviewModel(rawURL: url, cache: cache, fetch: fetch)
        #expect(requests == 0)
        let task = try #require(model.load())
        #expect(model.load() == nil)
        await task.value
        #expect(requests == 1)

        let reopened = ShelfLinkPreviewModel(rawURL: url, cache: cache, fetch: fetch)
        guard case let .loaded(metadata) = reopened.state else {
            Issue.record("Local metadata was not reused")
            return
        }
        #expect(metadata.title == "标题")
        #expect(reopened.load() == nil)
        #expect(requests == 1)
    }

    @Test func aCancelledRequestCannotPublishOrCacheMetadata() async throws {
        let url = "https://example.invalid/slow"
        let cache = ShelfLinkPreviewCache()
        let gate = FetchGate()
        let model = ShelfLinkPreviewModel(rawURL: url, cache: cache) { _ in
            await gate.fetch()
        }

        let task = try #require(model.load())
        await gate.waitUntilStarted()
        model.cancel()
        gate.finish()
        await task.value

        guard case .idle = model.state else {
            Issue.record("A cancelled request changed the visible preview")
            return
        }
        let parsed = try #require(model.url)
        #expect(cache[parsed] == nil)
    }

    @MainActor
    private final class FetchGate {
        private var pending: CheckedContinuation<ShelfLinkMetadata, Never>?
        private var started: CheckedContinuation<Void, Never>?

        func fetch() async -> ShelfLinkMetadata {
            await withCheckedContinuation { continuation in
                pending = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if pending != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish() {
            pending?.resume(returning: ShelfLinkMetadata(title: "迟到的预览", image: nil))
            pending = nil
        }
    }
}
