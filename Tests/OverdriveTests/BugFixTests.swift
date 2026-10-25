import Foundation
import SQLite3
import Testing
@testable import Overdrive

struct BugFixTests {
    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }

    @Test func theQueuePageRedrawsWhenTheQueueChanges() throws {
        let player = try source("Player.swift")

        #expect(player.contains("private(set) var revision = 0"))
        #expect(!player.contains("@ObservationIgnored private(set) var revision"), "the Queue rows read the queue only when the token changes, so the token itself must be observed, or a shuffle shows an old order and actions reach the wrong song")
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
        #expect(source.contains("guard current != nil else { return play(tracks) }"), "Add to Queue after the queue ends adds to it, it does not replace it")
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
        #expect(views.contains("private func refreshed() {\n        likes.load()\n        playlists.load()"), "a drive that mounts after launch must bring back its likes and playlists")
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
