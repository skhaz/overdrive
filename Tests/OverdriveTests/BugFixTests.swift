import AppKit
import CoreServices
import Foundation
import SQLite3
import Testing
@testable import Overdrive

struct BugFixTests {
    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }

    @Test func theUpNextPageRedrawsWhenTheQueueChanges() throws {
        let player = try source("Player.swift")

        #expect(player.contains("private(set) var revision = 0"))
        #expect(!player.contains("@ObservationIgnored private(set) var revision"), "the Up Next rows read the queue only when the token changes, so the token itself must be observed, or a shuffle shows an old order and actions reach the wrong song")
    }

    @Test func aRightClickNeverReachesAHiddenTable() throws {
        #expect(try source("Overdrive.swift").contains("table.visibleRect.contains(point), reachable(table, in: content)"), "a hidden page keeps its table, so a right-click must not select rows or take the focus there")
    }
}

struct PlayerRestoreTests {
    private func track(_ name: String) -> Track {
        Track(url: URL(filePath: "/m/\(name).mp3"), title: name, artist: "A", album: "B", number: 1, disc: 1, albumArtist: "", year: 2000, duration: 100, albumID: "B")
    }

    private func lookup(_ names: Set<String>) -> (String) -> Track? {
        { path in
            let name = URL(filePath: path).deletingPathExtension().lastPathComponent
            return names.contains(name) ? track(name) : nil
        }
    }

    @Test func aRepeatedSongRestoresAtItsOwnPosition() {
        let located = Player.located(["/m/A.mp3", "/m/B.mp3", "/m/A.mp3", "/m/C.mp3"], index: 2, lookup(["A", "B", "C"]))

        #expect(located.tracks.map(\.title) == ["A", "B", "A", "C"])
        #expect(located.index == 2, "the second A plays, not the first one")
    }

    @Test func aMissingSongShiftsTheCurrentOne() {
        let located = Player.located(["/m/A.mp3", "/m/X.mp3", "/m/B.mp3"], index: 2, lookup(["A", "B"]))

        #expect(located.tracks.map(\.title) == ["A", "B"])
        #expect(located.index == 1)
        #expect(located.positions == [0, 2], "the added marks follow the songs that stay")
        #expect(Player.located(["/m/A.mp3", "/m/X.mp3"], index: 1, lookup(["A"])).index == nil)
    }

    @Test func theRestoreWaitsForTheWholeLibrary() {
        #expect(Player.waits(found: 0, saved: 3, complete: true), "a drive that is not mounted yet must not drop the saved queue")
        #expect(Player.waits(found: 2, saved: 3, complete: false), "a first snapshot can miss the songs of a folder without a cache")
        #expect(!Player.waits(found: 2, saved: 3, complete: true))
        #expect(!Player.waits(found: 3, saved: 3, complete: false))
    }

    @Test func thePlayerKeepsItsStateRight() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/Player.swift"), encoding: .utf8)
        let stop = source.components(separatedBy: "    private func stop() {").last?.components(separatedBy: "\n    }\n").first ?? ""

        #expect(stop.contains("played = 0") && stop.contains("scrobbled = false") && stop.contains("announced = false"), "the end of the queue must not give the scrobble state of the last song to the first one")
        #expect(stop.contains("save()"))
        #expect(source.contains("guard current != nil else { return play(tracks) }"), "Add to Up Next after the list ends adds to it, it does not replace it")
        #expect(source.contains("guard restored || Player.saved == nil else {"), "nothing writes the session before the saved one is back or the user plays something new")
        #expect(source.contains("if repeatMode != oldValue { Log.player.info(\"repeat\", metadata: [\"mode\": \"\\(repeatMode)\"]); save() }"))
    }
}

