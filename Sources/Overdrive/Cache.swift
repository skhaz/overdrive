import Foundation
import Logging
import SQLite3

nonisolated final class Cache {
    static let name = "Cache.sqlite"

    struct Stamp: Equatable, Sendable {
        let modified: Double
        let size: Int
    }

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
    let root: String
    private var db: OpaquePointer?

    init?(_ folder: URL, file: URL? = nil) {
        self.folder = folder
        root = folder.path.withCString { path in realpath(path, nil).map { defer { free($0) }; return String(cString: $0) } } ?? folder.path
        let file = file ?? folder.appending(path: Self.name)
        if !FileManager.default.fileExists(atPath: file.path) {
            for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: file.path + suffix) {
                Log.cache.warning("old journal", metadata: ["file": "\(file.path + suffix)"])
                Persist.remove(URL(filePath: file.path + suffix))
            }
        }

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

    func stamps() -> [String: Stamp] {
        var result: [String: Stamp] = [:]
        query("SELECT path, modified, size FROM tracks") { row in
            result[Self.text(row, 0)] = Stamp(modified: sqlite3_column_double(row, 1), size: Int(sqlite3_column_int64(row, 2)))
        }
        return result
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
            let count = Int(sqlite3_column_bytes(row, 1))
            result[Self.text(row, 0)] = count > 0 ? sqlite3_column_blob(row, 1).map { Data(bytes: $0, count: count) } ?? Data() : Data()
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
    func save(_ changes: [Change], removed: [String], covers: [String: Data], dropping: [String] = [], replacing: Bool = false) -> Bool {
        guard exec("BEGIN IMMEDIATE") else {
            Log.cache.error("begin failed", metadata: ["root": "\(root)", "sqlite": "\(String(cString: sqlite3_errmsg(db)))"])
            return false
        }

        let saved = (!replacing || exec("DELETE FROM covers") && exec("DELETE FROM tracks")) && run("""
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
            && run("DELETE FROM covers WHERE album_id = ?", dropping) { statement, key in Self.bind(statement, 1, key) }

        guard saved, exec("COMMIT") else {
            Log.cache.error("save failed", metadata: ["root": "\(root)", "sqlite": "\(String(cString: sqlite3_errmsg(db)))"])
            exec("ROLLBACK")
            return false
        }

        Log.cache.info("saved", metadata: ["root": "\(root)", "changes": "\(changes.count)", "removed": "\(removed.count)", "covers": "\(covers.count)", "replacing": "\(replacing)"])
        return true
    }

    private func open(_ file: URL) -> Bool {
        sqlite3_close_v2(db)
        db = nil

        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              sqlite3_busy_timeout(db, Int32.max) == SQLITE_OK,
              exec("PRAGMA page_size = 65536; PRAGMA mmap_size = 1073741824; PRAGMA journal_mode = WAL; PRAGMA synchronous = FULL; PRAGMA fullfsync = ON; PRAGMA checkpoint_fullfsync = ON")
        else {
            Log.cache.error("open failed", metadata: ["file": "\(file.path)", "sqlite": "\(db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")"])
            return false
        }

        return exec(Self.schema) || { Log.cache.error("schema failed", metadata: ["file": "\(file.path)", "sqlite": "\(String(cString: sqlite3_errmsg(db)))"]); return false }()
    }

    private static func discard(_ file: URL) -> Bool {
        Log.cache.warning("discard", metadata: ["file": "\(file.path)"])
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
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return Log.cache.error("query failed", metadata: failure(sql))
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in values.enumerated() { Self.bind(statement, Int32(index + 1), value) }
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            row(statement)
            code = sqlite3_step(statement)
        }
        if code != SQLITE_DONE { Log.cache.error("query failed", metadata: failure(sql)) }
    }

    private func run<T>(_ sql: String, _ items: [T], _ bind: (OpaquePointer, T) -> Void) -> Bool {
        guard !items.isEmpty else { return true }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            Log.cache.error("statement failed", metadata: failure(sql))
            return false
        }
        defer { sqlite3_finalize(statement) }

        for (index, item) in items.enumerated() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(statement, item)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                Log.cache.error("statement failed", metadata: failure(sql, index))
                return false
            }
        }

        return true
    }

    private func failure(_ sql: String, _ index: Int? = nil) -> Logging.Logger.Metadata {
        var metadata: Logging.Logger.Metadata = ["root": "\(root)", "sql": "\(sql.prefix(80))", "code": "\(sqlite3_errcode(db))", "sqlite": "\(String(cString: sqlite3_errmsg(db)))"]
        if let index { metadata["index"] = "\(index)" }
        return metadata
    }

    private static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
