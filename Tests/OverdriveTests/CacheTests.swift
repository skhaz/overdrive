import Foundation
import SQLite3
import Testing
@testable import Overdrive

@Suite struct CacheTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OverdriveCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(filePath: url.path.withCString { String(cString: realpath($0, nil)) })
    }

    private func track(_ folder: URL, _ path: String, title: String = "Title", artist: String = "Artist", album: String = "Album") -> Track {
        Track(url: folder.appending(path: path), title: title, artist: artist, album: album, number: 3, disc: 2, albumArtist: "Album Artist", year: 1999, duration: 123.5, albumID: "id-" + album)
    }

    private func change(_ folder: URL, _ path: String, title: String = "Title", artist: String = "Artist", album: String = "Album", modified: Double = 1, size: Int = 10) -> Cache.Change {
        Cache.Change(path: path, modified: modified, size: size, track: track(folder, path, title: title, artist: artist, album: album))
    }

    private func execute(_ file: URL, _ sql: String) {
        var db: OpaquePointer?
        sqlite3_open(file.path, &db)
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
    }

    @Test func roundTripsEveryField() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(Cache(folder)!.save([change(folder, "A/one.mp3", modified: 42.25, size: 999)], removed: [], covers: [:]))

        let entry = try #require(Cache(folder)!.entries()["A/one.mp3"])
        let expected = track(folder, "A/one.mp3")
        #expect(entry.modified == 42.25)
        #expect(entry.size == 999)
        #expect(entry.track.url == expected.url)
        #expect(entry.track.title == expected.title)
        #expect(entry.track.artist == expected.artist)
        #expect(entry.track.album == expected.album)
        #expect(entry.track.number == expected.number)
        #expect(entry.track.disc == expected.disc)
        #expect(entry.track.albumArtist == expected.albumArtist)
        #expect(entry.track.year == expected.year)
        #expect(entry.track.duration == expected.duration)
        #expect(entry.track.albumID == expected.albumID)
    }

    @Test func roundTripsTheHash() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var hashed = change(folder, "one.mp3")
        hashed.hash = Data([1, 2, 3])

        Cache(folder)!.save([hashed, change(folder, "two.mp3")], removed: [], covers: [:])

        let entries = Cache(folder)!.entries()
        #expect(entries["one.mp3"]?.hash == Data([1, 2, 3]))
        #expect(entries["two.mp3"]?.hash == nil)
    }

    @Test func usesTheMeasuredSettings() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = Cache(folder)

        var db: OpaquePointer?
        sqlite3_open(folder.appending(path: Cache.name).path, &db)
        defer { sqlite3_close(db) }
        func value(_ sql: String) -> String {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            sqlite3_step(statement)
            return sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        }

        #expect(value("PRAGMA page_size") == "65536")
        #expect(value("PRAGMA journal_mode") == "wal")
        #expect(value("SELECT sql FROM sqlite_schema WHERE name = 'covers'").contains("WITHOUT ROWID") == false)
        #expect(value("SELECT name FROM sqlite_schema WHERE name = 'tracks_album'") == "tracks_album")
        #expect(value("SELECT sql FROM sqlite_schema WHERE name = 'search'").contains("trigram remove_diacritics 1"))
    }

    @Test func createsTheFileAtTheFolderRoot() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        _ = Cache(folder)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: Cache.name).path))
    }

    @Test func updatesARowAndItsSearchIndex() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = try #require(Cache(folder))

        cache.save([change(folder, "one.mp3", title: "Overkill")], removed: [], covers: [:])
        cache.save([change(folder, "one.mp3", title: "Bomber", modified: 2)], removed: [], covers: [:])

        #expect(cache.entries().count == 1)
        #expect(cache.entries()["one.mp3"]?.track.title == "Bomber")
        #expect(cache.search(["overkill"]).isEmpty)
        #expect(cache.search(["bomber"]) == [folder.path + "/one.mp3"])
    }

    @Test func removesRowsAndTheirSearchIndex() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = try #require(Cache(folder))

        cache.save([change(folder, "one.mp3", title: "Overkill"), change(folder, "two.mp3", title: "Bomber")], removed: [], covers: [:])
        cache.save([], removed: ["one.mp3", "missing.mp3"], covers: [:])

        #expect(Array(cache.entries().keys) == ["two.mp3"])
        #expect(cache.search(["overkill"]).isEmpty)
    }

    @Test func savesAddsChangesAndRemovesTogether() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = try #require(Cache(folder))

        cache.save([change(folder, "old.mp3"), change(folder, "same.mp3")], removed: [], covers: [:])
        cache.save([change(folder, "new.mp3"), change(folder, "same.mp3", title: "Changed", modified: 5)], removed: ["old.mp3"], covers: [:])

        let entries = cache.entries()
        #expect(Set(entries.keys) == ["new.mp3", "same.mp3"])
        #expect(entries["same.mp3"]?.track.title == "Changed")
        #expect(entries["same.mp3"]?.modified == 5)
    }

    @Test func keepsCoversOnlyForAlbumsWithSongs() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = try #require(Cache(folder))

        cache.save([change(folder, "one.mp3", album: "Kept")], removed: [], covers: ["id-Kept": Data([1, 2, 3]), "id-Gone": Data([4])])
        #expect(cache.covers() == ["id-Kept": Data([1, 2, 3])])

        cache.save([], removed: ["one.mp3"], covers: [:])
        #expect(cache.covers().isEmpty)
    }

    @Test func replacesACover() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = try #require(Cache(folder))

        cache.save([change(folder, "one.mp3")], removed: [], covers: ["id-Album": Data([1])])
        cache.save([], removed: [], covers: ["id-Album": Data([2, 2])])

        #expect(cache.covers() == ["id-Album": Data([2, 2])])
    }

    @Test func searchesSubstringsWithoutCaseOrAccents() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = try #require(Cache(folder))

        cache.save([change(folder, "one.mp3", title: "Ace of Spades", artist: "Motörhead")], removed: [], covers: [:])

        #expect(cache.search(["motor"]) == [folder.path + "/one.mp3"])
        #expect(cache.search(["SPADE"]) == [folder.path + "/one.mp3"])
        #expect(cache.search(["örh"]) == [folder.path + "/one.mp3"])
        #expect(cache.search(["queen"]).isEmpty)
    }

    @Test func searchesOnlyWordsWithThreeLetters() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = try #require(Cache(folder))

        cache.save([change(folder, "one.mp3", title: "Ace of Spades")], removed: [], covers: [:])

        #expect(cache.search(["ac"]).isEmpty)
        #expect(cache.search(["ace", "of"]).isEmpty)
        #expect(cache.search([]).isEmpty)
    }

    @Test func needsEveryWordInAnyField() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = try #require(Cache(folder))

        cache.save([change(folder, "one.mp3", title: "Bomber", artist: "Motörhead", album: "Bomber"), change(folder, "two.mp3", title: "Bomber", artist: "Other", album: "Else")], removed: [], covers: [:])

        #expect(cache.search(["bomber", "motor"]) == [folder.path + "/one.mp3"])
        #expect(Set(cache.search(["bomber"])) == [folder.path + "/one.mp3", folder.path + "/two.mp3"])
    }

    @Test func escapesQuotesInWords() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = try #require(Cache(folder))

        cache.save([change(folder, "one.mp3", title: "The \"Best\" Song")], removed: [], covers: [:])

        #expect(cache.search(["\"best\""]) == [folder.path + "/one.mp3"])
        #expect(cache.search(["\"\"\""]).isEmpty)
        #expect(cache.search(["a*b", "(x)"]).isEmpty)
    }

    @Test func keepsPathsOutsideTheFolderAbsolute() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = try #require(Cache(folder))

        #expect(cache.relative(folder.appending(path: "A/one.mp3")) == "A/one.mp3")
        #expect(cache.relative(URL(filePath: "/Elsewhere/two.mp3")) == "/Elsewhere/two.mp3")
        #expect(cache.relative(URL(filePath: folder.path + "Sibling/three.mp3")) == folder.path + "Sibling/three.mp3")

        cache.save([Cache.Change(path: "/Elsewhere/two.mp3", modified: 1, size: 1, track: track(folder, "x", title: "Outside"))], removed: [], covers: [:])
        #expect(cache.entries()["/Elsewhere/two.mp3"]?.track.url == URL(filePath: "/Elsewhere/two.mp3"))
        #expect(cache.search(["outside"]) == ["/Elsewhere/two.mp3"])
    }

    @Test func replacesACorruptFile() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 0xAB, count: 4096).write(to: folder.appending(path: Cache.name))

        let cache = try #require(Cache(folder))
        #expect(cache.entries().isEmpty)
        #expect(cache.save([change(folder, "one.mp3")], removed: [], covers: [:]))
    }

    @Test func ignoresOnlyItsOwnFiles() {
        #expect(Cache.ignored("/Music/Cache.sqlite"))
        #expect(Cache.ignored("/Music/Cache.sqlite-wal"))
        #expect(Cache.ignored("/Music/Cache.sqlite-shm"))
        #expect(!Cache.ignored("/Music/Cache/song.mp3"))
        #expect(!Cache.ignored("/Music/Album/song.mp3"))
    }

    @Test func anotherConnectionSeesCommittedChanges() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = try #require(Cache(folder))
        let writer = try #require(Cache(folder))

        #expect(reader.entries().isEmpty)
        writer.save([change(folder, "one.mp3", title: "Overkill")], removed: [], covers: [:])

        #expect(reader.entries().count == 1)
        #expect(reader.search(["overkill"]) == [folder.path + "/one.mp3"])
    }

    @Test func keepsDataAfterReopen() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        do {
            let cache = try #require(Cache(folder))
            cache.save([change(folder, "one.mp3")], removed: [], covers: ["id-Album": Data([9])])
        }

        let cache = try #require(Cache(folder))
        #expect(cache.entries().count == 1)
        #expect(cache.covers() == ["id-Album": Data([9])])
    }

    @Test func usesAnotherFileWhenGiven() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Other.sqlite")

        Cache(folder, file: file)!.save([change(folder, "one.mp3")], removed: [], covers: [:])

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: Cache.name).path))
        #expect(Cache(folder, file: file)!.entries().count == 1)
    }
}
