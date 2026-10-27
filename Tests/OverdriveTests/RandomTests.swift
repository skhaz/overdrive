import Foundation
import Testing
@testable import Overdrive

struct RandomTests {
    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }

    private func body(_ source: String, _ signature: String) -> String {
        guard let start = source.range(of: signature) else { return "" }
        let rest = source[start.upperBound...]
        return String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
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

    @Test func aRandomPickReplacesUpNextAndPlays() throws {
        let player = try body(try source("Player.swift"), "func random(_ tracks: [Track]) {")

        #expect(player.contains("play(tracks)"), "the picked songs become Up Next and the first one starts")
        #expect(!player.contains("insert("), "the picked songs never join the list that was there")
        #expect(!player.contains("clear()"), "play replaces the queue, so no stop in between")
    }

    @Test func theRandomMenuOffersEveryCountAndNoShortcut() throws {
        let app = try source("Overdrive.swift")
        let start = try #require(app.range(of: "Menu(\"Discovery\"")).upperBound
        let rest = app[start...]
        let end = try #require(rest.range(of: ".disabled(library.total < Library.randomCounts[0])")).lowerBound
        let menu = String(rest[..<end])

        #expect(Library.randomCounts == [1, 10, 20, 100])
        #expect(app.contains("ForEach(Library.randomCounts, id: \\.self)"))
        #expect(app.contains("player.random(library.random(number))"), "each value picks its songs from the library")
        #expect(menu.range(of: "keyboardShortcut") == nil, "a menu bar item never gets a plain key")
        #expect(menu.components(separatedBy: ".disabled(library.total < number)").count - 1 == 1, "each value is disabled on its own")
    }

    @Test func aValueNeedsThatManySongs() throws {
        let library = try source("Library.swift")

        #expect(try source("Overdrive.swift").contains(".disabled(library.total < number)"), "a count with more songs asked for than the library has stays off")
        #expect(library.contains("private(set) var total = 0"), "the menu reads the size of the library")
        #expect(library.contains("total = everything.count"), "the size follows every scan")
        #expect(try body(library, "func random(_ count: Int) -> [Track] {").contains("guard total >= count else { return [] }"), "a pick of more songs than the library has gives nothing")
    }

    @Test func anEmptyLibraryDisablesTheWholeMenu() throws {
        #expect(try source("Overdrive.swift").contains("Menu(\"Discovery\", systemImage: \"die.face.5\") {\n                    ForEach(Library.randomCounts, id: \\.self) { number in\n                        Button(\"\\(number) Song\\(number == 1 ? \"\" : \"s\")\") { player.random(library.random(number)) }\n                            .disabled(library.total < number)\n                    }\n                }\n                .disabled(library.total < Library.randomCounts[0])"))
    }
}
