import Foundation
import Testing
@testable import Overdrive

/// One fake Last.fm chart, shared by the fake URL protocol below. A lock, because
/// the requests run off the main actor and four artists are asked at a time.
private final class Chart: @unchecked Sendable {
    private struct State {
        var artists: [String] = []
        var tracks: [String: [String]] = [:]
        var calls: [String] = []
        var offline = false
        var single = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func reset(_ artists: [String], _ tracks: [String: [String]], offline: Bool = false, single: Bool = false) {
        lock.withLock { state = State(artists: artists, tracks: tracks, calls: [], offline: offline, single: single) }
    }

    static var calls: [String] { lock.withLock { state.calls } }

    /// The answer to one method, or nil when the network is down.
    static func reply(_ method: String?, _ artist: String?) -> [String: Any]? {
        lock.withLock {
            state.calls.append(method ?? "")
            guard !state.offline else { return nil }

            switch method {
            case "user.getTopArtists":
                return ["topartists": ["artist": shaped(state.artists.map { ["name": $0] }, state.single)]]
            case "artist.getTopTracks":
                return ["toptracks": ["track": shaped((state.tracks[artist ?? ""] ?? []).map { ["name": $0] }, state.single)]]
            default:
                return ["error": 3, "message": "Invalid Method"]
            }
        }
    }

