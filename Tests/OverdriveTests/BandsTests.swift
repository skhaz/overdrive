import Foundation
import Testing
@testable import Overdrive

struct BandsTests {
    @Test func theBandsGoFromTheMostPlayedToTheLeast() {
        let order = Library.topArtists([("death", 3), ("krisiun", 40), ("morra", 1)], 3)

        #expect(order == ["krisiun", "death", "morra"])
    }

    @Test func aTieGoesByTheFoldedName() {
        let order = Library.topArtists([("sepultura", 7), ("angra", 7), ("baterista", 7)], 3)

        #expect(order == ["angra", "baterista", "sepultura"], "the same total ties by the folded name")
        #expect(Library.topArtists(order.map { ($0, 7) }, 3) == order, "the order is stable, so the same answer twice")
    }

    @Test func theCountCutsTheList() {
        let totals = [("a", 9), ("b", 8), ("c", 7)]

        #expect(Library.topArtists(totals, 1) == ["a"])
        #expect(Library.topArtists(totals, 2) == ["a", "b"])
        #expect(Library.topArtists(totals, 9) == ["a", "b", "c"], "more than the list has gives the whole list")
        #expect(Library.topArtists(totals, 0).isEmpty, "nothing asked for, nothing picked")
        #expect(Library.topArtists([], 5).isEmpty)
    }

    @Test func theFoldedNameIsTheKeyOfTheSongs() {
        #expect(Fuzzy.fold("Ratos de Porão") == Fuzzy.fold("ratos de porao"), "so an accent or a case change finds the same band")
        #expect(Library.topArtists([(Fuzzy.fold("Ratos de Porão"), 4)], 1) == [Fuzzy.fold("ratos de porao")])
    }

    @Test func theTotalsAreBuiltInTheScanAndKeptLive() throws {
        let library = try source("Library.swift")

        #expect(library.contains("totals[Fuzzy.fold(track.artist), default: 0] += store.top(key)"), "the sums ride the single pass of every scan")
        #expect(!library.contains("for key in playedKeys"), "a click never walks the library again")
        #expect(library.contains("let held = bandTotals[artist, default: 0]"), "a play adds one to its band without a scan")
        #expect(library.contains("if held == 0 { bands += 1 }"), "a first play opens a band")
        #expect(library.components(separatedBy: "for (slot, track) in everything.enumerated() {").count - 1 == 1, "one pass per scan builds the played keys, the band totals, and the key index")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }
}
