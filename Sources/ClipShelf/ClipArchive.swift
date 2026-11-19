import Foundation
import SQLite3

struct ClipArchive: Sendable {
    static let live = Self(legacyURL: URL.applicationSupportDirectory
        .appending(path: "ClipShelf", directoryHint: .isDirectory)
        .appending(path: "History.plist"))

    private let legacyURL: URL
    private let databaseURL: URL

    init(legacyURL: URL) {
        self.legacyURL = legacyURL
        databaseURL = legacyURL.deletingPathExtension().appendingPathExtension("sqlite3")
    }

    func load(readOnly: Bool = false) throws -> (clips: [Clip], groups: [ClipGroup]) {
        if readOnly, !FileManager.default.fileExists(atPath: databaseURL.path) { return ([], []) }
        let library = try loadLibrary(readOnly: readOnly)
        return (library.clips, library.groups)
    }

    func loadLibrary(readOnly: Bool = false) throws -> (clips: [Clip], groups: [ClipGroup], tombstones: [SyncTombstone]) {
        try withDatabase(readOnly: readOnly) { db in
            try db.transaction("BEGIN") {
                let decoder = PropertyListDecoder()
                let clips = try db.withStatement("SELECT content FROM clips ORDER BY position DESC") { statement in
                    var clips: [Clip] = []
                    while try db.nextRow(statement) {
                        clips.append(try decoder.decode(Clip.self, from: db.data(in: statement)))
                    }
                    return clips
                }
                let groups = try db.withStatement("SELECT content FROM metadata WHERE key = 'groups'") { statement in
                    guard try db.nextRow(statement) else { return [ClipGroup]() }
                    return try decoder.decode([ClipGroup].self, from: db.data(in: statement))
                }
                let tombstones = try db.withStatement("SELECT content FROM metadata WHERE key = 'syncTombstones'") {
                    statement in
                    guard try db.nextRow(statement) else { return [SyncTombstone]() }
                    return try decoder.decode([SyncTombstone].self, from: db.data(in: statement))
                }
                return (clips, groups, tombstones)
            }
        }
    }

    // Supply newest clips first when inserting or moving more than one.
    func write(
        upserting: [Clip], removing: [Clip.ID], groups: [ClipGroup]? = nil, order: [Clip.ID]? = nil,
        tombstones: [SyncTombstone]? = nil
    ) throws {
        guard !upserting.isEmpty || !removing.isEmpty || groups != nil || tombstones != nil else { return }
        try withDatabase { db in
            try db.transaction {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try db.upsert(upserting, encoder: encoder)
                if !removing.isEmpty {
                    try db.withStatement("DELETE FROM clips WHERE id = ?") { statement in
                        for id in removing {
                            try db.check(sqlite3_bind_text(statement, 1, id.uuidString, -1, Database.transient))
                            try db.finishWrite(statement)
                        }
                    }
                }
                if let order { try db.restoreOrder(order) }
                if let groups {
                    try db.withStatement("""
                        INSERT INTO metadata (key, content) VALUES ('groups', ?)
                        ON CONFLICT(key) DO UPDATE SET content = excluded.content
                        """) { statement in
                        try db.bind(encoder.encode(groups), to: statement, at: 1)
                        try db.finishWrite(statement)
                    }
                }
                if let tombstones {
                    try db.withStatement("""
                        INSERT INTO metadata (key, content) VALUES ('syncTombstones', ?)
                        ON CONFLICT(key) DO UPDATE SET content = excluded.content
                        """) { statement in
                        try db.bind(encoder.encode(tombstones), to: statement, at: 1)
                        try db.finishWrite(statement)
                    }
                }
            }
        }
    }

