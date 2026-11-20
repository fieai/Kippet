import CryptoKit
import Foundation

extension Clip {
    // Match Swift string equality, including canonically equivalent Unicode spellings.
    func computeContentHash() -> String {
        var hasher = SHA256()
        func field(_ bytes: Data?) {
            var length = (bytes.map { UInt64($0.count) } ?? UInt64.max).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            if let bytes { hasher.update(data: bytes) }
        }
        func string(_ value: String) {
            field(Data(value.precomposedStringWithCanonicalMapping.utf8))
        }
        func image(_ digest: SyncBlob, format: String) {
            string(format)
            string(digest.hash)
        }

        string(storedPayload.kind.rawValue)
        switch storedPayload {
        case let .text(text, rtf, html):
            string(text)
            field(rtf)
            field(html)
        case let .link(link):
            string(link)
        case let .image(data, format):
            image(imageBlob?.digest ?? SyncBlob(data), format: format)
        case let .files(urls):
            for url in urls { string(url.absoluteString) }
        }
        // The nil marker separates the end of a file list from a snapshot's fields.
        field(nil)
        if let snapshotBlob {
            image(snapshotBlob.digest, format: snapshotBlob.format)
        } else if let imageSnapshot {
            image(SyncBlob(imageSnapshot.data), format: imageSnapshot.format)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func matchesCapture(_ incoming: Clip) -> Bool {
        guard let contentHash, contentHash == incoming.contentHash else { return false }
        do {
            return try readPayload() == incoming.readPayload() && readImageSnapshot() == incoming.readImageSnapshot()
        } catch {
            return false
        }
    }
}
