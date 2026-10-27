import Foundation
import Testing
@testable import Overdrive

struct BandsTests {
    private func band(_ folded: String, _ name: String, _ plays: Int) -> (folded: String, name: String, plays: Int) {
        (folded, name, plays)
    }

    @Test func theBandsGoFromTheMostPlayedToTheLeast() {
        let order = Library.topArtists([band("death", "Death", 3), band("krisiun", "Krisiun", 40), band("morra", "Morra", 1)], 3)

        #expect(order.map(\.name) == ["Krisiun", "Death", "Morra"])
        #expect(order.map(\.folded) == ["krisiun", "death", "morra"], "the folded name travels with the band, so the songs can be looked up")
    }

    @Test func aTieGoesByTheFoldedName() {
        let order = Library.topArtists([band("sepultura", "Sepultura", 7), band("angra", "Angra", 7), band("baterista", "Zé", 7)], 3)

        #expect(order.map(\.name) == ["Angra", "Zé", "Sepultura"], "the same total ties by the folded name, not the display one")
        #expect(Library.topArtists(order.map { band($0.folded, $0.name, 7) }, 3).map(\.name) == order.map(\.name), "the order is stable, so the same answer twice")
    }

    @Test func theCountCutsTheList() {
        let totals = [band("a", "A", 9), band("b", "B", 8), band("c", "C", 7)]

        #expect(Library.topArtists(totals, 1).map(\.name) == ["A"])
        #expect(Library.topArtists(totals, 2).map(\.name) == ["A", "B"])
        #expect(Library.topArtists(totals, 9).map(\.name) == ["A", "B", "C"], "more than the list has gives the whole list")
        #expect(Library.topArtists(totals, 0).isEmpty, "nothing asked for, nothing picked")
        #expect(Library.topArtists([], 5).isEmpty)
    }

    @Test func theFoldedNameIsTheKeyOfTheSongs() {
        let bands = Library.topArtists([band("ratos de porão", "Ratos de Porão", 4)], 1)

        #expect(bands.map(\.folded) == ["ratos de porão"], "the fold keeps the display name for Last.fm and the key for the library")
        #expect(Fuzzy.fold("Ratos de Porão") == Fuzzy.fold("ratos de porao"), "so an accent or a case change finds the same band")
    }
}
