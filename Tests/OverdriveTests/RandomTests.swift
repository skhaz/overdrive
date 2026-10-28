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

    private func discovery(_ source: String) throws -> String {
        let start = try #require(source.range(of: "struct DiscoveryMenu: View {")).upperBound
        let rest = source[start...]
        return String(rest[..<(try #require(rest.range(of: "\n}\n")).lowerBound)])
    }

    private func discoveryRegion(_ source: String) throws -> String {
        try body(source, "private func start(_ picked: [Track], _ mine: Int, _ pool: Pool, _ count: Int, _ why: String?) {")
    }

    private func handler(_ source: String, _ notification: String) throws -> String {
        let start = try #require(source.range(of: "publisher(for: .\(notification))) {")).upperBound
        let rest = source[start...]
        return String(rest[..<(try #require(rest.range(of: "\n        }")).lowerBound)])
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

    @Test func theDiscoveryMenuOffersEveryPicker() throws {
        let menu = try discovery(try source("Views.swift"))

        #expect(Library.randomCounts == [1, 10, 20, 100])
        #expect(menu.contains("Menu(\"Songs (\\(library.total))\")"), "the picker says how many songs can come from it")
        #expect(menu.contains("Menu(\"Never Played (\\(library.neverPlayed))\")"), "the unplayed picker says how many songs were never played")
        #expect(menu.contains("Menu(\"Most Played (\\(library.played))\")"), "the best played picker says how many songs have a count")
        #expect(menu.components(separatedBy: "values(library.total) { discovery.pick(.songs, $0) }").count - 1 == 1)
        #expect(menu.components(separatedBy: "values(library.neverPlayed) { discovery.pick(.unplayed, $0) }").count - 1 == 1)
        #expect(menu.components(separatedBy: "values(library.played) { discovery.pick(.played, $0) }").count - 1 == 1)
        #expect(menu.components(separatedBy: "ForEach(Library.randomCounts, id: \\.self)").count - 1 == 1, "one list of values, used by every picker")
        #expect(menu.range(of: "keyboardShortcut") == nil, "a menu bar item never gets a plain key")
    }

    @Test func everyPickerNeedsItsOwnSongs() throws {
        let menu = try discovery(try source("Views.swift"))

        #expect(menu.components(separatedBy: ".disabled(pool.map { $0 < number } ?? false)").count - 1 == 1, "a value with more songs than its pool stays off")
        #expect(menu.contains(".disabled(library.total < Library.randomCounts[0])"), "an empty library disables the Songs picker")
        #expect(menu.contains(".disabled(library.neverPlayed < Library.randomCounts[0])"), "nothing new disables the Never Played picker")
        #expect(menu.contains(".disabled(library.played < Library.randomCounts[0])"), "nothing played disables the Most Played picker")
    }

    @Test func discoveryIsItsOwnMenuBarMenu() throws {
        let app = try source("Overdrive.swift")
        let start = try #require(app.range(of: "CommandMenu(\"Discovery\") {")).upperBound
        let rest = app[start...]
        let menu = String(rest[..<(try #require(rest.range(of: "\n            }")).lowerBound)])

        #expect(menu.contains("DiscoveryMenu()"), "the menu bar entry holds the pickers")
        #expect(menu.contains(".environment(library)") && menu.contains(".environment(discovery)"))
        #expect(!menu.contains(".environment(player)"), "the menu no longer plays by itself; Discovery owns the pick")
        #expect(app.range(of: "CommandMenu(\"Discovery\")")!.lowerBound < app.range(of: "CommandMenu(\"Song\")")!.lowerBound, "Discovery comes before Song")

        let controls = try body(app, "CommandMenu(\"Controls\") {")
        #expect(!controls.contains("Discovery"), "the pickers are never in Controls as well")
        #expect(!controls.contains("library.random(") && !controls.contains("library.unplayed("), "Controls only clears and moves")
    }

    @Test func aDiscoveryPickShowsUpNext() throws {
        let views = try source("Views.swift")
        let discovery = try source("Discovery.swift")

        #expect(try discoveryRegion(discovery).contains("player.random(tracks)\n        open(Work.done)"), "the pick replaces Up Next, then the screen follows it")
        #expect(try body(discovery, "func pick(_ pool: Pool, _ count: Int) {").contains("let mine = begin()"), "a pick that spends requests opens Up Next at once, so the user sees it working")
        #expect(views.contains("static let discovery = Notification.Name(\"discovery\")"))

        let shown = try handler(views, "discovery")
        #expect(shown.contains("navigation.open(.upNext, leaving: tracker.position)"), "the picked songs show in Up Next")
        #expect(shown.contains("lyrics.settle {"), "a page change flushes a pending lyrics edit first")
        #expect(!shown.contains("player.random"), "the handler never picks a second time")
        #expect(shown.contains("let stage = note.object as? String ?? Work.done"), "both stages log, so the log says when the screen opened and when the songs landed")
    }

    @Test func theUnplayedPickNeedsItsCount() throws {
        let library = try body(try source("Library.swift"), "func unplayed(_ count: Int) -> [Track] {")

        #expect(library.contains("guard neverPlayed >= count else { return [] }"), "a pick of more unplayed songs than the library has gives nothing")
        #expect(library.contains("everything.lazy.filter"), "the pick filters as it walks, so it never builds a second copy of the library")
    }

    @Test func theBestPlayedPickNeedsItsCount() throws {
        let library = try source("Library.swift")
        let body = try self.body(library, "func topmost(_ count: Int) -> [Track] {")

        #expect(body.contains("guard played >= count else { return [] }"), "a pick of more songs than the library has played gives nothing")
        #expect(body.contains("plays.top(count)"), "the pick reads the play order, it never sorts the library")
        #expect(!body.contains("sorted") && !body.contains("everything.lazy"), "no walk over the library and no sort of it")
        #expect(body.contains("tracks.shuffle()"), "the best played songs come in a random order")
        #expect(library.contains("private(set) var played = 0"), "the library knows how many songs have a count")
        #expect(library.contains("played = playedKeys.count"), "a play moves a song into that pool without a scan")
    }

    @Test func theBestPlayedPickSkipsASongTheLibraryDoesNotHave() throws {
        let library = try source("Library.swift")

        #expect(try self.body(library, "func topmost(_ count: Int) -> [Track] {").contains("{ index[$0] != nil }"), "a key of a folder that left the library never takes the place of a real song")
        #expect(library.contains("keyIndex = index"), "the key of every song is indexed once per scan, so the lookup is O(1)")
        #expect(library.components(separatedBy: "for (slot, track) in everything.enumerated() {").count - 1 == 1, "one pass per scan builds the played keys, the played bands, and the key index")
        #expect(library.contains("if held == 0 { bands += 1 }"), "a first play opens a band without a scan")
    }

    @Test func aPlayIsCountedOncePerSong() throws {
        let player = try source("Player.swift")
        let finished = try body(player, "private func finished(_ ended: AVPlayerItem?) {")
        let tick = try body(player, "private func tick(_ seconds: Double) {")

        #expect(tick.contains("if !counted, Player.counts(played, track.duration) {"), "a song counts when 80% of it really played")
        #expect(finished.contains("if let track = current, !counted {"), "a song that reaches its end counts even when its stated length is wrong")
        #expect(player.components(separatedBy: "plays.bump").count - 1 == 2, "the play is counted once, at 80% or at the end, never twice")
        #expect(player.contains("counted = false"), "a new song starts uncounted")
        let moved = try #require(finished.range(of: "guard let next = following(index)")?.lowerBound)
        #expect(try #require(finished.range(of: "plays.bump")?.upperBound) < moved, "the count is taken before the player moves to the next song")
        #expect(player.contains("plays: Plays) {"), "the player gets the counts of the library at boot")
    }
}
