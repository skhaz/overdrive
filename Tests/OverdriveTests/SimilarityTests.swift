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
        #expect(ratio("Sandman", "Enter Sandman") < Similarity.threshold)
        #expect(ratio("Sandman", "Sandmen") > Similarity.threshold)
    }

    @Test func theMeasuredRatiosHold() {
        #expect(abs(ratio("Come As You Are", "Come As You Are (Remastered)") - 0.55) < 0.01)
        #expect(abs(ratio("Sandman", "Enter Sandman") - 0.58) < 0.01)
        #expect(abs(ratio("Sandman", "Sandmen") - 0.86) < 0.01)
        #expect(abs(ratio("Blood of Lions", "Bloodcraft") - 0.42) < 0.01)
    }

    @Test func theDistanceIsTheEditCount() {
        #expect(Similarity.distance([Character](), [Character]()) == 0)
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
        #expect(Similarity.normal("A (Remaster) 2004") == "aremaster2004")
        #expect(Similarity.normal("!!") == "")
        #expect(Similarity.letters("Believe").count == 7)
        #expect(Similarity.letters("É") == Similarity.letters("E"), "one accented scalar is one letter, not its decomposition")
    }

    @Test func theBandedWalkAgreesWithTheFullRatio() {
        let corpus = ["", "!", "A", "a", "Believe", "Cher", "Sandman", "Sandmen", "Enter Sandman", "Bloodcraft", "Bloodcrft",
                      "Combustion Inferno", "Combustion Infernos", "Sábado de sol", "Sabado de Sol", "Come As You Are",
                      "Come As You Are (Remastered)", "Ratos de Porão", "ratos de porao", "Dont Stop Believin",
                      "Don't Stop Believin'", "Individual Thought Patterns", "individualthoughtpatterns", "II", "2",
                      "The Great Execution", "Serene", "Serena", "Serena II", "X X X", "abcdef", "abcdeg", "aabbccddeeff"]

        for one in corpus {
            for two in corpus {
                let full = ratio(one, two)
                let banded = Similarity.close(Similarity.letters(one), Similarity.letters(two))

                if full >= Similarity.threshold {
                    #expect(banded == full, "\(one) vs \(two): the short walk must return the same ratio")
                } else {
                    #expect(banded == nil, "\(one) vs \(two): a name under the line must not pass")
                }
            }
        }
    }

    @Test func theBandedWalkCoversEveryNameLength() {
        let alphabet = Array("abcde")

        for length in 1...24 {
            let base = String((0..<length).map { alphabet[$0 % alphabet.count] })
            for mutation in 0...4 {
                var other = Array(base)
                for index in 0..<min(mutation, other.count) { other[index] = "z" }

                let one = Similarity.letters(base), two = Similarity.letters(String(other))
                let full = 1 - Double(Similarity.distance(one, two)) / Double(max(one.count, two.count))
                let banded = Similarity.close(one, two)

                if full >= Similarity.threshold {
                    #expect(banded == full, "length \(length), \(mutation) mutations")
                } else {
                    #expect(banded == nil, "length \(length), \(mutation) mutations")
                }
            }
        }
    }

    @Test func anEmptyNameNeverPassesTheBandedWalk() {
        #expect(Similarity.close([], Similarity.letters("Believe")) == nil)
        #expect(Similarity.close(Similarity.letters("Believe"), []) == nil)
        #expect(Similarity.close([], []) == nil)
        #expect(Similarity.close(Similarity.letters("!!"), Similarity.letters("Believe")) == nil)
    }
}
