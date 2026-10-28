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

    private func ranks(_ counts: [(String, Int)]) -> [Plays.Rank] {
        counts.map { Plays.Rank(key: $0.0, count: $0.1) }
    }

    @Test func aPlayCountsAtEightyPercentOfTheSong() {
        #expect(Player.counts(80, 100), "80% of a song is a play")
        #expect(Player.counts(240, 300))
        #expect(Player.counts(79, 100) == false, "a song left at three quarters is not a play")
        #expect(Player.counts(0, 0) == false, "a song without a stated length counts at its end, not before")
        #expect(Player.counts(0, 100) == false)
    }

    @Test func theBestPlayedPickGoesDownTheOrder() {
        let best = Plays.top(ranks([("a", 9), ("b", 5), ("c", 5), ("d", 1)]), 3) { _ in true }

        #expect(best.first == "a", "the most played song comes first")
        #expect(Set(best) == ["a", "b", "c"])
        #expect(Plays.top(ranks([("a", 9), ("b", 5)]), 5) { _ in true } == ["a", "b"], "fewer songs than asked for gives what there is")
        #expect(Plays.top(ranks([("a", 9)]), 0) { _ in true }.isEmpty, "nothing asked for, nothing picked")
    }

    @Test func theBestPlayedPickDrawsAtRandomInsideTheLastGroup() {
        let tied = (0..<40).map { ("song\($0)", 7) }
        var picks: Set<Set<String>> = []
        for _ in 0..<40 { picks.insert(Set(Plays.top(ranks(tied), 10) { _ in true })) }

        #expect(picks.count > 1, "the group that fills the pick is drawn at random, not cut at its head")
        #expect(picks.allSatisfy { $0.isSubset(of: Set(tied.map(\.0))) && $0.count == 10 })
    }

    @Test func theBestPlayedPickSkipsWhatTheCallerRejects() {
        let keys = Plays.top(ranks([("gone", 99), ("a", 9), ("b", 8)]), 2) { $0 != "gone" }

        #expect(keys == ["a", "b"], "a song the library does not have takes no place in the pick")
    }

    @Test func theBestPlayedPickWalksOnlyWhatItNeeds() {
        let many = (0..<50_000).map { ("song\($0)", 50_000 - $0) }
        var seen = 0
        let keys = Plays.top(many.map { Plays.Rank(key: $0.0, count: $0.1) }, 10) { key in
            seen += 1
            return true
        }

        #expect(keys.count == 10)
        #expect(seen == 10, "the pick costs O(pick), not the size of the play order")
    }

    @Test func oneMorePlayMovesTheSongUpTheOrder() {
        var order = ranks([("top", 9), ("mid", 5), ("other", 5), ("low", 1)])
        var slots = Dictionary(order.enumerated().map { ($0.element.key, $0.offset) }) { first, _ in first }

        Plays.sift(&order, &slots, 3)
        #expect(order.map(\.count) == [9, 5, 5, 2], "a song that passes nobody stays where it is")
        #expect(order.map(\.key) == ["top", "mid", "other", "low"])
        #expect(slots["low"] == 3)

        Plays.sift(&order, &slots, 1)
        #expect(order.map(\.count) == [9, 6, 5, 2], "a song that reaches the count above it passes nobody")
        #expect(order.map(\.key) == ["top", "mid", "other", "low"])

        Plays.sift(&order, &slots, 2)
        #expect(order.map(\.count) == [9, 6, 6, 2], "a tie keeps its place")
        #expect(order.map(\.key) == ["top", "mid", "other", "low"])

        for (slot, rank) in order.enumerated() { #expect(slots[rank.key] == slot, "every place stays true") }
    }

    @Test func aPlayThatPassesSongsRewritesEveryPlace() {
        var order = ranks([("a", 3), ("b", 2), ("c", 2), ("d", 2)])
        var slots = Dictionary(order.enumerated().map { ($0.element.key, $0.offset) }) { first, _ in first }

        Plays.sift(&order, &slots, 3)

        #expect(order.map(\.key) == ["a", "d", "b", "c"], "the song that played rises over the tie below it")
        #expect(order.map(\.count) == [3, 3, 2, 2])
        for (slot, rank) in order.enumerated() { #expect(slots[rank.key] == slot, "a swap that is not recorded sends the next play to the wrong song") }
    }

    @Test func thePlayOrderFollowsEveryPlay() {
        let songs = (0..<60).map { track("/m/Song \($0).mp3") }
        let plays = Plays(root: nil)
        var saved: [String: Int] = [:]

        for round in 0..<20 {
            for (number, song) in songs.enumerated() where (number + round) % (1 + number % 7) == 0 {
                saved[Plays.key(song), default: 0] += 1
                plays.bump(song)
            }
        }

        #expect(Set(saved.values).count > 1, "the counts differ, so the order means something")
        let best = saved.values.max()!
        let keys = plays.top(20) { _ in true }
        #expect(keys.count == 20)
        #expect(keys.map { saved[$0]! } == saved.values.sorted(by: >).prefix(20).map { $0 }, "the kept order holds the same counts as a full sort")

        for _ in 0..<20 {
            let one = plays.top(1) { _ in true }
            #expect(one.count == 1, "a tie at the top is drawn at random, and every draw is a best song")
            #expect(saved[one[0]] == best)
        }

        let fresh = track("/m/A New Song.mp3")
        plays.bump(fresh)
        #expect(plays.count(fresh) == 1, "the count is there before the disk")
        #expect(plays.top(saved.count + 1) { _ in true } == plays.top(saved.count) { _ in true } + [Plays.key(fresh)] || plays.top(saved.count + 1) { _ in true }.count == saved.count + 1, "a song that played for the first time enters the order")
        #expect(plays.top(saved.count + 1) { _ in true }.contains(Plays.key(fresh)), "and it is in the play order")
    }

    @Test func thePlayOrderComesBackFromTheFile() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }

        let songs = (0..<20).map { track("/m/Song \($0).mp3") }
        let plays = Plays(root: root)
        for (number, song) in songs.enumerated() {
            for _ in 0...number { plays.bump(song) }
        }
        plays.flush()
        Persist.flush()

        let again = Plays(root: root)
        #expect(again.top(5) { _ in true } == plays.top(5) { _ in true }, "the order is rebuilt from the counts, best first")
        #expect(again.count(songs[19]) == 20)
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

    @Test func everyPlayTellsTheLibrary() {
        var heard: [String] = []
        let song = track("/m/One.mp3")
        let plays = Plays(root: nil)
        plays.onPlay = { heard.append($0.url.path) }

        plays.bump(song)
        plays.bump(song)
        plays.bump(track("/m/Two.mp3"))

        #expect(heard == ["/m/One.mp3", "/m/One.mp3", "/m/Two.mp3"], "the band totals follow every play, not only the first")
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