    private func withDatabase<T>(readOnly: Bool = false, _ body: (Database) throws -> T) throws -> T {
        if !readOnly {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        var handle: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        defer { if let handle { sqlite3_close(handle) } }
        guard result == SQLITE_OK, let handle else {
            throw ArchiveError.database(String(cString: sqlite3_errstr(result)))
        }
        let db = Database(handle: handle)
        try db.check(sqlite3_busy_timeout(handle, 2_000))
        let version = try db.schemaVersion()
        if version != 1 {
            if readOnly { throw ArchiveError.unsupportedVersion(version) }
            try migrate(db)
        }
        return try body(db)
    }

    private func migrate(_ db: Database) throws {
        try db.transaction {
            switch try db.schemaVersion() {
            case 1: return // Another connection already migrated the archive.
            case 0: break
            case let version: throw ArchiveError.unsupportedVersion(version)
            }
            let clips: [Clip]
            do {
                clips = try PropertyListDecoder().decode([Clip].self, from: Data(contentsOf: legacyURL))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                clips = []
            }
            try db.execute("""
                CREATE TABLE clips (
                    position INTEGER PRIMARY KEY,
                    id TEXT NOT NULL UNIQUE,
                    date REAL NOT NULL,
                    content BLOB NOT NULL
                );
                CREATE TABLE metadata (key TEXT NOT NULL PRIMARY KEY, content BLOB NOT NULL);
                """)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try db.upsert(clips, encoder: encoder)
            try db.execute("PRAGMA user_version = 1")
        }
    }
}

private enum ArchiveError: Error {
    case database(String)
    case unsupportedVersion(Int32)
}

private struct Database {
    let handle: OpaquePointer
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func schemaVersion() throws -> Int32 {
        try withStatement("PRAGMA user_version") { statement in
            guard try nextRow(statement) else { throw error }
            return sqlite3_column_int(statement, 0)
        }
    }

    func upsert(_ clips: [Clip], encoder: PropertyListEncoder) throws {
        guard !clips.isEmpty else { return }
        try withStatement("""
            INSERT INTO clips (id, date, content) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                position = CASE WHEN clips.date <> excluded.date THEN excluded.position ELSE clips.position END,
                date = excluded.date,
                content = excluded.content
            """) { statement in
            for clip in clips.reversed() {
                try check(sqlite3_bind_text(statement, 1, clip.id.uuidString, -1, Self.transient))
                try check(sqlite3_bind_double(statement, 2, clip.date.timeIntervalSinceReferenceDate))
                try bind(encoder.encode(clip), to: statement, at: 3)
                try finishWrite(statement)
            }
        }
    }

    func restoreOrder(_ ids: [Clip.ID]) throws {
        let requested = ids.map(\.uuidString)
        let known = Set(requested)
        var currentPositions: [String: Int64] = [:]
        var positions: [Int64] = []
        try withStatement("SELECT id, position FROM clips ORDER BY position DESC") { statement in
            while try nextRow(statement) {
                guard let value = sqlite3_column_text(statement, 0) else { throw error }
                let id = String(cString: value)
                guard known.contains(id) else { continue }
                let position = sqlite3_column_int64(statement, 1)
                currentPositions[id] = position
                positions.append(position)
            }
        }
        let present = requested.filter { currentPositions[$0] != nil }
        let moved = zip(present, positions).filter { currentPositions[$0.0] != $0.1 }
        guard !moved.isEmpty else { return }
        try withStatement("UPDATE clips SET position = ? WHERE id = ?") { statement in
            // Positions are positive. Stage moved rows at negative positions to free their slots.
            for sign: Int64 in [-1, 1] {
                for (id, position) in moved {
                    try check(sqlite3_bind_int64(statement, 1, position * sign))
                    try check(sqlite3_bind_text(statement, 2, id, -1, Self.transient))
                    try finishWrite(statement)
                }
            }
        }
    }

    func transaction<T>(_ begin: String = "BEGIN IMMEDIATE", _ body: () throws -> T) throws -> T {
        try execute(begin)
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        guard let statement else { throw error }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    func bind(_ data: Data, to statement: OpaquePointer, at index: Int32) throws {
        try data.withUnsafeBytes { bytes in
            try check(sqlite3_bind_blob64(statement, index, bytes.baseAddress, UInt64(bytes.count), Self.transient))
        }
    }

    func data(in statement: OpaquePointer) throws -> Data {
        guard let bytes = sqlite3_column_blob(statement, 0) else { throw error }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    }

    func nextRow(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw error
        }
    }

    func finishWrite(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error }
        try check(sqlite3_reset(statement))
    }

    func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw error }
    }

    private var error: ArchiveError {
        .database(String(cString: sqlite3_errmsg(handle)))
    }
}
