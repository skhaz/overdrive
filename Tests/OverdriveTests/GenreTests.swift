import Foundation
import Testing
@testable import Overdrive

struct GenreTests {
    @Test func namesTheStandardList() {
        #expect(Genre.id3(0) == "Blues")
        #expect(Genre.id3(17) == "Rock")
        #expect(Genre.id3(79) == "Hard Rock")
        #expect(Genre.id3(147) == "Synthpop")
        #expect(Genre.id3(-1) == "")
        #expect(Genre.id3(148) == "")
        #expect(Genre.id3(1000) == "")
    }

    @Test func keepsPlainText() {
        #expect(Genre.name("Rock") == "Rock")
        #expect(Genre.name("Indie Rock") == "Indie Rock")
        #expect(Genre.name("") == "")
        #expect(Genre.name("   ") == "")
    }

    @Test func resolvesANumberAlone() {
        #expect(Genre.name("(17)") == "Rock")
        #expect(Genre.name("(0)") == "Blues")
        #expect(Genre.name("(999)") == "")
    }

    @Test func prefersTheTextOverTheNumber() {
        #expect(Genre.name("(17)Rock") == "Rock")
        #expect(Genre.name("(17)(24)Death Metal") == "Death Metal")
        #expect(Genre.name("(12)(24)Cuban") == "Cuban")
    }

    @Test func leavesUnknownPrefixesAlone() {
        #expect(Genre.name("(RX)Remix") == "(RX)Remix")
        #expect(Genre.name("(CR)Cover") == "(CR)Cover")
    }
}
