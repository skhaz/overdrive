import Foundation
import Testing
@testable import Overdrive

struct RandomTests {
    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }

    private func body(_ source: String, _ signature: String) throws -> String {
        guard let start = source.range(of: signature) else { return "" }
        let rest = source[start.upperBound...]
        return String(rest[..<(try #require(rest.range(of: "\n    }\n")).lowerBound)])
    }

    private func discovery(_ app: String) throws -> String {
        let start = try #require(app.range(of: "Menu(\"Discovery\"")).lowerBound
        let rest = app[start...]
        let end = try #require(rest.range(of: "Button(\"Clear Up Next")).lowerBound
        return String(rest[..<end])
    }

    @Test func noSongsAskedForGivesNoSong() {
        #expect(Player.picked([1, 2, 3], 0).isEmpty)
        #expect(Player.picked([1, 2, 3], -1).isEmpty)
    }

    @Test func anEmptyLibraryGivesNoSong() {
        #expect(Player.picked([Int](), 10).isEmpty)
    }

    @Test func moreSongsThanTheLibraryGivesEverySongOnce() {
        let picked = Player.picked(Array(1...50), 100)

        #expect(picked.count == 50)
        #expect(Set(picked) == Set(1...50))
    }

    @Test func thePickedSongsAreAllDifferent() {
        let picked = Player.picked(Array(0..<1000), 100)

        #expect(picked.count == 100)
        #expect(Set(picked).count == 100, "no song comes twice")
    }

    @Test func everyPickComesFromTheLibrary() {
        let library = Array(0..<20)
        for _ in 0..<200 {
            let picked = Player.picked(library, 5)

            #expect(picked.count == 5)
            #expect(Set(picked).isSubset(of: Set(library)))
        }
    }

    @Test func everySongCanBePicked() {
        var seen: Set<Int> = []
        for _ in 0..<2000 { seen.formUnion(Player.picked(Array(0..<40), 1)) }

        #expect(seen == Set(0..<40), "every song can be the one that shows")
    }

    @Test func thePickedSongsComeInARandomOrder() {
        let library = Array(0..<200)
        var orders: Set<[Int]> = []
        for _ in 0..<50 { orders.insert(Player.picked(library, 60)) }

        #expect(orders.count > 1, "the same order twice in a row is not a random pick")
        #expect(Player.picked(library, 200) != library, "the whole library comes back shuffled")
    }

    @Test func thePickTouchesEverySongOnlyOnce() {
        let library = Array(0..<50_000)
        var counted = 0
        let picked = Player.picked(library.lazy.map { counted += 1; return $0 }, 20)

        #expect(picked.count == 20)
        #expect(counted == 50_000, "one pass over the library, no second look and no copy of it")
    }

    @Test func aRandomPickReplacesUpNextAndPlays() throws {
        let player = try body(try source("Player.swift"), "func random(_ tracks: [Track]) {")

        #expect(player.contains("play(tracks)"), "the picked songs become Up Next and the first one starts")
        #expect(!player.contains("insert("), "the picked songs never join the list that was there")
        #expect(!player.contains("clear()"), "play replaces the queue, so no stop in between")
    }

    @Test func theDiscoveryMenuOffersBothPickers() throws {
        let menu = try discovery(try source("Overdrive.swift"))

        #expect(Library.randomCounts == [1, 10, 20, 100])
        #expect(menu.contains("Menu(\"Songs (\\(library.total))\")"), "the picker says how many songs can come from it")
        #expect(menu.contains("Menu(\"Never Played (\\(library.neverPlayed))\")"), "the unplayed picker says how many songs were never played")
        #expect(menu.components(separatedBy: "ForEach(Library.randomCounts, id: \\.self)").count - 1 == 2, "both pickers use the same values")
        #expect(menu.components(separatedBy: "player.random(library.random(number))").count - 1 == 1)
        #expect(menu.components(separatedBy: "player.random(library.unplayed(number))").count - 1 == 1)
        #expect(menu.range(of: "keyboardShortcut") == nil, "a menu bar item never gets a plain key")
    }

    @Test func everyPickerNeedsItsOwnSongs() throws {
        let menu = try discovery(try source("Overdrive.swift"))

        #expect(menu.components(separatedBy: ".disabled(library.total < number)").count - 1 == 1, "a value with more songs than the library has stays off")
        #expect(menu.components(separatedBy: ".disabled(library.neverPlayed < number)").count - 1 == 1, "a value with more songs than the library has never played stays off")
        #expect(menu.contains(".disabled(library.total < Library.randomCounts[0])"))
        #expect(menu.contains(".disabled(library.neverPlayed < Library.randomCounts[0])"))
        #expect(menu.contains(".disabled(library.total == 0)"), "an empty library disables the whole menu")
    }

    @Test func theUnplayedPickNeedsItsCount() throws {
        let library = try body(try source("Library.swift"), "func unplayed(_ count: Int) -> [Track] {")

        #expect(library.contains("guard neverPlayed >= count else { return [] }"), "a pick of more unplayed songs than the library has gives nothing")
        #expect(library.contains("everything.lazy.filter"), "the pick filters as it walks, so it never builds a second copy of the library")
    }

    @Test func theCountIsSetWhenASongEnds() throws {
        let player = try source("Player.swift")
        let finished = try body(player, "private func finished(_ ended: AVPlayerItem?) {")

        #expect(finished.contains("if let track = current { plays.bump(track) }"), "a song that played to the end counts one play")
        #expect(player.components(separatedBy: "plays.bump").count - 1 == 1, "only a full play counts a song")
        let moved = try #require(finished.range(of: "guard let next = following(index)")?.lowerBound)
        #expect(try #require(finished.range(of: "plays.bump")?.upperBound) < moved, "the count is taken before the player moves to the next song")
        #expect(player.contains("plays: Plays) {"), "the player gets the counts of the library at boot")
    }
}
