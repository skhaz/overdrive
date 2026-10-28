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
        let pick = { (count: Int) in 0 }

        #expect(Discovery.choose(titles, far, using: pick) == nil, "nothing here matches, so the walk reads every name")

        let start = ContinuousClock.now
        for _ in 0..<100 {
            _ = Discovery.choose(titles, far, using: pick)
            _ = Discovery.choose(titles, improbable, using: pick)
        }
        let elapsed = start.duration(to: .now)

        #expect(elapsed < .seconds(1), "200 artists of 300 songs each took \(elapsed); the walk that folded every name per title spent 3 s here")
    }

    @Test func anExactNameCostsOneDictionaryRead() {
        let held = Discovery.Held(songs(300) { $0 == 1 ? "Blood of Lions" : "Track \($0) of the Executioner and the Longest Title \($0)" })

        #expect(held.one("Blood of Lions")?.title == "Blood of Lions")
        #expect(held.one("Blood of Lion")?.title == "Blood of Lions", "a near name still finds its song, by walking every song")

        let start = ContinuousClock.now
        for _ in 0..<100_000 { _ = held.one("Blood of Lions") }
        let exact = start.duration(to: .now)

        let walk = ContinuousClock.now
        for _ in 0..<1_000 { _ = held.one("Blood of Lion") }
        let near = walk.duration(to: .now)

        #expect(exact < near, "an exact name is one dictionary read: \(exact) for 100 000 of them, against \(near) for 1 000 walks of 300 songs")
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

    @Test func theLocalPassOverABigMirrorCostsNothing() {
        let library = Library(loudness: Loudness(), folders: [])
        let mirror = (0..<20_000).map { Loves.key("Ghost \($0)", "Dance Macabre \($0)") }

        let start = ContinuousClock.now
        var held = 0
        for key in mirror {
            let parts = key.components(separatedBy: "\u{1F}")
            if library.hold(folded: parts[0], folded: parts[1]) != nil { held += 1 }
        }
        let elapsed = start.duration(to: .now)

        #expect(held == 0, "a library with no folders holds no loved song")
        #expect(elapsed < .milliseconds(50), "20 000 loved keys over a library that holds none of them took \(elapsed); the local pass runs on every scan")
    }
}
