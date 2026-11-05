import Foundation
import Testing
@testable import Overdrive

/// What one fake service answers, and what it saw. Each test gets its own, so
/// a request a previous test left in flight cannot land on the wrong one.
final class SimilarStub: @unchecked Sendable {
    nonisolated(unsafe) private static var registry: [String: SimilarStub] = [:]
    private static let gate = NSLock()

    let host: String

    private let lock = NSLock()
    private var _similar: [[String: Any]] = []
    private var _infos: [String: [String: Any]] = [:]
    private var _calls: [(method: String, artist: String)] = []
    private var _fail = false
    private var _slow = false
    private var _slowInfo = false
    private var _once29 = false
    private var _infoNow = 0
    private var _infoPeak = 0

    init() {
        host = "similar-\(UUID().uuidString).invalid"
        Self.gate.withLock { Self.registry[host] = self }
    }

    static func lookup(_ url: URL?) -> SimilarStub? {
        guard let host = url?.host else { return nil }
        return Self.gate.withLock { registry[host] }
    }

    var endpoint: URL { URL(string: "https://\(host)/2.0/")! }

    var calls: [(method: String, artist: String)] { lock.withLock { _calls } }

    var counts: (similar: Int, info: Int) {
        lock.withLock { (_calls.filter { $0.method == "artist.getSimilar" }.count, _calls.filter { $0.method == "artist.getInfo" }.count) }
    }

    func similar(_ artists: [[String: Any]]) { lock.withLock { _similar = artists } }
    func infos(_ value: [String: [String: Any]]) { lock.withLock { _infos = value } }
    func fail(_ value: Bool) { lock.withLock { _fail = value } }
    func slow(_ value: Bool) { lock.withLock { _slow = value } }
    func slowInfo(_ value: Bool) { lock.withLock { _slowInfo = value } }
    func failInfoOnce() { lock.withLock { _once29 = true } }
    func clear() { lock.withLock { _calls = [] } }

    var infoPeak: Int { lock.withLock { _infoPeak } }

    func arrive(_ method: String) {
        lock.withLock {
            guard method == "artist.getInfo" else { return }
            _infoNow += 1
            _infoPeak = max(_infoPeak, _infoNow)
        }
    }

    func depart(_ method: String) {
        lock.withLock { if method == "artist.getInfo" { _infoNow -= 1 } }
    }

    func delay(_ method: String) -> TimeInterval {
        lock.withLock {
            if _slow && method == "artist.getSimilar" { return 0.3 }
            if _slowInfo && method == "artist.getInfo" { return 0.08 }
            return 0
        }
    }

    func reply(_ form: [String: String]) -> Any {
        lock.withLock {
            let method = form["method"] ?? ""
            let artist = form["artist"] ?? ""
            _calls.append((method, artist))

            switch method {
            case "artist.getSimilar":
                guard !_fail else { return ["error": 6, "message": "The artist you supplied could not be found"] }
                return ["similarartists": ["artist": _similar, "@attr": ["artist": artist]]]
            case "artist.getInfo":
                if _once29 { _once29 = false; return ["error": 29, "message": "Your service limit was exceeded"] }
                return ["artist": _infos[artist] ?? ["name": artist]]
            default:
                return [:]
            }
        }
    }
}

/// One instance per request, started once, answered once: the sendable claim
/// is by that rule. (The compiler still warns because `URLProtocol` marks its
/// own sendability unavailable; the fake never shares an instance.)
private final class SimilarFake: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let stub = SimilarStub.lookup(request.url) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }

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

        let method = form["method"] ?? ""
        let sent = form
        let wait = stub.delay(method)
        stub.arrive(method)

        let send: @Sendable () -> Void = {
            let data = try! JSONSerialization.data(withJSONObject: stub.reply(sent))
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
            stub.depart(method)
        }

        if wait > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + wait, execute: send) } else { send() }
    }
}

/// How many requests run at once, and how many ran at all.
private final class Peak: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var best = 0
    private var total = 0

    var value: Int { lock.withLock { best } }
    var hits: Int { lock.withLock { total } }

    func enter() { lock.withLock { now += 1; total += 1; best = max(best, now) } }
    func leave() { lock.withLock { now -= 1 } }
}

