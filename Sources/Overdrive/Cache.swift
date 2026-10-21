import Foundation
import SQLite3

nonisolated final class Cache {
    static let name = "Cache.sqlite"

    struct Entry {
        let modified: Double
        let size: Int
        let hash: Data?
        let track: Track
    }

    struct Change {
        let path: String
        let modified: Double
        let size: Int
        var hash: Data?
        let track: Track
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let schema = """
        CREATE TABLE IF NOT EXISTS tracks (
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            modified REAL NOT NULL,
            size INTEGER NOT NULL,
            hash BLOB,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            album TEXT NOT NULL,
            number INTEGER NOT NULL,
            disc INTEGER NOT NULL,
            album_artist TEXT NOT NULL,
            year INTEGER NOT NULL,
            duration REAL NOT NULL,
            album_id TEXT NOT NULL
        ) STRICT;
        CREATE INDEX IF NOT EXISTS tracks_album ON tracks(album_id);
        CREATE TABLE IF NOT EXISTS covers (
            album_id TEXT PRIMARY KEY,
            data BLOB NOT NULL
        ) STRICT;
        CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(
            title, artist, album,
            content = 'tracks', content_rowid = 'id',
            tokenize = 'trigram remove_diacritics 1'
        );
        CREATE TRIGGER IF NOT EXISTS tracks_insert AFTER INSERT ON tracks BEGIN
            INSERT INTO search(rowid, title, artist, album) VALUES (new.id, new.title, new.artist, new.album);
        END;
        CREATE TRIGGER IF NOT EXISTS tracks_delete AFTER DELETE ON tracks BEGIN
            INSERT INTO search(search, rowid, title, artist, album) VALUES ('delete', old.id, old.title, old.artist, old.album);
        END;
        CREATE TRIGGER IF NOT EXISTS tracks_update AFTER UPDATE ON tracks BEGIN
            INSERT INTO search(search, rowid, title, artist, album) VALUES ('delete', old.id, old.title, old.artist, old.album);
            INSERT INTO search(rowid, title, artist, album) VALUES (new.id, new.title, new.artist, new.album);
        END;
        """

    let folder: URL
    private let root: String
    private var db: OpaquePointer?

    init?(_ folder: URL, file: URL? = nil) {
        self.folder = folder
        root = folder.path.withCString { path in realpath(path, nil).map { defer { free($0) }; return String(cString: $0) } } ?? folder.path
        let file = file ?? folder.appending(path: Self.name)

        guard open(file) || (Self.discard(file) && open(file)) else { return nil }
    }

    deinit {
        sqlite3_close_v2(db)
    }

    nonisolated static func ignored(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix(name)
    }

    func relative(_ url: URL) -> String {
        for base in [root, folder.path] where url.path.hasPrefix(base + "/") {
            return String(url.path.dropFirst(base.count + 1))
        }
        return url.path
    }

    func entries() -> [String: Entry] {
        var result: [String: Entry] = [:]

        query("SELECT path, modified, size, title, artist, album, number, disc, album_artist, year, duration, album_id, hash FROM tracks") { row in
            let path = Self.text(row, 0)
            let url = URL(filePath: path.hasPrefix("/") ? path : root + "/" + path)
            let track = Track(
                url: url,
                title: Self.text(row, 3),
                artist: Self.text(row, 4),
                album: Self.text(row, 5),
                number: Int(sqlite3_column_int64(row, 6)),
                disc: Int(sqlite3_column_int64(row, 7)),
                albumArtist: Self.text(row, 8),
                year: Int(sqlite3_column_int64(row, 9)),
                duration: sqlite3_column_double(row, 10),
                albumID: Self.text(row, 11)
            )
            let hash = sqlite3_column_blob(row, 12).map { Data(bytes: $0, count: Int(sqlite3_column_bytes(row, 12))) }
            result[path] = Entry(modified: sqlite3_column_double(row, 1), size: Int(sqlite3_column_int64(row, 2)), hash: hash, track: track)
        }

        return result
    }

    func covers() -> [String: Data] {
        var result: [String: Data] = [:]

        query("SELECT album_id, data FROM covers") { row in
            guard let bytes = sqlite3_column_blob(row, 1) else { return }

            result[Self.text(row, 0)] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, 1)))
        }

        return result
    }

    func search(_ words: [String]) -> [String] {
        guard !words.isEmpty, words.allSatisfy({ $0.count >= 3 }) else { return [] }

        let pattern = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
        var result: [String] = []

        query("SELECT tracks.path FROM search JOIN tracks ON tracks.id = search.rowid WHERE search MATCH ? ORDER BY rank", [pattern]) { row in
            let path = Self.text(row, 0)
            result.append(path.hasPrefix("/") ? path : root + "/" + path)
        }

        return result
    }

    @discardableResult
    func save(_ changes: [Change], removed: [String], covers: [String: Data]) -> Bool {
        guard exec("BEGIN IMMEDIATE") else { return false }

        let saved = run("""
            INSERT INTO tracks (path, modified, size, title, artist, album, number, disc, album_artist, year, duration, album_id, hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                modified = excluded.modified, size = excluded.size, hash = excluded.hash, title = excluded.title, artist = excluded.artist,
                album = excluded.album, number = excluded.number, disc = excluded.disc, album_artist = excluded.album_artist,
                year = excluded.year, duration = excluded.duration, album_id = excluded.album_id
            """, changes) { statement, change in
                let track = change.track
                Self.bind(statement, 1, change.path)
                sqlite3_bind_double(statement, 2, change.modified)
                sqlite3_bind_int64(statement, 3, Int64(change.size))
                Self.bind(statement, 4, track.title)
                Self.bind(statement, 5, track.artist)
                Self.bind(statement, 6, track.album)
                sqlite3_bind_int64(statement, 7, Int64(track.number))
                sqlite3_bind_int64(statement, 8, Int64(track.disc))
                Self.bind(statement, 9, track.albumArtist)
                sqlite3_bind_int64(statement, 10, Int64(track.year))
                sqlite3_bind_double(statement, 11, track.duration)
                Self.bind(statement, 12, track.albumID)
                if let hash = change.hash {
                    _ = hash.withUnsafeBytes { sqlite3_bind_blob(statement, 13, $0.baseAddress, Int32($0.count), Self.transient) }
                }
            }
            && run("DELETE FROM tracks WHERE path = ?", removed) { statement, path in Self.bind(statement, 1, path) }
            && run("INSERT INTO covers (album_id, data) VALUES (?, ?) ON CONFLICT(album_id) DO UPDATE SET data = excluded.data", Array(covers)) { statement, cover in
                Self.bind(statement, 1, cover.key)
                _ = cover.value.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), Self.transient) }
            }
            && exec("DELETE FROM covers WHERE album_id NOT IN (SELECT album_id FROM tracks)")

        guard saved, exec("COMMIT") else {
            exec("ROLLBACK")
            return false
        }

        return true
    }

    private func open(_ file: URL) -> Bool {
        sqlite3_close_v2(db)
        db = nil

        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              sqlite3_busy_timeout(db, Int32.max) == SQLITE_OK,
              exec("PRAGMA page_size = 16384; PRAGMA mmap_size = 268435456; PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA fullfsync = ON; PRAGMA checkpoint_fullfsync = ON")
        else { return false }

        return exec(Self.schema)
    }

    private static func discard(_ file: URL) -> Bool {
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(filePath: file.path + suffix)
            if FileManager.default.fileExists(atPath: url.path), !Persist.remove(url) { return false }
        }
        return true
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func query(_ sql: String, _ values: [String] = [], _ row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }

        for (index, value) in values.enumerated() { Self.bind(statement, Int32(index + 1), value) }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private func run<T>(_ sql: String, _ items: [T], _ bind: (OpaquePointer, T) -> Void) -> Bool {
        guard !items.isEmpty else { return true }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }

        for item in items {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(statement, item)
            guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        }

        return true
    }

    private static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
