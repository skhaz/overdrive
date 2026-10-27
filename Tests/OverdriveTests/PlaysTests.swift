import Foundation
import Testing
@testable import Overdrive

@MainActor
@Suite(.serialized)
struct PlaysTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OverdrivePlays-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(filePath: url.path.withCString { String(cString: realpath($0, nil)) })
    }

    private func track(_ path: String, _ album: String = "Album", _ artist: String = "Artist") -> Track {
        Track(url: URL(fileURLWithPath: path), title: URL(fileURLWithPath: path).lastPathComponent, artist: artist, album: album, number: 1, disc: 1, albumArtist: "", year: 2000, duration: 100, albumID: "x")
    }

    @Test func theKeyCarriesNoPath() {
        let key = Plays.key(track("/a/b/One.mp3", "Album", "Artist"))

        #expect(key == "One.mp3\u{1F}Album\u{1F}Artist")
        #expect(!key.contains("/a/b"), "the key never holds a path, so the library can move")
        #expect(Plays.key(track("/elsewhere/One.mp3", "Album", "Artist")) == key, "the same song in another folder is the same song")
        #expect(Plays.key(track("/a/b/One.mp3", "Other", "Artist")) != key, "another album is another song")
        #expect(Plays.key(track("/a/b/One.mp3", "Album", "Someone Else")) != key, "another artist is another song")
        #expect(Plays.key(track("/a/b/One.mp3", "Album", "Artist")) != Plays.key(track("/a/b/One.mp3", "Album Artist", "")), "the parts stay separate")
    }

    @Test func theFileIsInTheLibraryFolder() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(Plays.file(in: root).lastPathComponent == "Plays.plist")
        #expect(Plays.file(in: root).path == root.path + "/Plays.plist", "the file sits at the root of the folder, with the likes and the playlists")
        #expect(Plays.file(in: nil).path.hasSuffix("Music/Library/Plays.plist"))
    }

    @Test func aNewSongCountsOncePerPlay() {
        let song = track("/m/One.mp3")
        let plays = Plays(root: nil)

        #expect(plays.count(song) == 0, "a song you have not played shows zero")
        let revision = plays.revision
        plays.bump(song)
        #expect(plays.count(song) == 1)
        plays.bump(song)
        plays.bump(song)
        #expect(plays.count(song) == 3)
        #expect(plays.revision > revision, "a new count is a new state for the lists")
        #expect(plays.played(Plays.key(song)))
    }

    @Test func onlyTheFirstPlayFlipsASong() {
        var flipped: [String] = []
        let song = track("/m/One.mp3")
        let plays = Plays(root: nil)
        plays.flipped = { flipped.append($0.url.path) }

        plays.bump(song)
        plays.bump(song)
        plays.bump(track("/m/Two.mp3"))

        #expect(flipped == ["/m/One.mp3", "/m/Two.mp3"], "a flip is what moves the never-played count")
    }

    @Test func theCountsAreInTheMemoryBeforeTheDisk() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }

        let plays = Plays(root: root)
        plays.bump(track("/m/One.mp3"))
        Persist.flush()

        #expect(plays.count(track("/m/One.mp3")) == 1, "the memory holds the count at once")
        #expect(Persist.read([String: Int].self, from: Plays.file(in: root)) == nil, "nothing is on the disk before a sync")
        #expect(!FileManager.default.fileExists(atPath: Plays.file(in: root).path), "a sync writes the file, not every play")

        plays.flush()
        Persist.flush()
        #expect(Persist.read([String: Int].self, from: Plays.file(in: root)) == ["One.mp3\u{1F}Album\u{1F}Artist": 1], "the file is one dictionary of key to count")
    }

    @Test func aSyncKeepsWhatIsAlreadySaved() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }

        let song = track("/m/One.mp3")
        let plays = Plays(root: root)
        plays.bump(song)
        plays.flush()
        plays.bump(song)
        plays.bump(song)
        plays.flush()
        Persist.flush()

        #expect(Persist.read([String: Int].self, from: Plays.file(in: root))?.values.first == 3, "a later sync adds to the saved count, it never replaces it")

        let again = Plays(root: root)
        #expect(again.count(song) == 3, "the counts come back from the file")
    }

    @Test func countsSurviveAFolderMove() throws {
        let root = try folder()
        let moved = root.deletingLastPathComponent().appending(path: "OverdrivePlaysMoved-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: moved) }

        let song = track("/anything/One.mp3")
        let plays = Plays(root: root)
        plays.bump(song)
        plays.bump(song)
        plays.flush()
        Persist.flush()

        try FileManager.default.moveItem(at: root, to: moved)
        let after = Plays(root: moved)

        #expect(after.count(song) == 2, "the folder moved with the music, and the counts moved with it")
        #expect(after.played(Plays.key(song)))
    }

    @Test func nothingIsWrittenWhileTheFolderIsMissing() throws {
        let missing = URL(fileURLWithPath: "/tmp/overdrive-missing-\(UUID().uuidString)")
        let records = logRecords
        let plays = Plays(root: missing)
        Persist.flush()

        #expect(!FileManager.default.fileExists(atPath: Plays.file(in: missing).path), "a folder that is not mounted gets no file")
        #expect(!records.find("persist", "read failed", "path", Plays.file(in: missing).path), "a missing file is normal")

        plays.bump(track("/m/One.mp3"))
        plays.flush()
        Persist.flush()
        #expect(!FileManager.default.fileExists(atPath: Plays.file(in: missing).path), "the count stays in memory until the folder is there")
        #expect(plays.count(track("/m/One.mp3")) == 1, "the screen still shows the count")
    }

    @Test func aDriveThatMountsLaterBringsTheCountsBack() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }

        let song = track("/m/One.mp3")
        let saved = Plays(root: root)
        saved.bump(song)
        saved.bump(song)
        saved.flush()
        Persist.flush()

        let plays = Plays(root: nil)
        #expect(plays.missing, "no folder means no file")
        #expect(plays.count(song) == 0)

        plays.rebind(root)
        #expect(!plays.missing)
        #expect(plays.count(song) == 2)
    }

    @Test func aReloadKeepsTheCountsThatAreNotSavedYet() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }

        let song = track("/m/One.mp3")
        let plays = Plays(root: root)
        plays.bump(song)
        plays.load()

        #expect(plays.count(song) == 1, "a reload writes what is pending first")
        Persist.flush()
        #expect(Persist.read([String: Int].self, from: Plays.file(in: root))?.values.first == 1)
    }

    @Test func countsThatNeverReachedTheDiskTravelWithTheFolder() throws {
        let root = try folder()
        let moved = root.deletingLastPathComponent().appending(path: "OverdrivePlaysMoved-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: moved) }

        let song = track("/anything/One.mp3")
        let plays = Plays(root: root)
        plays.bump(song)
        plays.bump(song)
        Persist.flush()

        try FileManager.default.moveItem(at: root, to: moved)
        plays.rebind(moved)

        #expect(plays.count(song) == 2, "the plays of a folder that moved are not lost")
        plays.flush()
        Persist.flush()
        #expect(Persist.read([String: Int].self, from: Plays.file(in: moved))?.values.first == 2, "they land in the file of the new folder")
        #expect(!FileManager.default.fileExists(atPath: root.path), "a sync that cannot write never recreates the old folder")
    }

    @Test func aBrokenFileIsReportedNotHidden() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a plist".utf8).write(to: Plays.file(in: root))

        let records = logRecords
        let plays = Plays(root: root)

        #expect(plays.count(track("/m/One.mp3")) == 0, "a file that cannot be read starts empty")
        #expect(records.find("persist", "decode failed"), "a broken data file must leave a trace before the app replaces it")
    }

    @Test func mergedCountsAddUp() {
        #expect(Plays.merged(["a": 2, "b": 1], ["a": 1, "c": 3]) == ["a": 3, "b": 1, "c": 3])
        #expect(Plays.merged([:], ["a": 1]) == ["a": 1])
        #expect(Plays.merged(["a": 1], [:]) == ["a": 1])
    }

    @Test func theSaveIsAtomicAndDurable() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }

        let plays = Plays(root: root)
        for number in 0..<500 { plays.bump(track("/m/Song \(number).mp3")) }
        plays.flush()
        Persist.flush()

        let file = Plays.file(in: root)
        let saved = try #require(Persist.read([String: Int].self, from: file))
        #expect(saved.count == 500)
        #expect(saved.values.allSatisfy { $0 == 1 })
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("tmp").path), "the temporary file is renamed, never left behind")
    }
}