@MainActor
@Suite(.serialized)
struct LyricsRaceTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "LyricsRace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func track(_ folder: URL, _ name: String) -> Track {
        Track(url: folder.appending(path: name + ".mp3"), title: name, artist: "A", album: "B", number: 1, disc: 1, albumArtist: "", year: 2000, duration: 100, albumID: "B")
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    @Test func aRefreshNeverLandsOnAnotherSong() async throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let first = track(folder, "First"), second = track(folder, "Second")
        try Data("second kept".utf8).write(to: folder.appending(path: "Second.lyrics"))

        let lyrics = Lyrics()
        lyrics.source = { _ in .success("") }
        lyrics.refresher = { _ in
            try? await Task.sleep(for: .milliseconds(200))
            return .success("first online")
        }
        lyrics.show(first)
        lyrics.refresh()
        lyrics.show(second)
        try await Task.sleep(for: .milliseconds(500))
        Persist.flush()

        #expect(lyrics.text == "second kept", "the lyrics of the first song must not show on the second")
        #expect(!lyrics.remote)
        #expect(read(folder.appending(path: "Second.lyrics")) == "second kept")
    }

    @Test func aRefreshKeepsWhatTheUserTyped() async throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let song = track(folder, "Song")

        let lyrics = Lyrics()
        lyrics.source = { _ in .success("") }
        lyrics.refresher = { _ in .success("online") }
        lyrics.show(song)
        lyrics.edit("typed")
        lyrics.refresh()
        try await Task.sleep(for: .milliseconds(1500))
        lyrics.flush()
        Persist.flush()

        #expect(read(folder.appending(path: "Song.lyrics")) == "typed", "what the user types always wins")
        #expect(lyrics.text == "typed")
    }

    @Test func aBrokenOffsetNeverGivesAnInvalidTime() {
        for tag in ["nan", "inf", "-inf", "1e400"] {
            let lines = LRC.parse("[offset:\(tag)]\n[00:01.00]hello")
            #expect(lines.allSatisfy { $0.time.isFinite }, "offset \(tag) would seek the player to an invalid time")
        }
        #expect(LRC.parse("[offset:500]\n[00:01.00]hello").first?.time == 0.5)
    }

    @Test func aPanelShownAgainStaysShown() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive")
        let panel = try String(contentsOf: root.appending(path: "LyricsPanel.swift"), encoding: .utf8)
        let video = try String(contentsOf: root.appending(path: "YouTube.swift"), encoding: .utf8)

        #expect(panel.contains("guard showing == shown else { return }"), "a quick hide and show must not hide the floating lyrics")
        #expect(video.contains("guard closing == current else { return }"), "a video shown right after Escape must stay open")
    }

    @Test func theDailyLimitWaitsForTheNextDay() {
        let noon = Date(timeIntervalSince1970: 1_700_000_000)
        let next = LastFM.resume(after: noon)
        #expect(next > noon)
        #expect(Int(next.timeIntervalSince1970) % 86400 == 0, "Last.fm counts the limit per UTC day")
        #expect(next.timeIntervalSince(noon) <= 86400)
    }
}

private let bugFixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")

