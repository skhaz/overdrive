import Foundation
import Testing
@testable import Overdrive

private final class Chart: @unchecked Sendable {
    private struct State {
        var artists: [String] = []
        var tracks: [String: [String]] = [:]
        var known: [String: String] = [:]
        var calls: [String] = []
        var offline = false
        var single = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func reset(_ artists: [String], _ tracks: [String: [String]], known: [String: String] = [:], offline: Bool = false, single: Bool = false) {
        lock.withLock { state = State(artists: artists, tracks: tracks, known: known, calls: [], offline: offline, single: single) }
    }

    static var calls: [String] { lock.withLock { state.calls } }

    static func reply(_ method: String?, _ artist: String?) -> [String: Any]? {
        lock.withLock {
            state.calls.append(method ?? "")
            guard !state.offline else { return nil }

            switch method {
            case "user.getTopArtists":
                return ["topartists": ["artist": shaped(state.artists.map { ["name": $0] }, state.single)]]
            case "artist.getTopTracks":
                return ["toptracks": ["track": shaped((state.tracks[artist ?? ""] ?? []).map { ["name": $0] }, state.single)]]
            case "artist.getInfo":
                guard let name = state.known[artist ?? ""] else {
                    return ["error": 6, "message": "The artist you supplied could not be found"]
                }
                let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
                let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name

                return ["artist": ["name": name, "url": "https://www.last.fm/music/" + encoded]]
            default:
                return ["error": 3, "message": "Invalid Method"]
            }
        }
    }

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

    /// A draw that must never run: a single candidate is taken at once.
    func noDraw(_ count: Int) -> Int {
        Issue.record("a library that holds one candidate must not cost a draw")
        return 0
    }

    @Test func aTitleOfTheChartIsASongOfTheLibrary() {
        let held = Discovery.Held(songs(["Bloodcraft", "Combustion Inferno"]))

        #expect(held.one("Combustion Inferno")?.title == "Combustion Inferno")
        #expect(held.one("Bloodcraft")?.title == "Bloodcraft")
        #expect(held.one("Nothing Here") == nil, "a title the library lacks is no candidate")
        #expect(held.one("") == nil, "an empty title never matches")
        #expect(Discovery.Held([]).one("Bloodcraft") == nil, "an artist with no song in the library has no candidate")
    }

    @Test func anExactNameIsFoundWithoutScanningTheSongs() throws {
        let discovery = try source("Discovery.swift")

        #expect(discovery.contains("if let held = exact[Similarity.normal(letters)] { return held }"), "the common case is one dictionary read, not 300 comparisons")
        #expect(discovery.contains("Similarity.letters(song.title)"), "every song name is folded once, before the titles run")
        #expect(!discovery.contains("Similarity.ratio("), "the ratio pass runs on the letters, so nothing is folded a second time")
    }

    @Test func theClosestNameOfTheLibraryWinsInsideOneTitle() {
        let held = Discovery.Held(songs(["Sandman", "Enter Sandman", "Sandmen"]))

        #expect(held.one("Sandman")?.title == "Sandman", "the exact name beats a near one")
        #expect(held.one("Enter Sandman")?.title == "Enter Sandman")
        #expect(held.one("Wrong Assembly") == nil)
    }

    @Test func anAccentOrACaseChangeIsTheSameSong() {
        #expect(Discovery.choose(["Sabado De Sol"], songs(["sábado de sol"], "Morra"), using: noDraw)?.track.title == "sábado de sol",
                "the library title is what plays, with its own spelling")
        #expect(Discovery.choose(["Ratos de Porao"], songs(["Ratos de Porão"], "Ratos de Porão"), using: noDraw) != nil)
    }