    /// The service sends one item, not a list of one, when the list has one.
    private static func shaped(_ items: [[String: Any]], _ single: Bool) -> Any {
        single && items.count == 1 ? items[0] : items
    }
}

private final class ChartFake: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = Data()

        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            stream.close()
        } else if let data = request.httpBody {
            body = data
        }

        var form: [String: String] = [:]

        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            form[parts[0]] = parts.count > 1 ? parts[1] : ""
        }

        guard let object = Chart.reply(form["method"], form["artist"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let data = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func hit() { lock.withLock { count += 1 } }
}

@MainActor
@Suite(.serialized)
struct DiscoveryTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "OverdriveDiscovery-\(UUID().uuidString)")

    init() {
        Chart.reset([], [:])
    }

    func client() -> LastFM {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [ChartFake.self]

        var configuration = LastFM.Configuration()
        configuration.endpoint = URL(string: "https://example.invalid/2.0/")!
        configuration.credentials = directory.appending(path: "lastfm.plist")
        configuration.store = directory.appending(path: "Scrobbles.plist")
        configuration.transport = URLSession(configuration: session)
        configuration.retry = .seconds(3600)
        configuration.monitor = false

        let lastFM = LastFM(configuration)
        lastFM.user = "tester"
        return lastFM
    }

    func track(_ title: String, _ artist: String = "Death") -> Track {
        Track(url: URL(fileURLWithPath: "/m/\(artist)/\(title).mp3"), title: title, artist: artist, album: "Album", number: 1, disc: 1,
              albumArtist: "", year: 2000, duration: 200, albumID: "x")
    }

    func songs(_ titles: [String], _ artist: String = "Death") -> [Track] {
        titles.map { track($0, artist) }
    }

    @Test func theBestTitleThatTheLibraryHasWins() {
        let owned = Discovery.owned(["Combustion Inferno", "Bloodcraft"], songs(["Bloodcraft", "Combustion Inferno"]))

        #expect(owned?.title == "Combustion Inferno", "the highest-ranked title wins, even when the library holds the other one first")
        #expect(Discovery.owned(["Bloodcraft"], songs(["Combustion Inferno"])) == nil, "a song the library lacks is skipped")
        #expect(Discovery.owned([], songs(["Bloodcraft"])) == nil, "no title from the internet, no song")
        #expect(Discovery.owned(["Bloodcraft"], []) == nil, "an artist with no songs in the library is skipped")
    }

    @Test func theClosestNameOfTheLibraryWinsInsideOneTitle() {
        #expect(Discovery.owned(["Sandman"], songs(["Sandman", "Enter Sandman", "Sandmen"]))?.title == "Sandman", "the exact name beats a near one")
        #expect(Discovery.owned(["Enter Sandman"], songs(["Sandmen", "Enter Sandman"]))?.title == "Enter Sandman")
    }

    @Test func anAccentOrACaseChangeIsTheSameSong() {
        #expect(Discovery.owned(["Sabado De Sol"], songs(["sábado de sol"], "Morra"))?.title == "sábado de sol", "the library title is what plays, with its own spelling")
        #expect(Discovery.owned(["Ratos de Porao"], songs(["Ratos de Porão"], "Ratos de Porão")) != nil)
    }

    @Test func theWalkFollowsTheArtistOrderAndStopsAtTheCount() async {
        let wanted = [("Krisiun", songs(["Blood of Lions"], "Krisiun")), ("Death", songs(["Individual Thought Patterns"])), ("Torture Squad", songs(["Wrong Assembly"], "Torture Squad"))]
        let picked = await Discovery.collect(2, wanted) { name in
            ["Krisiun": ["Blood of Lions"], "Death": ["Individual Thought Patterns"], "Torture Squad": ["Wrong Assembly"]][name] ?? []
        }

        #expect(picked.map(\.title) == ["Blood of Lions", "Individual Thought Patterns"], "your own order, and it stops at the count")
    }

    @Test func theWalkSkipsAnArtistTheLibraryDoesNotHave() async {
        let asked = Counter()
        let wanted = [("Ghost", [] as [Track]), ("Death", songs(["Bloodcraft"]))]
        let picked = await Discovery.collect(1, wanted) { _ in
            asked.hit()
            return ["Bloodcraft"]
        }

        #expect(picked.map(\.title) == ["Bloodcraft"])
        #expect(asked.value == 1, "an artist with no song in the library costs no request")
    }

    @Test func theWalkSkipsAnArtistWhoseTopTracksNobodyHas() async {
        let wanted = [("A", songs(["One"], "A")), ("B", songs(["Two"], "B"))]
        let picked = await Discovery.collect(1, wanted) { name in
            name == "A" ? ["Nothing Here"] : ["Two"]
        }

        #expect(picked.map(\.title) == ["Two"], "a miss moves on to the next artist")
    }

    @Test func theWalkAsksAWindowAtATime() async {
        let asked = Counter()
        let wanted = (0..<12).map { ("Artist \($0)", songs(["Song \($0)"], "Artist \($0)")) }
        let picked = await Discovery.collect(1, wanted) { name in
            asked.hit()
            return [name.replacingOccurrences(of: "Artist", with: "Song")]
        }

        #expect(picked.count == 1)
        #expect(asked.value <= Discovery.window, "the walk asks at most one window before it can stop, not every artist")
    }

    @Test func aSongTwoArtistsShareEntersTheListOnce() async {
        let wanted = [("A", songs(["Same"])), ("B", songs(["Same"]))]
        let picked = await Discovery.collect(2, wanted) { _ in ["Same"] }

        #expect(picked.count == 1, "the same song is never in the list twice")
    }

    @Test func theArtistsComeFromLastFM() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        Chart.reset(["Krisiun", "Death", "Morra"], ["Krisiun": ["Blood of Lions", "Bloodcraft"]])

        let lastFM = client()
        let names = await lastFM.topArtists(3)
        let titles = await lastFM.topTracks("Krisiun", 10)

        #expect(names == ["Krisiun", "Death", "Morra"])
        #expect(Chart.calls == ["user.getTopArtists", "artist.getTopTracks"])
        #expect(titles == ["Blood of Lions", "Bloodcraft"])
    }

    @Test func oneItemArrivesNotAsAList() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        Chart.reset(["Krisiun"], ["Krisiun": ["Blood of Lions"]], single: true)

        let lastFM = client()
        let names = await lastFM.topArtists(5)
        let titles = await lastFM.topTracks("Krisiun", 5)

        #expect(names == ["Krisiun"])
        #expect(titles == ["Blood of Lions"], "the service sends one item when the list has one")
    }

    @Test func noUserOrNoAnswerGivesNoName() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }

        let lastFM = client()
        Chart.reset([], [:])
        let empty = await lastFM.topArtists(5)
        let noArtist = await lastFM.topTracks("", 5)
        let zero = await lastFM.topArtists(0)

        #expect(empty.isEmpty)
        #expect(noArtist.isEmpty, "an empty artist name costs no request")
        #expect(zero.isEmpty, "nothing asked for, nothing fetched")

        Chart.reset(["Krisiun"], [:], offline: true)
        let offline = await lastFM.topArtists(5)
        let offlineTitles = await lastFM.topTracks("Krisiun", 5)

        #expect(offline.isEmpty, "an offline service gives no name, it never throws")
        #expect(offlineTitles.isEmpty)

        Chart.reset(["Krisiun"], [:])
        lastFM.user = ""
        let noUser = await lastFM.topArtists(5)

        #expect(noUser.isEmpty, "no user means no request")
        #expect(Chart.calls.isEmpty, "a refused call sends nothing")
    }

    @Test func thePickerIsOfferedOnlyWithCredentialsAndSongs() throws {
        let discovery = try source("Discovery.swift")

        #expect(discovery.contains("!LastFM.key.isEmpty && !lastFM.user.isEmpty && !library.albums.isEmpty"), "no key, no user, or no songs means the submenu is off")
        #expect(discovery.contains("guard ready else {"), "a click that cannot work is refused before any request")
        #expect(discovery.contains("guard !running else {"), "one discovery at a time")
    }

    @Test func aClickAsksTheInternetAtOnceAndKeepsNoCache() throws {
        let discovery = try source("Discovery.swift")

        #expect(!discovery.contains("Persist."), "the discovery is never written to the disk")
        #expect(!discovery.contains("Date(") && !discovery.contains("ContinuousClock"), "no lifetime, no cache")
        #expect(body(discovery, "func topSongs(_ count: Int) {").contains("await collect(count)"), "every click runs the walk")
        #expect(body(discovery, "private func collect(_ count: Int) async -> [Track] {").contains("await lastFM.topArtists(count)"), "the artists come from a fresh request")
        #expect(discovery.contains("player.random(tracks)\n            NotificationCenter.default.post(name: .discovery, object: nil)"), "the picked songs replace Up Next and the screen follows")
    }

    @Test func theLastFMPickerIsInTheDiscoveryMenu() throws {
        let menu = try discovery(try source("Views.swift"))

        #expect(menu.contains("Menu(\"Last.fm Artists\") {"))
        #expect(menu.components(separatedBy: "values(nil) { discovery.topSongs($0) }").count - 1 == 1)
        #expect(menu.contains(".disabled(!discovery.ready || discovery.running)"), "off without a Last.fm account, and no second request while one is in flight")
        #expect(!menu.contains("Persist."), "the menu reads nothing from the disk")
    }

    @Test func theChartIsReadFourArtistsAtATime() throws {
        let discovery = try source("Discovery.swift")

        #expect(Discovery.window == 4, "Last.fm answers 29 when one IP spends its rate")
        #expect(Discovery.tracks == 10, "ten top tracks of an artist is enough to find a song the library has")
        #expect(discovery.contains("min(start + window, names.count)"), "the walk stops at the artists it has")
        #expect(discovery.contains("found.count < count"), "the walk stops as soon as the list is full")
    }

    // MARK: - helpers

    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }

    private func body(_ source: String, _ signature: String) -> String {
        guard let start = source.range(of: signature) else { return "" }
        let rest = source[start.upperBound...]
        return String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
    }

    private func discovery(_ source: String) throws -> String {
        let start = try #require(source.range(of: "struct DiscoveryMenu: View {")).upperBound
        let rest = source[start...]
        return String(rest[..<(try #require(rest.range(of: "\n}\n")).lowerBound)])
    }
}