@MainActor
@Suite(.serialized)
struct LibraryBugTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "LibraryBug-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(filePath: url.path.withCString { String(cString: realpath($0, nil)) })
    }

    private func track(_ url: URL) -> Track {
        Track(url: url, title: url.lastPathComponent, artist: "A", album: "B", number: 1, disc: 1, albumArtist: "", year: 2000, duration: 100, albumID: "B")
    }

    @Test func likesAreNotWrittenWhileTheirFolderIsMissing() throws {
        let root = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: root) }
        let drive = root.appending(path: "Volumes/Music")
        let likes = Likes(file: Likes.file(in: drive), folder: drive)

        likes.add([track(drive.appending(path: "a.mp3"))])
        Persist.flush()
        #expect(!FileManager.default.fileExists(atPath: drive.path), "a drive that is not mounted must not get a folder on the boot disk, and its likes must not be replaced")

        let playlists = Playlists(directory: Playlists.directory(in: drive), folder: drive)
        playlists.create("Mix", [drive.appending(path: "a.mp3")])
        Persist.flush()
        #expect(!FileManager.default.fileExists(atPath: drive.path))
    }

    @Test func likesAndPlaylistsReloadAfterEveryScan() throws {
        let views = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/Views.swift"), encoding: .utf8)
        #expect(views.contains("        likes.load()\n        playlists.load()\n        bans.load()\n        navigation.refresh(library.albums)"), "a drive that mounts after launch must bring back its likes, playlists, and denials")
    }

    @Test func aPlaylistFileOnDiskIsNeverOverwrittenByANewOne() throws {
        let root = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: root) }
        let playlists = Playlists(directory: Playlists.directory(in: root), folder: root)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        _ = Persist.write(try encoder.encode(["old.mp3"]), to: Playlists.directory(in: root).appending(path: "Mix.plist"))

        #expect(!playlists.valid("Mix"), "a playlist that is on disk but not loaded yet must not be replaced")
        #expect(!playlists.valid("mix"))
    }

    @Test func likesUseTheRealPathOfTheFolder() throws {
        let root = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: root) }
        let real = root.appending(path: "Real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appending(path: "Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let likes = Likes(file: Likes.file(in: link), folder: link)
        likes.add([track(real.appending(path: "a.mp3"))])
        Persist.flush()

        #expect(Persist.read([String].self, from: Likes.file(in: real)) == ["a.mp3"], "the songs come from the real path, so the likes must be relative to it")
        #expect(Likes(file: Likes.file(in: link), folder: link).contains(track(real.appending(path: "a.mp3"))))
    }

    @Test func theSameFolderIsNeverAddedTwice() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appending(path: "Music")
        let other = root.appending(path: "Other")
        try FileManager.default.createDirectory(at: music.appending(path: "Sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other.appending(path: "Sub"), withIntermediateDirectories: true)
        let link = root.appending(path: "Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: music)

        let library = Library(loudness: Loudness(), folders: [music])
        library.add([link, link.appending(path: "Sub")])
        #expect(library.folders == [music], "a link to a folder is the same folder")

        library.add([other.appending(path: "Sub"), other])
        #expect(library.folders == [music, other], "a folder and its subfolder in one add keep only the parent")
    }

    @Test func aDeletedCacheDropsItsOldJournal() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("junk".utf8).write(to: root.appending(path: Cache.name + "-wal"))
        try Data("junk".utf8).write(to: root.appending(path: Cache.name + "-shm"))

        let cache = try #require(Cache(root))
        #expect(cache.entries().isEmpty)
        #expect((try? Data(contentsOf: root.appending(path: Cache.name + "-wal"))) != Data("junk".utf8), "an old journal must never mix with a new cache")
    }

    @Test func aFailedCacheWriteIsNeverShown() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "A"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bugFixtures.appending(path: "cbr.mp3"), to: root.appending(path: "A/one.mp3"))
        _ = await Library.load([root], [:])

        try FileManager.default.copyItem(at: bugFixtures.appending(path: "vbr.mp3"), to: root.appending(path: "A/two.mp3"))
        var db: OpaquePointer?
        sqlite3_open(root.appending(path: Cache.name).path, &db)
        sqlite3_exec(db, "CREATE TRIGGER fail BEFORE INSERT ON tracks BEGIN SELECT RAISE(ABORT, 'disk full'); END", nil, nil, nil)
        sqlite3_close(db)

        let result = await Library.load([root], [:])
        let shown = Set(result.albums.flatMap(\.tracks).map(\.url.path))
        let stored = Set(Cache(root)!.entries().values.map(\.track.url.path))
        #expect(shown == stored, "the library must show only what the cache has")
        #expect(!shown.contains(root.appending(path: "A/two.mp3").path))
    }

    @Test func aReplacedScanShowsWhatItCommitted() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/Library.swift"), encoding: .utf8)

        #expect(source.contains("guard generation == self.generation else {\n                shownFolders = nil\n                return Log.library.info(\"scan replaced\""), "the next scan must show what a replaced scan committed")
        #expect(source.contains("if !FileManager.default.fileExists(atPath: folder.appending(path: Cache.name).path) { reopen = true }"), "a deleted cache closes the search connections before the rebuild")
    }
}