    @Test func everyCandidateOfTheChartIsInTheDraw() {
        let songs = [
            Track(url: URL(fileURLWithPath: "/m/a.mp3"), title: "Bloodcrafts", artist: "A", album: "B", number: 1, disc: 1, albumArtist: "", year: 2000, duration: 100, albumID: "x"),
            Track(url: URL(fileURLWithPath: "/m/b.mp3"), title: "Blood of Lions", artist: "A", album: "B", number: 2, disc: 1, albumArtist: "", year: 2000, duration: 100, albumID: "x"),
        ]

        #expect(Discovery.choose(["Bloodcraft", "Blood of Lions"], songs, using: { _ in 0 })?.track.title == "Bloodcrafts")
        #expect(Discovery.choose(["Bloodcraft", "Blood of Lions"], songs, using: { _ in 1 })?.track.title == "Blood of Lions",
                "a fuzzy match on the higher-ranked title and an exact name lower down are both candidates, so the draw decides")
        #expect(Discovery.choose(["Bloodcraft", "Blood of Lions"], songs, using: { _ in 1 })?.candidates == 2)
    }

    @Test func aSingleCandidateIsTakenWithoutADraw() {
        let match = Discovery.choose(["Nope", "Nada", "Two", "Also Nope", "Neither"], songs(["One", "Two"]), using: noDraw)

        #expect(match?.track.title == "Two")
        #expect(match?.title == "Two", "the spelling of the library is what plays")
        #expect(match?.candidates == 1, "the one title of the top five that the library holds is used directly, so no draw is spent")
    }

    @Test func everyCandidateOfThePoolCanWinTheDraw() {
        let titles = ["One", "Two", "Three"]
        let held = songs(["One", "Two", "Three"])

        for index in titles.indices {
            let match = Discovery.choose(titles, held, using: { _ in index })

            #expect(match?.track.title == titles[index], "the draw reaches every candidate, not only the first")
            #expect(match?.candidates == 3)
        }

        #expect(Discovery.choose(titles, held, using: { _ in 99 })?.track.title == "Three", "a draw past the pool lands on the last candidate, it never traps")
        #expect(Discovery.choose(titles, held, using: { _ in -1 })?.track.title == "One", "and a negative draw lands on the first")
    }

    @Test func anArtistWhoseTopFiveNobodyHasIsSkippedWithoutADraw() {
        #expect(Discovery.choose(["Nope", "Nada"], songs(["One", "Two"]), using: noDraw) == nil, "no candidate, no song, and no draw spent")
        #expect(Discovery.choose([], songs(["One"]), using: noDraw) == nil, "no title from the internet, no song")
        #expect(Discovery.choose(["One"], [], using: noDraw) == nil, "an artist with no song in the library is skipped")
    }

    @Test func twoTitlesThatAreOneSongEnterTheDrawOnce() {
        let draws = Counter()
        let match = Discovery.choose(["Sandman", "Sandmen", "Enter Sandman"], songs(["Sandmen", "Enter Sandman"]), using: { count in
            draws.hit()
            #expect(count == 2, "the pool is the songs the library holds, not the titles it was sent")
            return 1
        })

        #expect(match?.track.title == "Enter Sandman")
        #expect(match?.candidates == 2)
        #expect(draws.value == 1)
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
        #expect(body(discovery, "func pick(_ pool: Pool, _ count: Int) {").contains("if pool == .artists || pool == .bands, !ready"), "a click that cannot work is refused before any request")
        #expect(body(discovery, "func pick(_ pool: Pool, _ count: Int) {").range(of: "!ready")!.lowerBound < body(discovery, "func pick(_ pool: Pool, _ count: Int) {").range(of: "generation += 1")!.lowerBound,
                "a refused click must not retire the discovery that is in flight")
    }

    @Test func aClickAsksTheInternetAtOnceAndKeepsNoCache() throws {
        let discovery = try source("Discovery.swift")

        #expect(!discovery.contains("Persist."), "the discovery is never written to the disk")
        #expect(!discovery.contains("Date(") && !discovery.contains("ContinuousClock"), "no lifetime, no cache")
        #expect(body(discovery, "private func walk(_ pool: Pool, _ count: Int) async -> [Track] {").contains("await lastFM.topArtists(Discovery.reach(count))"), "the artists come from a fresh request, wider than the list so the draw is a draw")
        #expect(body(discovery, "private func walk(_ pool: Pool, _ count: Int) async -> [Track] {").contains("wanted = library.topBands(count)"), "the bands come from the local play counts")
        #expect(body(discovery, "private func walk(_ pool: Pool, _ count: Int) async -> [Track] {").components(separatedBy: "library.songs(by:").count - 1 == 1,
                "one lookup per artist: the band picker brings its own songs, so nothing is looked up twice")
        #expect(discovery.contains("player.random(tracks)\n        NotificationCenter.default.post(name: .discovery, object: nil)"), "the picked songs replace Up Next and the screen follows")
    }

    @Test func theNewestDiscoveryRetiresTheOneBeforeIt() throws {
        let discovery = try source("Discovery.swift")
        let pick = body(discovery, "func pick(_ pool: Pool, _ count: Int) {")

        #expect(pick.contains("generation += 1\n        let mine = generation"), "every click takes a new generation")
        #expect(pick.contains("work?.cancel()"), "an answer in flight is cancelled, so its requests stop")
        #expect(pick.components(separatedBy: "guard mine == self.generation else {").count - 1 == 1, "a late answer is dropped")
        #expect(body(discovery, "private func start(_ tracks: [Track], _ mine: Int, _ pool: Pool, _ count: Int) {").contains("guard mine == generation else {"), "a local pick that lost the race does nothing")
        #expect(discovery.contains("\"discovery superseded\""), "a dropped answer leaves a trace")
    }

    @Test func everyPoolPlaysThroughOneDoor() throws {
        let discovery = try source("Discovery.swift")
        let pick = body(discovery, "func pick(_ pool: Pool, _ count: Int) {")

        #expect(pick.components(separatedBy: "start(").count - 1 == 4, "songs, never played, most played, and the two network pools")
        #expect(pick.components(separatedBy: "player.random").count - 1 == 0, "only start plays, so no pool can skip the rule")
        #expect(body(discovery, "private func start(_ tracks: [Track], _ mine: Int, _ pool: Pool, _ count: Int) {").contains("guard !tracks.isEmpty else {"), "an empty answer leaves the player alone")
    }

    @Test func theLastFMPickersAreInTheDiscoveryMenu() throws {
        let menu = try discovery(try source("Views.swift"))

        #expect(menu.contains("Menu(\"Last.fm Artists\") {"))
        #expect(menu.contains("Menu(\"Top Bands (\\(library.bands))\") {"), "the band picker says how many bands have a count")
        #expect(menu.components(separatedBy: "values(nil) { discovery.pick(.artists, $0) }").count - 1 == 1)
        #expect(menu.components(separatedBy: "values(nil) { discovery.pick(.bands, $0) }").count - 1 == 1)
        #expect(menu.components(separatedBy: ".disabled(!discovery.ready").count - 1 == 2, "off without a Last.fm account, and no second request while one is in flight")
        #expect(menu.contains(".disabled(!discovery.ready || discovery.running)"), "the artist picker")
        #expect(menu.contains(".disabled(!discovery.ready || discovery.running || library.bands == 0)"), "the band picker")
        #expect(menu.contains("|| library.bands == 0)"), "nothing played disables the band picker")
        #expect(menu.contains("Divider()"), "the local pickers are apart from the ones that spend a request")
        #expect(!menu.contains("Persist."), "the menu reads nothing from the disk")
    }

    @Test func aCancelledDiscoveryStopsAsking() async {
        let asked = Counter()
        let wanted = (0..<24).map { ("Artist \($0)", songs(["Song \($0)"], "Artist \($0)")) }

        let task = Task {
            await Discovery.collect(24, wanted) { name in
                asked.hit()
                try? await Task.sleep(for: .milliseconds(20))
                return [name.replacingOccurrences(of: "Artist", with: "Song")]
            }
        }
        task.cancel()
        let found = await task.value

        #expect(asked.value <= Discovery.window, "a cancelled walk stops at the window it was in, it does not spend the rest")
        #expect(found.isEmpty, "a cancelled walk returns nothing")
    }

    @Test func theChartIsReadFourArtistsAtATime() throws {
        let discovery = try source("Discovery.swift")

        let walk = body(discovery, "nonisolated static func collect(_ count: Int, _ wanted: [(name: String, songs: [Track])],")

        #expect(Discovery.window == 4, "Last.fm answers 29 when one IP spends its rate")
        #expect(Discovery.tracks == 5, "the five most played songs of an artist are the pool a title comes from")
        #expect(!discovery.contains("attempts"), "the candidates are known before the first draw, so nothing is drawn again and nothing is retried")
        #expect(body(discovery, "nonisolated static func choose(").contains("guard candidates.count > 1 else {"), "one candidate is taken at once, and only more than one is drawn")
        #expect(body(discovery, "nonisolated static func choose(").contains("$0.track.id == track.id"), "two titles that are the same song enter the draw once")
        #expect(walk.contains("min(start + min(window, count - found.count), names.count)"), "a discovery of one song asks one artist, not a whole window")
        #expect(walk.contains("start += slice.count"), "the walk advances by the artists it asked, so none is skipped")
        #expect(walk.contains("found.count < count"), "the walk stops as soon as the list is full")
        #expect(walk.components(separatedBy: "guard !Task.isCancelled else {").count - 1 == 1, "a cancelled walk stops asking, in the window loop")
        #expect(discovery.contains("guard !Task.isCancelled else {"), "and before the first request of the walk")
    }

    @Test func theWalkNeverAsksMoreThanItNeeds() async {
        let asked = Counter()
        let wanted = (0..<12).map { ("Artist \($0)", songs(["Song \($0)"], "Artist \($0)")) }

        _ = await Discovery.collect(1, wanted) { name in
            asked.hit()
            return [name.replacingOccurrences(of: "Artist", with: "Song")]
        }
        #expect(asked.value == 1, "one song asked for is one artist asked about")

        let counter = Counter()
        _ = await Discovery.collect(6, wanted) { _ in
            counter.hit()
            return []
        }
        #expect(counter.value == 12, "nothing matches, so every artist is asked, four at a time and never skipped")
    }

    @Test func theArtistsAreDrawnFromAWiderPool() {
        #expect(Discovery.reach(1) == 20, "one song is drawn from twenty artists, not from the one at the top")
        #expect(Discovery.reach(4) == 20)
        #expect(Discovery.reach(10) == 50)
        #expect(Discovery.reach(100) == 200, "the service caps the page, so the pool stops there")
    }

    @Test func everyArtistOfThePoolCanBeDrawn() {
        let chart = ["A", "B", "C", "D", "E"]

        for target in chart.indices {
            #expect(Discovery.draw(chart, 1, using: { _ in target }) == [chart[target]], "the draw reaches the whole pool, not its head")
        }
        let head = Discovery.draw(chart, 3, using: { _ in 0 })
        #expect(head.count == 3 && head[0] == "A", "each draw takes one name out of the pool")
        #expect(Discovery.draw(chart, 3, using: { $0 - 1 }) == ["E", "D", "C"], "and the last name of what is left")
        #expect(Discovery.draw(chart, 5, using: { _ in 2 }).count == 5)
        #expect(Set(Discovery.draw(chart, 5, using: { _ in 2 })).count == 5, "an artist never comes twice in one discovery")
        #expect(Discovery.draw(chart, 9, using: { _ in 0 }).count == 5, "the pool has no more names than it has")
        #expect(Discovery.draw(["A", "A", "B"], 2, using: { _ in 0 }) == ["A", "B"], "a name the chart repeats is drawn once")
        #expect(Discovery.draw(chart, 0, using: { _ in 0 }).isEmpty)
        #expect(Discovery.draw([], 3, using: { _ in 0 }).isEmpty)
    }

    @Test func theWalkDrawsInsideTheCandidatesOfEachArtist() async {
        let wanted = [("A", songs(["One", "Two"], "A")), ("B", songs(["Three"], "B"))]
        let picked = await Discovery.collect(2, wanted, draw: { _ in 1 }) { name in
            name == "A" ? ["One", "Two"] : ["Nope", "Three"]
        }

        #expect(picked.map(\.title) == ["Two", "Three"], "A is drawn from its two candidates, B takes its only one with no draw")
    }

    @Test func theArtistPageIsPercentEncoded() {
        #expect(LastFM.artistPage("Motörhead")?.absoluteString == "https://www.last.fm/music/Mot%C3%B6rhead")
        #expect(LastFM.artistPage("AC/DC")?.absoluteString == "https://www.last.fm/music/AC%2FDC", "a slash is part of the name, not of the path")
        #expect(LastFM.artistPage("Calibre 12")?.absoluteString == "https://www.last.fm/music/Calibre%2012")
        #expect(LastFM.artistPage("") == nil, "no name, no page")
    }

    @Test func theArtistPageFollowsTheSpellingOfLastFM() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        Chart.reset([], [:], known: ["calibre 12": "Calibre 12", "ac/dc": "AC/DC"])

        let lastFM = client()
        let page = try #require(await lastFM.artistURL("calibre 12"))

        #expect(page.known, "the name the app has is not the name the service keeps")
        #expect(page.url.absoluteString == "https://www.last.fm/music/Calibre%2012", "the page is the one of the spelling that Last.fm answers")
        #expect(Chart.calls == ["artist.getInfo"], "one request, and the spelling comes from the service")

        let slash = try #require(await lastFM.artistURL("ac/dc"))
        #expect(slash.url.absoluteString == "https://www.last.fm/music/AC%2FDC")
    }

    @Test func anArtistLastFMDoesNotKnowFallsBackToItsPage() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        Chart.reset([], [:], offline: false)

        let lastFM = client()
        let page = try #require(await lastFM.artistURL("Banda Que Nao Existe"))

        #expect(!page.known, "the service answered that the artist does not exist")
        #expect(page.url.absoluteString == "https://www.last.fm/music/Banda%20Que%20Nao%20Existe", "the 404 page of the service, under the name the app has")
        #expect(Chart.calls == ["artist.getInfo"])

        Chart.reset([], [:], offline: true)
        let offline = try #require(await lastFM.artistURL("Death"))
        #expect(!offline.known, "an answer that never comes is not an artist")
        #expect(offline.url.absoluteString == "https://www.last.fm/music/Death", "the browser still gets a page")
    }

    @Test func everyHostOfTheSongMenuCarriesTheAccount() throws {
        let app = try source("Overdrive.swift")

        let menu = try #require(app.range(of: "CommandMenu(\"Song\") {")).upperBound
        #expect(String(app[menu...].prefix(600)).contains(".environment(lastFM)"), "the Song menu builds GoMenu, which reads the account: without it the app traps at launch")

        let content = try #require(app.range(of: "ContentView()")).upperBound
        #expect(String(app[content...].prefix(600)).contains(".environment(lastFM)"), "the main window builds GoMenu too")
    }

    @Test func theLastFMPageIsOfferedOnlyWithAnAccount() throws {
        let views = try source("Views.swift")
        let menu = body(views, "struct GoMenu: View {")

        #expect(menu.contains("Button(\"Go to Last.fm\") { lastFM.openArtist(track.artist) }"), "the song menu opens the artist page")
        #expect(menu.contains(".disabled(lastFM.user.isEmpty)"), "no account, no Last.fm page")
        #expect(menu.contains("@Environment(LastFM.self) private var lastFM"), "the menu reads the account")

        let lastFM = try source("LastFM.swift")
        #expect(body(lastFM, "func openArtist(_ artist: String) {").contains("guard !user.isEmpty else {"), "a click without an account spends no request")
        #expect(body(lastFM, "func openArtist(_ artist: String) {").contains("NSWorkspace.shared.open"), "the default browser opens the page")
        #expect(body(lastFM, "func artistURL(_ artist: String) async -> (url: URL, known: Bool)? {").contains("call(\"artist.getInfo\""), "the spelling comes from the API before the browser opens")
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
