import Foundation
import SQLite3

enum HistorySearchIndex {
    static let minimumHistoryCount = 2_000

    // Dropping ASCII punctuation and whitespace broadens the candidate set. Retain rows
    // with other scalars for Foundation's locale-sensitive comparison.
    static func normalized(_ text: String) -> String? {
        var normalized = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x3400...0x4DBF, 0x4E00...0x9FFF:
                normalized.append(scalar)
            case 0x09...0x0D, 0x20...0x7E:
                continue
            default:
                return nil
            }
        }
        return String(normalized)
    }

    static func fields(in clip: Clip) -> [String] {
        [clip.title ?? "", clip.recognizedText ?? "", (clip.barcodePayloads ?? []).joined(separator: " "),
         clip.storedPayload.searchableText, clip.sourceName ?? clip.sourceBundleIdentifier ?? ""]
    }

    static let isAvailable: Bool = {
        guard sqlite3_compileoption_used("ENABLE_FTS5") != 0 else { return false }
        var handle: OpaquePointer?
        let result = sqlite3_open(":memory:", &handle)
        defer { if let handle { sqlite3_close(handle) } }
        guard result == SQLITE_OK, let handle else { return false }
        return sqlite3_exec(
            handle, "CREATE VIRTUAL TABLE probe USING fts5(text, tokenize='trigram')", nil, nil, nil
        ) == SQLITE_OK
    }()
}

extension ClipArchive {
    func searchCandidates(for query: String, historyCount: Int, token: String) -> Set<Clip.ID>? {
        guard historyCount > HistorySearchIndex.minimumHistoryCount, query.count >= 3,
              HistorySearchIndex.isAvailable, let normalized = HistorySearchIndex.normalized(query),
              normalized.count >= 3 else { return nil }
        return try? withDatabase(readOnly: true, busyTimeout: 0) { db in
            try db.transaction("BEGIN") {
                guard try db.searchIndexToken() == token else { return nil }
                return try db.withStatement("""
                    SELECT id FROM clip_search_rows WHERE needs_scan = 1
                    UNION ALL
                    SELECT rows.id FROM clip_search
                    JOIN clip_search_rows AS rows ON rows.slot = clip_search.rowid
                    WHERE clip_search MATCH ? AND rows.needs_scan = 0
                    """) { statement in
                        try db.bind("\"\(normalized)\"", to: statement, at: 1)
                        var candidates: Set<Clip.ID> = []
                        while try db.nextRow(statement) {
                            guard let value = sqlite3_column_text(statement, 0),
                                  let id = UUID(uuidString: String(cString: value)) else {
                                throw ArchiveError.database("Invalid history search ID")
                            }
                            candidates.insert(id)
                        }
                        return candidates
                    }
            }
        }
    }
}

extension Database {
    func prepareSearchIndex() {
        guard HistorySearchIndex.isAvailable, (try? searchIndexIsReady()) == false else { return }
        try? transaction {
            guard try !searchIndexIsReady() else { return }
            try execute("""
                CREATE TABLE IF NOT EXISTS clip_search_rows (
                    slot INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, needs_scan INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS clip_search_needs_scan ON clip_search_rows (needs_scan) WHERE needs_scan = 1;
                CREATE VIRTUAL TABLE IF NOT EXISTS clip_search USING fts5(
                    title, recognized_text, barcode_payloads, searchable_text, source_name, tokenize='trigram'
                );
                DELETE FROM clip_search;
                DELETE FROM clip_search_rows;
                """)
            let decoder = PropertyListDecoder()
            try withStatement("SELECT content FROM clips") { statement in
                while try nextRow(statement) {
                    try autoreleasepool {
                        let clip = try decoder.decode(Clip.self, from: data(in: statement))
                        try index(clip)
                    }
                }
            }
            try setSearchIndexToken(UUID().uuidString)
        }
    }

    func searchIndexIsReady() throws -> Bool {
        try searchIndexToken() != nil
    }

    func searchIndexToken() throws -> String? {
        try withStatement("SELECT content FROM metadata WHERE key = 'clipSearchV1'") { statement in
            guard try nextRow(statement), let token = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: token)
        }
    }

    private func setSearchIndexToken(_ token: String) throws {
        try withStatement("""
            INSERT INTO metadata (key, content) VALUES ('clipSearchV1', ?)
            ON CONFLICT(key) DO UPDATE SET content = excluded.content
            """) { statement in
                try bind(token, to: statement, at: 1)
                try finishWrite(statement)
            }
    }

    func updateSearchIndex(upserting: [Clip], removing: [Clip.ID], token: String) throws {
        guard !upserting.isEmpty || !removing.isEmpty, try searchIndexIsReady() else { return }
        if HistorySearchIndex.isAvailable {
            try execute("SAVEPOINT search_update")
            do {
                for clip in upserting { try index(clip) }
                for id in removing {
                    try removeSearchEntry(id)
                    try withStatement("DELETE FROM clip_search_rows WHERE id = ?") { statement in
                        try bind(id.uuidString, to: statement, at: 1)
                        try finishWrite(statement)
                    }
                }
                try setSearchIndexToken(token)
                try execute("RELEASE search_update")
                return
            } catch {
                try execute("ROLLBACK TO search_update; RELEASE search_update")
            }
        }
        // A later FTS-capable open rebuilds the index from clips.
        try execute("DELETE FROM metadata WHERE key = 'clipSearchV1'")
    }

    private func removeSearchEntry(_ id: Clip.ID) throws {
        try withStatement("DELETE FROM clip_search WHERE rowid = (SELECT slot FROM clip_search_rows WHERE id = ?)") {
            try bind(id.uuidString, to: $0, at: 1)
            try finishWrite($0)
        }
    }

    private func index(_ clip: Clip) throws {
        let fields = HistorySearchIndex.fields(in: clip).map(HistorySearchIndex.normalized)
        try removeSearchEntry(clip.id)
        try withStatement("""
            INSERT INTO clip_search_rows (id, needs_scan) VALUES (?, ?)
            ON CONFLICT(id) DO UPDATE SET needs_scan = excluded.needs_scan
            """) { statement in
                try bind(clip.id.uuidString, to: statement, at: 1)
                try check(sqlite3_bind_int(statement, 2, fields.contains(nil) ? 1 : 0))
                try finishWrite(statement)
            }
        try withStatement("""
            INSERT INTO clip_search (rowid, title, recognized_text, barcode_payloads, searchable_text, source_name)
            SELECT slot, ?, ?, ?, ?, ? FROM clip_search_rows WHERE id = ?
            """) { statement in
                for index in fields.indices {
                    try bind(fields[index] ?? "", to: statement, at: Int32(index + 1))
                }
                try bind(clip.id.uuidString, to: statement, at: 6)
                try finishWrite(statement)
            }
    }
}
