import Foundation
import SQLite3

extension ClipArchive {
    func externalizingImages(_ original: Clip) -> Clip {
        var clip = original
        var pending: [ClipBlobKind: Data] = [:]
        if clip.imageBlob == nil, case let .image(data, format) = clip.storedPayload, !data.isEmpty {
            clip.imageBlob = ClipImageReference(ClipImage(data: data, format: format))
            clip.storedPayload = .image(Data(), format: format)
            pending[.image] = data
        }
        if let snapshot = clip.imageSnapshot {
            clip.snapshotBlob = ClipImageReference(snapshot)
            clip.imageSnapshot = nil
            pending[.snapshot] = snapshot.data
        }
        if !pending.isEmpty {
            for kind in ClipBlobKind.allCases where pending[kind] == nil {
                pending[kind] = clip.blobSource?.staged(kind)
            }
            clip.blobSource = ClipBlobSource(archive: self, pending: pending)
        }
        return clip
    }

    func readBlob(id: Clip.ID, kind: ClipBlobKind, reference: ClipImageReference) throws -> Data {
        try withDatabase(readOnly: true) { db in
            try db.withStatement("SELECT data FROM clip_blobs WHERE id = ? AND kind = ? AND digest = ?") { statement in
                try db.bind(id.uuidString, to: statement, at: 1)
                try db.bind(kind.rawValue, to: statement, at: 2)
                try db.bind(reference.digest.hash, to: statement, at: 3)
                guard try db.nextRow(statement), Int(sqlite3_column_bytes(statement, 0)) == reference.byteCount else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                return try db.data(in: statement)
            }
        }
    }

    func migrateInlineImages(_ db: Database) throws {
        guard try !db.imageMigrationIsFinished() else { return }
        try db.ensureBlobTable()
        try db.transaction {
            guard try !db.imageMigrationIsFinished() else { return }
            let decoder = PropertyListDecoder()
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            // Keep positions stable while walking the old rows and replacing their contents.
            var position = Int64.min
            try db.withStatement("SELECT content, position FROM clips WHERE position > ? ORDER BY position LIMIT 1") {
                statement in
                while try autoreleasepool(invoking: {
                    try db.check(sqlite3_bind_int64(statement, 1, position))
                    guard try db.nextRow(statement) else { return false }
                    let inline = try decoder.decode(Clip.self, from: db.data(in: statement))
                    position = sqlite3_column_int64(statement, 1)
                    try db.check(sqlite3_reset(statement))
                    let clip = externalizingImages(inline)
                    if clip.blobSource != nil {
                        try db.writeBlobs(for: clip)
                        try db.withStatement("UPDATE clips SET content = ? WHERE position = ?") { update in
                            try db.bind(encoder.encode(clip), to: update, at: 1)
                            try db.check(sqlite3_bind_int64(update, 2, position))
                            try db.finishWrite(update)
                        }
                    }
                    return true
                }) {}
            }
            try db.finishImageMigration()
        }
    }
}

extension Database {
    func ensureBlobTable() throws {
        guard try !hasTable("clip_blobs") else { return }
        try execute("""
            CREATE TABLE IF NOT EXISTS clip_blobs (
                id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                digest TEXT NOT NULL,
                data BLOB NOT NULL,
                PRIMARY KEY (id, kind)
            ) WITHOUT ROWID
            """)
    }

    func imageMigrationIsFinished() throws -> Bool {
        try withStatement("SELECT 1 FROM metadata WHERE key = 'inlineImagesV1'") { try nextRow($0) }
    }

    func finishImageMigration() throws {
        try execute("""
            INSERT INTO metadata (key, content) VALUES ('inlineImagesV1', X'01');
            PRAGMA user_version = 2;
            """)
    }

    func writeBlobs(for clip: Clip) throws {
        try withStatement("DELETE FROM clip_blobs WHERE id = ? AND kind = ? AND digest <> ?") { deletion in
            for kind in ClipBlobKind.allCases {
                let reference = kind == .image ? clip.imageBlob : clip.snapshotBlob
                try bind(clip.id.uuidString, to: deletion, at: 1)
                try bind(kind.rawValue, to: deletion, at: 2)
                try bind(reference?.digest.hash ?? "", to: deletion, at: 3)
                try finishWrite(deletion)
                guard let reference else { continue }

                if let data = clip.blobSource?.staged(kind) {
                    try withStatement("""
                        INSERT INTO clip_blobs (id, kind, digest, data) VALUES (?, ?, ?, ?)
                        ON CONFLICT(id, kind) DO NOTHING
                        """) { statement in
                        try bind(clip.id.uuidString, to: statement, at: 1)
                        try bind(kind.rawValue, to: statement, at: 2)
                        try bind(reference.digest.hash, to: statement, at: 3)
                        try bind(data, to: statement, at: 4)
                        try finishWrite(statement)
                    }
                } else {
                    try withStatement("SELECT 1 FROM clip_blobs WHERE id = ? AND kind = ? AND digest = ?") { statement in
                        try bind(clip.id.uuidString, to: statement, at: 1)
                        try bind(kind.rawValue, to: statement, at: 2)
                        try bind(reference.digest.hash, to: statement, at: 3)
                        guard try nextRow(statement) else { throw CocoaError(.fileReadNoSuchFile) }
                    }
                }
            }
        }
    }
}
