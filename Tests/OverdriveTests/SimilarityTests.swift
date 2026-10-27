import Foundation
import Testing
@testable import Overdrive

struct SimilarityTests {
    private func ratio(_ one: String, _ two: String) -> Double {
        Similarity.ratio(one, two)
    }

    @Test func theThresholdIsEightyPercent() {
        #expect(Similarity.threshold == 0.8)
    }

    @Test func anIdenticalNameScoresOne() {
        #expect(ratio("Blood of Lions", "Blood of Lions") == 1)
        #expect(ratio("", "") == 0, "an empty name is not a song")
        #expect(ratio("Believe", "") == 0, "an empty answer from the internet never matches")
        #expect(ratio("", "Believe") == 0)
    }

    @Test func caseAccentsAndSpacingScoreNothing() {
        #expect(ratio("Sábado de sol", "Sabado de Sol") == 1)
        #expect(ratio("Back In Black", "back in black") == 1)
        #expect(ratio("Dont Stop Believin", "Don't Stop Believin'") == 1, "an apostrophe is not a letter")
        #expect(ratio("Angra  II", "Angra II") == 1)
    }

    @Test func aSmallDifferenceStillMatches() {
        #expect(ratio("Combustion Inferno", "Combustion Infernos") > Similarity.threshold, "one plural is the same song")
        #expect(ratio("Bloodcraft", "Bloodcrft") > Similarity.threshold, "one typo is the same song")
        #expect(ratio("Ratos de Porão", "Ratos de Porao") == 1)
    }

    @Test func aDifferentSongScoresLow() {
        #expect(ratio("Song", "Sing") < Similarity.threshold)
        #expect(ratio("Blood of Lions", "Bloodcraft") < Similarity.threshold)
        #expect(ratio("Believe", "Cher") < Similarity.threshold)
        #expect(ratio("Amor Verdadeiro", "Verdade") < Similarity.threshold)
    }

    @Test func aSuffixThatDoublesTheNameIsNotTheSameSong() {
        #expect(ratio("Come As You Are", "Come As You Are (Remastered)") < Similarity.threshold,
                "a remaster tag that lengthens the name a lot falls under the line; the library title is what the pick returns")
    }

    @Test func theDistanceIsTheEditCount() {
        #expect(Similarity.distance([], []) == 0)
        #expect(Similarity.distance(Array("kitten"), Array("sitting")) == 3)
        #expect(Similarity.distance(Array("sitting"), Array("kitten")) == 3, "the distance does not depend on the order")
        #expect(Similarity.distance([], Array("abc")) == 3)
        #expect(Similarity.distance(Array("abc"), []) == 3)
        #expect(Similarity.distance(Array("flaw"), Array("lawn")) == 2)
        #expect(Similarity.distance(Array("gumboil"), Array("gaumbol")) == 2)
        #expect(Similarity.distance(Array("saturday"), Array("sunday")) == 3)
    }

    @Test func theDistanceHoldsForLongNames() {
        let long = Array(String(repeating: "a", count: 200))
        var other = long
        other[50] = "b"
        other[120] = "c"

        #expect(Similarity.distance(long, other) == 2)
        #expect(Similarity.distance(other, long) == 2)
    }

    @Test func onlyLettersAndDigitsAreCompared() {
        #expect(Similarity.letters("A (Remaster) 2004") == Array("aremaster2004"))
        #expect(Similarity.letters("!!") == [])
    }
}