struct MovedFolderTests {
    @Test func aMovedFolderKeepsEachAlbumWhole() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "Moved-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appending(path: "Old"), new = base.appending(path: "New")
        try FileManager.default.createDirectory(at: old.appending(path: "Album"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bugFixtures.appending(path: "cbr.mp3"), to: old.appending(path: "Album/one.mp3"))
        try FileManager.default.copyItem(at: bugFixtures.appending(path: "vbr.mp3"), to: old.appending(path: "Album/two.mp3"))
        let first = await Library.load([old], [:])
        #expect(first.albums.count == Set(first.albums.flatMap(\.tracks).map(\.album)).count)

        try FileManager.default.moveItem(at: old, to: new)
        let handle = try FileHandle(forWritingTo: new.appending(path: "Album/one.mp3"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 16))
        try handle.close()

        let moved = await Library.load([new], [:])
        let real = Library.real(new)
        for album in moved.albums {
            #expect(album.id.hasPrefix(StoredPath.encode(real)), "an album id follows the folder where the songs are now")
        }
        #expect(moved.albums.count == first.albums.count, "a song read again and a song from the cache stay in one album")

        var db: OpaquePointer?
        sqlite3_open(new.appending(path: Cache.name).path, &db)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM tracks WHERE album_id NOT LIKE ?", -1, &statement, nil)
        sqlite3_bind_text(statement, 1, StoredPath.encode(real) + "%", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(statement)
        #expect(sqlite3_column_int(statement, 0) == 0, "the cache keeps the new album ids, so covers stay with their albums")
        sqlite3_finalize(statement)
    }
}

struct UnreadableSongTests {
    @Test func anUnreadableSongDoesNotWakeTheSyncAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Unreadable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "A"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bugFixtures.appending(path: "cbr.mp3"), to: root.appending(path: "A/good.mp3"))
        try Data(repeating: 7, count: 64).write(to: root.appending(path: "A/broken.mp3"))

        let unreadable = Unreadable()
        let result = await Library.load([root], [:], unreadable: unreadable)
        #expect(result.albums.flatMap(\.tracks).count == 1)

        let stamps = try #require(await Library.stamps([root]))
        #expect(await Library.changed([root], stamps, unreadable: unreadable) == nil, "a song that cannot be read and did not change must not start a scan every 10 minutes")

        try Data(repeating: 8, count: 80).write(to: root.appending(path: "A/broken.mp3"))
        #expect(await Library.changed([root], stamps, unreadable: unreadable) != nil, "a new version of the file is checked again")
    }
}

struct CoverCrashTests {
    private let urls = (0..<10).map { URL(filePath: "/m/\($0)/a.mp3") }

    @Test func recordsSurviveACutStream() {
        var stream = Picture.record(3, Data("abc".utf8)) + Picture.record(5, nil)
        let cut = Picture.record(7, Data("long data".utf8))
        stream += cut.prefix(cut.count - 2)

        let read = Picture.records(stream)
        #expect(read.received == [3, 5], "a record cut by a crash is dropped, the whole ones stay")
        #expect(read.covers[3] == Data("abc".utf8))
        #expect(read.covers[5] == nil)
    }

    @Test func oneBadCoverNeverDropsTheOthers() {
        let bad = 6
        var runs = 0
        let covers = Picture.collect(urls) { batch, workers in
            runs += 1
            var received = Set<Int>(), covers: [Int: Data] = [:]
            for (offset, url) in batch.enumerated() {
                if url == urls[bad] { return (received, covers, false) }
                if workers > 1, offset > 0, batch[offset - 1] == urls[bad] { continue }
                received.insert(offset)
                covers[offset] = Data(url.path.utf8)
            }
            return (received, covers, true)
        }

        for index in urls.indices where index != bad {
            #expect(covers[index] == Data(urls[index].path.utf8), "album \(index) keeps its cover")
        }
        #expect(covers[bad] == nil, "only the album that crashes the reader has no cover")
        #expect(runs <= 4, "a crash costs a few runs, never one run per album")
    }

