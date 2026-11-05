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
    func clear() { lock.withLock { _calls = [] } }

    func delay(_ method: String) -> Bool { lock.withLock { _slow && method == "artist.getSimilar" } }

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
                return ["artist": _infos[artist] ?? ["name": artist]]
            default:
                return [:]
            }
        }
    }
}

private final class SimilarFake: URLProtocol {
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

        if stub.delay(form["method"] ?? "") { Thread.sleep(forTimeInterval: 0.3) }

        let data = try! JSONSerialization.data(withJSONObject: stub.reply(form))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
@Suite(.serialized)
struct SimilarTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "OverdriveSimilar-\(UUID().uuidString)")
    let stub = SimilarStub()

    func lastFM(user: String = "tester") -> LastFM {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [SimilarFake.self]

        var configuration = LastFM.Configuration()
        configuration.endpoint = stub.endpoint
        configuration.credentials = directory.appending(path: "lastfm.plist")
        configuration.store = directory.appending(path: "Scrobbles.plist")
        configuration.transport = URLSession(configuration: session)
        configuration.retry = .seconds(3600)
        configuration.monitor = false

        let lastFM = LastFM(configuration)
        lastFM.session = "key"
        lastFM.user = user
        return lastFM
    }

    func harness(user: String = "tester") -> (LastFM, Similar) {
        let lastFM = self.lastFM(user: user)
        let similar = Similar(lastFM: lastFM)
        similar.gap = .zero
        return (lastFM, similar)
    }

    func track(_ title: String, _ artist: String) -> Track {
        Track(url: URL(fileURLWithPath: "/m/\(artist)/\(title).mp3"), title: title, artist: artist, album: "Album", number: 1, disc: 1,
              albumArtist: "", year: 2000, duration: 200, albumID: "x")
    }

    func photo(_ name: String) -> [[String: Any]] {
        [["#text": "http://example.invalid/34/\(name).png", "size": "small"], ["#text": "https://example.invalid/300/\(name).png", "size": "extralarge"]]
    }

    func stub(_ names: [String]) {
        stub.similar(names.map { ["name": $0, "url": "https://www.last.fm/music/\($0)", "image": photo($0)] })
        stub.infos(Dictionary(uniqueKeysWithValues: names.map { ($0, ["name": $0, "listeners": "1234", "tags": ["tag": [["name": "rock"]]], "image": photo($0)]) }))
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

        await settle { !similar.loading && similar.artists.count == 10 && similar.artists.allSatisfy { $0.listeners != nil && $0.genre != nil && $0.image != nil } }

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
        await settle { !similar.loading && similar.artists.count == 1 && similar.artists[0].listeners != nil }
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
        await settle { !similar.loading }

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
        await settle { !similar.loading && similar.artists.count == 1 && similar.artists[0].listeners != nil }

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
        await settle { !similar.loading && similar.artists.allSatisfy { $0.listeners != nil } }

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
    }

    @Test func oneArtistInfoCarriesListenersAndTheFirstTag() async {
        stub.infos(["Band 1": ["name": "Band 1", "listeners": "987", "tags": ["tag": ["name": "metal"]], "image": photo("Band 1")]])
        let (lastFM, _) = harness()

        let info = await lastFM.artistInfo("Band 1")
        #expect(info?.listeners == 987, "Last.fm writes counts as strings")
        #expect(info?.tag == "metal", "a lone tag arrives as one object, not a list")
        #expect(info?.image?.absoluteString == "https://example.invalid/300/Band%201.png")
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