@MainActor
@Suite(.serialized)
struct SimilarTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "OverdriveSimilar")
    let stub = SimilarStub()

    init() {
        try? FileManager.default.removeItem(at: directory)
    }

    func lastFM(user: String = "tester") -> LastFM {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [SimilarFake.self]

        var configuration = LastFM.Configuration()
        configuration.endpoint = stub.endpoint
        configuration.credentials = directory.appending(path: "lastfm.plist")
        configuration.store = directory.appending(path: "Scrobbles.plist")
        configuration.transport = URLSession(configuration: session)
        configuration.retry = .seconds(3600)
        configuration.recover = .milliseconds(30)
        configuration.monitor = false

        let lastFM = LastFM(configuration)
        lastFM.session = "key"
        lastFM.user = user
        return lastFM
    }

    func harness(user: String = "tester") -> (LastFM, Similar) {
        let lastFM = self.lastFM(user: user)
        let similar = Similar(lastFM: lastFM)
        similar.space = .zero
        similar.artwork = { _ in nil }
        return (lastFM, similar)
    }

    func track(_ title: String, _ artist: String) -> Track {
        Track(url: URL(fileURLWithPath: "/m/\(artist)/\(title).mp3"), title: title, artist: artist, album: "Album", number: 1, disc: 1,
              albumArtist: "", year: 2000, duration: 200, albumID: "x")
    }

    func photo(_ name: String) -> [[String: Any]] {
        [["#text": "http://example.invalid/34/\(name).png", "size": "small"], ["#text": "https://example.invalid/300/\(name).png", "size": "extralarge"]]
    }

    static let silhouette = "https://lastfm-img.freetls.fastly.net/i/u/300x300/2a96cbd8b46e442fc41c2b86b821562f.png"

    func stub(_ names: [String], picture: String? = nil) {
        let images: (String) -> [[String: Any]]
        if let picture {
            images = { _ in [["#text": picture, "size": "extralarge"]] }
        } else {
            images = photo
        }
        stub.similar(names.map { ["name": $0, "url": "https://www.last.fm/music/\($0)", "image": images($0)] })
        // The service writes the counts under `stats`.
        stub.infos(Dictionary(uniqueKeysWithValues: names.map { ($0, ["name": $0, "stats": ["listeners": "1234"], "tags": ["tag": [["name": "rock"]]], "image": images($0)]) }))
    }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the panel never settled")
    }

    @Test func itStartsOnTheLyrics() {
        let (_, similar) = harness()
        similar.show(track("One", "Metallica"))

        #expect(similar.tab == .lyrics, "the lyrics are the default")
        #expect(!similar.loading)
        #expect(stub.calls.isEmpty)
    }

    @Test func theSimilarTabListsArtistsWithPhotoGenreAndListeners() async {
        stub((1...12).map { "Band \($0)" })
        let (_, similar) = harness()
        similar.show(track("One", "Metallica"))
        similar.select(.similar)

        await settle { similar.artists.count == 10 && similar.artists.allSatisfy { $0.listeners != nil && $0.genre != nil && $0.image != nil } }

        #expect(similar.artists.count == 10, "the tab shows the top ten, not more")
        #expect(similar.artists[0].name == "Band 1")
        #expect(similar.artists[0].genre == "rock")
        #expect(similar.artists[0].listeners == 1234)
        #expect(similar.artists[0].image?.absoluteString == "https://example.invalid/300/Band%201.png", "the biggest photo, over https")
        let counts = stub.counts
        #expect(counts.similar == 1, "the list costs one request")
        #expect(counts.info == 10, "the genre and the listeners cost one request per artist")
    }

    @Test func aSongOfTheSameArtistKeepsTheTab() async {
        stub(["Band 1"])
        let (_, similar) = harness()
        similar.show(track("One", "Metallica"))
        similar.select(.similar)
        await settle { similar.artists.count == 1 && similar.artists[0].listeners != nil }
        stub.clear()

        similar.show(track("Two", "Metallica"))

        #expect(similar.tab == .similar, "a new song of the same artist never takes the panel back to the lyrics")
        #expect(similar.artists.count == 1, "and it never asks the service again")
        #expect(stub.calls.isEmpty)
    }

    @Test func aNewArtistGoesBackToTheLyrics() async {
        stub((1...10).map { "Band \($0)" })
        let (_, similar) = harness()
        similar.show(track("One", "Metallica"))
        similar.select(.similar)
        await settle { !similar.loading && !similar.artists.isEmpty }

        similar.show(track("One", "Slayer"))

        #expect(similar.tab == .lyrics, "a new artist takes the panel back to the lyrics")
        #expect(similar.artists.isEmpty, "and the list of the old artist goes with it")
        #expect(!similar.loading)
    }

    @Test func theArtistLineIgnoresCaseAndAccents() async {
        stub(["Band 1"])
        let (_, similar) = harness()
        similar.show(track("One", "Metallica"))
        similar.select(.similar)
        await settle { similar.artists.count == 1 && similar.artists[0].listeners != nil }

        similar.show(track("Two", "metallica"))

        #expect(similar.tab == .similar, "the same artist under another spelling is the same artist")
    }

    @Test func withoutAnAccountThereIsNoTab() {
        let (_, similar) = harness(user: "")
        similar.show(track("One", "Metallica"))

        #expect(!similar.available, "the tabs only exist with a connected account")
        similar.select(.similar)
        #expect(similar.tab == .lyrics, "and the tab cannot even be chosen without one")
        #expect(stub.calls.isEmpty)
    }

    @Test func clickingBackAndForthKeepsTheList() async {
        stub((1...10).map { "Band \($0)" })
        let (_, similar) = harness()
        similar.show(track("One", "Metallica"))
        similar.select(.similar)
        await settle { similar.artists.count == 10 && similar.artists.allSatisfy { $0.listeners != nil } }

        similar.select(.lyrics)
        similar.select(.similar)
        await settle { !similar.loading }

        #expect(stub.counts.similar == 1, "the artist that is showing is not asked for twice")
        #expect(similar.artists.count == 10)
    }

    @Test func aFailedListIsNotKeptAsAnAnswer() async {
        stub(["Band 1"])
        let (_, similar) = harness()
        similar.show(track("One", "Metallica"))
        stub.fail(true)
        similar.select(.similar)
        await settle { !similar.loading }
        #expect(similar.artists.isEmpty)

        stub.fail(false)
        similar.reload()
        await settle { similar.artists.count == 1 && similar.artists[0].listeners != nil }

        #expect(stub.counts.similar == 2, "a retry asks the service again: an empty answer is not cached")
    }

    @Test func aSongWithNoArtistIsNoRequest() async {
        let (_, similar) = harness()
        similar.show(track("One", ""))
        similar.select(.similar)

        #expect(similar.tab == .similar, "the tab shows, but with nothing to ask for")
        similar.reload()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(stub.calls.isEmpty, "an empty artist spends no request")
    }

    @Test func aLateAnswerNeverReplacesTheNewArtist() async {
        stub(["Band 1"])
        let (_, similar) = harness()
        stub.slow(true)

        similar.show(track("One", "Metallica"))
        similar.select(.similar)
        similar.show(track("One", "Slayer"))
        try? await Task.sleep(for: .milliseconds(500))

        #expect(similar.artists.isEmpty, "the answer for the artist that left the screen must not land")
        #expect(similar.tab == .lyrics)
        #expect(stub.counts.info == 0, "and nothing keeps asking after it")
    }

    @Test func theDefaultPhotoIsNoPhoto() async {
        // The API answers the same silhouette for every artist for years: a row
        // must not keep it, or no real photo can come after it.
        stub(["Band 1"], picture: Self.silhouette)
        let (lastFM, _) = harness()

        #expect(await lastFM.similar("Metallica", 10).first?.image == nil, "the list drops the silhouette")
        #expect(await lastFM.artistInfo("Band 1")?.image == nil, "and so does the artist info")
    }

    @Test func aRowWithoutAPhotoTakesTheSearchArtwork() async {
        stub(["Band 1"], picture: Self.silhouette)
        let (_, similar) = harness()
        similar.artwork = { name in URL(string: "https://art.invalid/300/\(name).jpg") }
        similar.show(track("One", "Metallica"))
        similar.select(.similar)

        await settle { similar.artists.first?.image?.absoluteString == "https://art.invalid/300/Band%201.jpg" }

        #expect(similar.artists.first?.image?.absoluteString == "https://art.invalid/300/Band%201.jpg", "the artist gets a real photo")
    }

    @Test func theDataAndThePhotosComeTogether() async {
        stub((1...10).map { "Band \($0)" }, picture: Self.silhouette)
        let peak = Peak()
        let (_, similar) = harness()
        stub.slowInfo(true)
        similar.artwork = { name in
            peak.enter()
            try? await Task.sleep(for: .milliseconds(30))
            peak.leave()
            return URL(string: "https://art.invalid/\(name).jpg")
        }
        similar.show(track("One", "Metallica"))
        similar.select(.similar)

        await settle { similar.artists.count == 10 && similar.artists.allSatisfy { $0.image != nil && $0.listeners != nil && $0.genre != nil } }

        #expect(peak.value >= 2, "the photos are asked together, not one after the other")
        #expect(peak.value <= Similar.lanes, "and never more than the lanes of the CPU limit")
        #expect(peak.hits == 10, "every row without a photo asks once")
        #expect(stub.infoPeak >= 2, "the artist data is asked together too, not in a line")
        #expect(stub.counts.info == 10, "one request per artist, no more")
    }

    @Test func aRateLimitedArtistInfoIsAskedOnceMore() async {
        stub(["Band 1"])
        let (_, similar) = harness()
        stub.failInfoOnce()
        similar.show(track("One", "Metallica"))
        similar.select(.similar)

        await settle { similar.artists.first?.listeners != nil }

        #expect(stub.counts.info == 2, "a code 29 is asked again, once")
    }

    @Test func aRealPhotoFromTheServiceIsNeverAskedForAgain() async {
        stub((1...4).map { "Band \($0)" })
        let asks = Peak()
        let (_, similar) = harness()
        similar.artwork = { _ in
            asks.enter()
            return nil
        }
        similar.show(track("One", "Metallica"))
        similar.select(.similar)

        await settle { !similar.loading && similar.artists.count == 4 && similar.artists.allSatisfy { $0.listeners != nil } }

        #expect(asks.hits == 0, "a row that already has a real photo spends no search")
    }

    @Test func theCoverTakesTheArtistsOwnAnswerInStoreOrder() {
        let answers = [
            (name: "Cover Megadeth Tribute", art: "https://example.invalid/cover.jpg"),
            (name: "MEGADETH", art: "https://example.invalid/megadeth.jpg"),
            (name: "Megadeth Fan Club", art: "https://example.invalid/fan.jpg"),
        ]

        #expect(Similar.cover(answers, "Megadeth")?.art == "https://example.invalid/megadeth.jpg", "the folded exact name wins over the store's first answer")
        #expect(Similar.cover(answers, "megadeth")?.name == "MEGADETH", "case and accents score nothing")
        let near: [(name: String, art: String)] = [
            (name: "Nothing Here", art: "a"),
            (name: "Megadeth Live", art: "b"),
        ]
        #expect(Similar.cover(near, "Megadeth")?.art == "b", "no exact name takes one that starts with it")
        let alike: [(name: String, art: String)] = [
            (name: "Totally Different", art: "a"),
            (name: "Beastie Boy", art: "b"),
        ]
        #expect(Similar.cover(alike, "Beastie Boys")?.art == "b", "a store name close to the one asked gives its cover")
        #expect(Similar.cover(answers, "Anything Else") == nil, "with nothing alike no answer is taken")
        let nothing: [(name: String, art: String)] = []
        #expect(Similar.cover(nothing, "Megadeth") == nil, "no answers, no cover")
    }

    @Test func theCoverNeverBorrowsTheTopHitOfALooseSearch() {
        // The shape the store really answers when asked for Empire of Souls:
        // Iron Maiden first, for the song "Empire of the Clouds", and no
        // answer is the band. The old walk took the first answer, and the
        // row showed the Maiden cover.
        let loose: [(name: String, art: String)] = [
            (name: "Iron Maiden", art: "https://example.invalid/maiden.jpg"),
            (name: "Morifade", art: "https://example.invalid/morifade.jpg"),
            (name: "FESTA DAVIDE", art: "https://example.invalid/festa.jpg"),
        ]

        #expect(Similar.cover(loose, "Empire of Souls") == nil, "an artist the store does not hold borrows no cover")
    }

    @Test func thePageOfARowIsTheOneTheServiceAnswered() throws {
        let answered = Similar.Entry(name: "Band 1", url: URL(string: "https://www.last.fm/music/Band%201"), image: nil)
        #expect(Similar.page(answered) == URL(string: "https://www.last.fm/music/Band%201"))

        let bare = Similar.Entry(name: "Band 1", url: nil, image: nil)
        #expect(Similar.page(bare) == LastFM.artistPage("Band 1"), "a row with no page opens the page of its name")
    }

    @Test func thePhotoPicksTheBiggestSizeAndSecuresTheAddress() {
        let images: [[String: Any]] = [
            ["#text": "http://example.invalid/34/a.png", "size": "small"],
            ["#text": "http://example.invalid/174/a.png", "size": "large"],
            ["#text": "https://example.invalid/300/a.png", "size": "extralarge"],
        ]
        #expect(LastFM.photo(images)?.absoluteString == "https://example.invalid/300/a.png")
        #expect(LastFM.photo([["#text": "http://example.invalid/126/a.png", "size": "large"]])?.absoluteString == "https://example.invalid/126/a.png", "an http photo becomes https")
        #expect(LastFM.photo([["#text": "", "size": "small"], ["#text": "//example.invalid/64/a.png", "size": "medium"]])?.absoluteString == "https://example.invalid/64/a.png", "an empty size is not a photo")
        #expect(LastFM.photo(nil) == nil)
        #expect(LastFM.secure("www.last.fm/music/Metallica")?.absoluteString == "https://www.last.fm/music/Metallica")
        #expect(LastFM.secure("mailto:nobody@example.invalid") == nil, "only https pages and photos")
        #expect(LastFM.isDefault(URL(string: Self.silhouette)), "and the silhouette is known")
    }

    @Test func oneArtistInfoCarriesListenersAndTheFirstTag() async {
        // The service puts the counts under `stats` now, and older answers held
        // them at the top: the app reads both.
        stub.infos([
            "Band 1": ["name": "Band 1", "stats": ["listeners": "987"], "tags": ["tag": ["name": "metal"]], "image": photo("Band 1")],
            "Band 2": ["name": "Band 2", "listeners": "42"],
        ])
        let (lastFM, _) = harness()

        let info = await lastFM.artistInfo("Band 1")
        #expect(info?.listeners == 987, "Last.fm writes counts as strings")
        #expect(info?.tag == "metal", "a lone tag arrives as one object, not a list")
        #expect(info?.image?.absoluteString == "https://example.invalid/300/Band%201.png")
        #expect(await lastFM.artistInfo("Band 2")?.listeners == 42, "the old place still works")
        #expect(await lastFM.artistInfo("") == nil, "no name, no request")
    }

    @Test func theListStopsAtTenAndSurvivesOddAnswers() async {
        stub.similar([
            ["name": "Band 1", "image": photo("Band 1")],
            ["name": "", "url": "https://www.last.fm/music/x"],
            ["name": "Band 2", "url": "http://www.last.fm/music/Band%202"],
        ])
        let (lastFM, _) = harness()

        let found = await lastFM.similar("Metallica", Similar.top)
        #expect(found.map(\.name) == ["Band 1", "Band 2"], "an artist with no name is not an artist")
        #expect(found[1].url?.absoluteString == "https://www.last.fm/music/Band%202", "the page arrives over https")
        #expect(await lastFM.similar("Metallica", 1).count == 1, "the count is a cap")
        #expect(await lastFM.similar("", 10).isEmpty, "an empty artist spends no request")
    }
}