    @Test func aCleanRunNeedsNoRetry() {
        var runs = 0
        let covers = Picture.collect(urls) { batch, _ in
            runs += 1
            return (Set(batch.indices), Dictionary(uniqueKeysWithValues: batch.indices.map { ($0, Data([UInt8($0)])) }), true)
        }
        #expect(runs == 1)
        #expect(covers.allSatisfy { $0 != nil })
    }
}

struct ShuffleOriginTests {
    @Test func turningShuffleOffGoesBackToTheSameCopy() {
        let order = ["A", "B", "A", "C"]
        let origin = Player.shuffled(order.count, keeping: 2)
        let queue = origin.map { order[$0] }

        #expect(origin.first == 2 && Set(origin) == Set(order.indices))
        #expect(Player.unshuffled(0, origin: origin, queue: queue, order: order) == 2, "the second A plays, so the order goes on from the second A, not the first")
    }

    @Test func withoutOriginTheSameOccurrenceIsUsed() {
        let order = ["A", "B", "A", "C"]
        let queue = ["C", "A", "B", "A"]
        #expect(Player.unshuffled(3, origin: [], queue: queue, order: order) == 2, "the second A in the queue maps to the second A in the order")
        #expect(Player.unshuffled(1, origin: [], queue: queue, order: order) == 0)
        #expect(Player.unshuffled(0, origin: [9, 9, 9, 9], queue: queue, order: order) == 3, "a stale origin falls back")
    }

    @Test func thePlayerKeepsTheOrigin() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/Player.swift"), encoding: .utf8)
        #expect(source.contains("index = Player.unshuffled(index, origin: origin, queue: queue, order: order)"))
        #expect(!source.contains("index = order.firstIndex(of: track) ?? 0"))
    }
}

@MainActor
@Suite(.serialized)
struct ExpiredLyricsTests {
    private func setup() throws -> (URL, Track) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Expired-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let track = Track(url: folder.appending(path: "Song.mp3"), title: "Song", artist: "A", album: "B", number: 1, disc: 1, albumArtist: "", year: 2000, duration: 100, albumID: "B")
        try Data("old".utf8).write(to: Lyrics.key(track))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: Lyrics.key(track).path)
        return (folder, track)
    }

    @Test func anExpiredLyricShowsAtOnceAndIsReplacedWhenANewOneArrives() async throws {
        let (folder, track) = try setup()
        defer { try? FileManager.default.removeItem(at: folder) }

        let lyrics = Lyrics()
        lyrics.source = { _ in
            try? await Task.sleep(for: .milliseconds(200))
            return .success("new")
        }
        lyrics.show(track)
        #expect(lyrics.text == "old", "the old lyric stays on screen while the app looks for a new one")
        #expect(!lyrics.loading)

        try await Task.sleep(for: .milliseconds(500))
        #expect(lyrics.text == "new", "a new lyric replaces the old one on screen")
        #expect(lyrics.remote)
    }

    @Test func aFailedRefreshKeepsTheOldLyric() async throws {
        let (folder, track) = try setup()
        defer { try? FileManager.default.removeItem(at: folder) }

        let lyrics = Lyrics()
        lyrics.source = { _ in .failure(.offline) }
        lyrics.show(track)
        try await Task.sleep(for: .milliseconds(200))
        #expect(lyrics.text == "old")
    }

    @Test func aRefreshNeverReplacesWhatTheUserTypes() async throws {
        let (folder, track) = try setup()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }

        let lyrics = Lyrics()
        lyrics.source = { _ in
            try? await Task.sleep(for: .milliseconds(200))
            return .success("new")
        }
        lyrics.show(track)
        lyrics.edit("typed")
        try await Task.sleep(for: .milliseconds(400))
        #expect(lyrics.text == "typed")
    }
}

