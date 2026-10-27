import Foundation
import Testing
@testable import Overdrive

#if DEBUG
private let optimized = false
#else
private let optimized = true
#endif

@MainActor
@Suite(.enabled(if: optimized, "a debug build is 8x slower and the bound would prove nothing; run with swift test -c release"))
struct DiscoveryCostTests {
    private let titles = ["Blood of Lions", "Combustion Inferno", "Bloodcraft", "South of the Border", "Imperial Invasive Intense",
                          "Ravenous", "Demonic Trilogy", "Burning Eyes", "Kings of Killing", "Darkest Absolute"]

    private func songs(_ count: Int, _ shape: (Int) -> String) -> [Track] {
        (1...count).map { index in
            Track(url: URL(fileURLWithPath: "/m/\(index).mp3"), title: shape(index), artist: "A", album: "B", number: index, disc: 1,
                  albumArtist: "", year: 2000, duration: 100, albumID: "x")
        }
    }

    @Test func aMatchReadsEveryNameOnce() {
        let far = songs(300) { "Alfa \($0) Beta Gamma Delta Epsilon Zeta \($0)" }
        let improbable = songs(300) { "Track \($0) of the Executioner and the Longest Title Here \($0)" }

        #expect(Discovery.owned(titles, far) == nil, "nothing here matches, so the walk reads every name")

        let start = ContinuousClock.now
        for _ in 0..<100 {
            _ = Discovery.owned(titles, far)
            _ = Discovery.owned(titles, improbable)
        }
        let elapsed = start.duration(to: .now)

        #expect(elapsed < .seconds(1), "200 artists of 300 songs each took \(elapsed); the walk that folded every name per title spent 3 s here")
    }

    @Test func anExactNameCostsNoComparison() {
        let held = songs(300) { $0 == 1 ? "Blood of Lions" : "Track \($0) of the Executioner \($0)" }

        #expect(Discovery.owned(titles, held)?.title == "Blood of Lions")

        let start = ContinuousClock.now
        for _ in 0..<100 { _ = Discovery.owned(titles, held) }
        let elapsed = start.duration(to: .now)

        #expect(elapsed < .milliseconds(400), "the common case is one dictionary read per title, not 300 comparisons: \(elapsed)")
    }

    @Test func theBandedWalkCostsLessThanTheFullRatio() {
        let one = Similarity.letters("Come As You Are And Some Other Long Name Indeed Here")
        let two = Similarity.letters("Totally Different Song That Shares Nothing At All")

        let start = ContinuousClock.now
        for _ in 0..<20_000 { _ = Similarity.close(one, two) }
        let banded = start.duration(to: .now)

        let full = ContinuousClock.now
        for _ in 0..<20_000 { _ = Similarity.ratio(one, two) }
        let whole = full.duration(to: .now)

        #expect(Similarity.close(one, two) == nil, "these names do not match, so the short walk may stop early")
        #expect(banded < whole, "a name that cannot reach the line must cost less than a full distance: \(banded) vs \(whole)")
    }
}