@MainActor
struct TagEditTests {
    private func track(_ name: String, title: String, album: String = "B") -> Track {
        Track(url: URL(filePath: "/m/\(name).mp3"), title: title, artist: "A", album: album, number: 1, disc: 1, albumArtist: "", year: 2000, duration: 100, albumID: "/m\n" + album)
    }

    private func png(_ side: Int) -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return image.representation(using: .png, properties: [:])!
    }

    @Test func aTagEditIsAnEdit() {
        let old = ["/m/a.mp3": track("a", title: "Old")]
        #expect(Library.edited(old, [track("a", title: "New")]), "same file, new title")
        #expect(!Library.edited(old, [track("a", title: "Old")]))
        #expect(!Library.edited(old, [track("b", title: "Other")]), "a new song is a membership change, not an edit")
    }

    @Test func theUpNextListTakesTheNewTags() {
        let queue = [track("a", title: "Old"), track("b", title: "Same")]
        let fresh = ["/m/a.mp3": track("a", title: "New"), "/m/b.mp3": track("b", title: "Same")]

        let refreshed = Player.refreshed(queue) { fresh[$0] }
        #expect(refreshed?.map(\.title) == ["New", "Same"], "the song that plays shows its new title")
        #expect(Player.refreshed([track("b", title: "Same")]) { fresh[$0] } == nil, "no change, no update")
        #expect(Player.refreshed([track("gone", title: "X")]) { fresh[$0] } == nil, "a song that left the library stays as it is")
    }

    @Test func aChangedAlbumMakesItsCoverAgain() {
        let albums = [Album(id: "x", title: "X", artist: "A", year: 0, tracks: [track("a", title: "a", album: "X")]), Album(id: "y", title: "Y", artist: "A", year: 0, tracks: [track("b", title: "b", album: "Y")])]
        var asked: [URL] = []
        let result = Library.covers(albums, ["x\u{1F}old": Data([1]), "y\u{1F}same": Data([2])], keys: ["x": "x\u{1F}new", "y": "y\u{1F}same"]) { urls in
            asked = urls
            return urls.map { _ in Data([9]) }
        }

        #expect(asked == [albums[0].tracks[0].url], "only the album whose files changed reads its cover again")
        #expect(result.byID["x"] == Data([9]))
        #expect(result.byID["y"] == Data([2]))
        #expect(result.generated == ["x\u{1F}new": Data([9])])
    }

    @Test func anAlbumWithoutCoverIsNotReadAgainAndAgain() {
        let albums = [Album(id: "x", title: "X", artist: "A", year: 0, tracks: [track("a", title: "a", album: "X")])]
        var runs = 0
        let first = Library.covers(albums, [:], keys: ["x": "x\u{1F}1"]) { urls in runs += 1; return urls.map { _ in nil } }
        #expect(first.generated["x\u{1F}1"] == Data(), "no cover is kept as an empty record")
        let second = Library.covers(albums, first.generated, keys: ["x": "x\u{1F}1"]) { urls in runs += 1; return urls.map { _ in nil } }
        #expect(runs == 1)
        #expect(second.byID["x"] == nil)
    }

    @Test func aNewCoverReplacesTheOneInMemory() {
        let song = track("a", title: "a", album: "Z")
        Artwork.covers = [song.albumID: png(4)]
        #expect(Artwork.image(song)?.size.width == 4)

        Artwork.covers = [song.albumID: png(8)]
        #expect(Artwork.image(song)?.size.width == 8, "the image in memory must follow the new cover")
        Artwork.covers = [:]
    }

    @Test func screensRedrawAfterAnEdit() throws {
        let views = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/Views.swift"), encoding: .utf8)

        #expect(views.contains("SongTable(tracks: library.tracks).id(\"\\(library.query)\\u{1F}\\(library.members)\\u{1F}\\(library.edits)\")"))
        #expect(views.contains(".id(\"\\(route.key)\\u{1F}\\(library.edits)\")"), "an open album shows its new tags and cover")
        #expect(views.components(separatedBy: ".id(\"\\(sort.rawValue)\\u{1F}\\(library.edits)\")").count - 1 == 4, "the queue, playlists, liked songs, and the never-picked list show new tags")
        #expect(views.contains("player.refresh { library.track($0) }"), "the queue takes the new tags after a scan")
    }
}


struct CoverFingerprintTests {
    @Test func theFingerprintFollowsTheFilesOfTheAlbum() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Fingerprint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let song = Track(url: root.appending(path: "one.mp3"), title: "one", artist: "A", album: "B", number: 1, disc: 1, albumArtist: "", year: 0, duration: 1, albumID: "B")
        let album = Album(id: "B", title: "B", artist: "A", year: 0, tracks: [song])
        let stamps = [song.url.path: Cache.Stamp(modified: 1, size: 10)]

        let base = Library.fingerprint(album, stamps)
        #expect(Library.fingerprint(album, stamps) == base, "nothing changed, same fingerprint")
        #expect(Library.fingerprint(album, [song.url.path: Cache.Stamp(modified: 2, size: 10)]) != base, "a new date (new tags or cover in the file) makes a new cover")
        #expect(Library.fingerprint(album, [song.url.path: Cache.Stamp(modified: 1, size: 11)]) != base)

        try Data([1]).write(to: root.appending(path: "notes.txt"))
        #expect(Library.fingerprint(album, stamps) == base, "a text file is not a cover")
        try Data([1, 2, 3]).write(to: root.appending(path: "cover.jpg"))
        let withImage = Library.fingerprint(album, stamps)
        #expect(withImage != base, "a cover image in the folder makes a new cover")
        try Data([1, 2, 3, 4]).write(to: root.appending(path: "cover.jpg"))
        #expect(Library.fingerprint(album, stamps) != withImage, "a changed cover image makes a new cover")
        #expect(Library.coverKey(album, stamps).hasPrefix("B\u{1F}"))
    }

    @Test func theCacheKeepsOnlyTheCurrentCovers() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "CoverKeys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "A"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bugFixtures.appending(path: "cbr.mp3"), to: root.appending(path: "A/one.mp3"))

        _ = await Library.load([root], [:])
        let first = Set(Cache(root)!.covers().keys)
        #expect(first.count == 1 && first.allSatisfy { $0.contains("\u{1F}") }, "each cover is kept with the fingerprint of its album")

        _ = await Library.load([root], [:])
        #expect(Set(Cache(root)!.covers().keys) == first, "nothing changed, the cover stays")

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000_000)], ofItemAtPath: root.appending(path: "A/one.mp3").path)
        _ = await Library.load([root], [:])
        let second = Set(Cache(root)!.covers().keys)
        #expect(second.count == 1 && second != first, "a changed file replaces the cover and drops the old one")
    }

    @Test func coverImagesAndAnHourlyScanKeepTheLibraryInSync() throws {
        let removed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        #expect(Library.relevant([("/m/A/cover.jpg", removed)]), "a new cover image in a music folder starts a scan")
        #expect(Library.relevant([("/m/A/folder.png", removed)]))
        #expect(!Library.relevant([("/m/A/notes.txt", removed)]))
        #expect(!Library.relevant([("/m/Plays.plist", removed)]), "a write of the play counts never starts a scan")

        let source = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/Library.swift"), encoding: .utf8)
        #expect(Library.full == 6, "every hour a full scan runs, also when the quick check sees nothing")
        #expect(source.contains("if ticks.isMultiple(of: Library.full), !scanning {"))
        #expect(source.contains("plays.flush()\n                    scan(\"periodic full\")"), "the hourly tick saves the play counts, then scans; the loved tracks have their own hour in `Loves`")
    }
}
