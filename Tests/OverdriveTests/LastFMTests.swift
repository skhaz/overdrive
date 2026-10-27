import Foundation
import Testing
@testable import Overdrive

final class Server: @unchecked Sendable {
    enum Mode {
        case ok
        case unsent
        case down
        case error(Int)
        case broken
        case limit(Set<String>)
        case invalid(String)
        case filtered([String: Int])
        case lost(keep: Int)
    }

    enum Reply {
        case json(Any)
        case status(Int, Data)
        case failure(URLError)
    }

    nonisolated(unsafe) static var current = Server()

    private let lock = NSLock()
    private var _mode = Mode.ok
    private var _history = true
    private var _received: [(track: String, timestamp: Int)] = []
    private var _batches: [Int] = []
    private var _store: URL?
    private var _snapshot: Data?

    var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    var history: Bool {
        get { lock.withLock { _history } }
        set { lock.withLock { _history = newValue } }
    }

    var store: URL? {
        get { lock.withLock { _store } }
        set { lock.withLock { _store = newValue } }
    }

    var snapshot: Data? { lock.withLock { _snapshot } }
    var received: [String] { lock.withLock { _received.map(\.track) } }
    var batches: [Int] { lock.withLock { _batches } }

    func reply(_ form: [String: String]) -> Reply {
        lock.withLock {
            switch form["method"] {
            case "track.updateNowPlaying":
                return .json(["nowplaying": [:]])
            case "user.getRecentTracks":
                guard _history else { return .failure(URLError(.timedOut)) }

                let low = Int(form["from"] ?? "") ?? 0
                let high = Int(form["to"] ?? "") ?? .max
                let tracks = _received.filter { (low...high).contains($0.timestamp) }.map { ["name": $0.track, "date": ["uts": String($0.timestamp)]] }
                return .json(["recenttracks": ["track": tracks, "@attr": ["totalPages": "1"]]])
            default:
                break
            }

            let batch = (0..<50).compactMap { index -> (track: String, timestamp: Int)? in
                guard let track = form["track[\(index)]"], let timestamp = form["timestamp[\(index)]"].flatMap(Int.init) else { return nil }
                return (track, timestamp)
            }
            _batches.append(batch.count)
            if let _store { _snapshot = try? Data(contentsOf: _store) }

            switch _mode {
            case .unsent:
                return .failure(URLError(.notConnectedToInternet))
            case .down:
                return .status(503, Data("<html><body>503 Service Unavailable</body></html>".utf8))
            case .broken:
                return .status(500, Data("{}".utf8))
            case .error(let code):
                return .json(["error": code, "message": "Error \(code)"])
            case .invalid(let track) where batch.contains { $0.track == track }:
                return .json(["error": 6, "message": "Invalid parameters"])
            case .lost(let keep):
                _received += batch.prefix(keep)
                _mode = .ok
                return .failure(URLError(.networkConnectionLost))
            default:
                break
            }

            var items: [[String: Any]] = []

            for entry in batch {
                var code = 0
                if case .limit(let tracks) = _mode, tracks.contains(entry.track) { code = 5 }
                if case .filtered(let codes) = _mode { code = codes[entry.track] ?? 0 }
                if code == 0 { _received.append(entry) }
                items.append(["track": ["#text": entry.track], "ignoredMessage": ["code": String(code), "#text": ""]])
            }

            return .json(["scrobbles": ["scrobble": items, "@attr": ["accepted": items.count, "ignored": 0]]])
        }
    }
}

final class Fake: URLProtocol {
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

        switch Server.current.reply(form) {
        case .json(let object):
            respond(200, try! JSONSerialization.data(withJSONObject: object))
        case .status(let code, let data):
            respond(code, data)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func respond(_ code: Int, _ data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
@Suite(.serialized)
struct LastFMTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "OverdriveTests-\(UUID().uuidString)")

    init() {
        Server.current = Server()
    }

    func client(settle: TimeInterval = 0) -> LastFM {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [Fake.self]

        var configuration = LastFM.Configuration()
        configuration.endpoint = URL(string: "https://example.invalid/2.0/")!
        configuration.credentials = directory.appending(path: "lastfm.plist")
        configuration.store = directory.appending(path: "Scrobbles.plist")
        configuration.transport = URLSession(configuration: session)
        configuration.retry = .seconds(3600)
        configuration.settle = settle
        configuration.monitor = false

        let lastFM = LastFM(configuration)
        if lastFM.session.isEmpty {
            lastFM.session = "key"
            lastFM.user = "tester"
        }

        return lastFM
    }

    func track(_ title: String) -> Track {
        Track(url: URL(filePath: "/Music/\(title).m4a"), title: title, artist: "Artist", album: "Album", number: 1, disc: 1,
              albumArtist: "", year: 2000, duration: 240, albumID: "album")
    }

    func scrobble(_ lastFM: LastFM, _ titles: [String], ago: TimeInterval = 3600) {
        for (index, title) in titles.enumerated() {
            lastFM.scrobble(track(title), at: Date.now.addingTimeInterval(-ago + Double(index) * 300))
        }
    }

    func settle(_ lastFM: LastFM, until condition: () -> Bool = { true }) async {
        for _ in 0..<200 {
            await lastFM.flush()
            await Task.yield()
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    var server: Server { Server.current }

    @Test func sendsScrobbles() async {
        let lastFM = client()
        scrobble(lastFM, ["A", "B", "C"])
        await settle(lastFM) { lastFM.pending.isEmpty }

        #expect(lastFM.pending.isEmpty)
        #expect(server.received == ["A", "B", "C"])
    }

    @Test func keepsScrobblesWhenOffline() async {
        let lastFM = client()
        server.mode = .unsent
        scrobble(lastFM, ["A", "B"])
        await settle(lastFM)

        #expect(lastFM.pending.map { $0["track"] } == ["A", "B"])
        #expect(lastFM.pending.allSatisfy { $0["_uncertain"] == nil })
        #expect(server.received.isEmpty)

        server.mode = .ok
        await settle(lastFM) { lastFM.pending.isEmpty }
        #expect(server.received == ["A", "B"])
    }

    @Test(arguments: [11, 16, 29, 26, 8])
    func keepsScrobblesOnTemporaryErrors(code: Int) async {
        let lastFM = client()
        server.mode = .error(code)
        scrobble(lastFM, ["A", "B"])
        await settle(lastFM)

        #expect(lastFM.pending.count == 2)
        #expect(lastFM.rejected.isEmpty)

        server.mode = .ok
        await settle(lastFM) { lastFM.pending.isEmpty }
        #expect(server.received == ["A", "B"])
    }

    @Test func keepsScrobblesWhenServiceIsDown() async {
        let lastFM = client()
        server.mode = .down
        scrobble(lastFM, ["A", "B"])
        await settle(lastFM)

        #expect(lastFM.pending.count == 2)

        server.mode = .ok
        await settle(lastFM) { lastFM.pending.isEmpty }
        #expect(server.received == ["A", "B"])
    }

    @Test func keepsScrobblesWhenTheServerBreaksWithAValidBody() async {
        let lastFM = client()
        server.mode = .broken
        scrobble(lastFM, ["A", "B"])
        await settle(lastFM)

        #expect(lastFM.pending.count == 2, "a 500 is not an accepted scrobble, even when the body parses")
        #expect(lastFM.rejected.isEmpty)

        server.mode = .ok
        await settle(lastFM) { lastFM.pending.isEmpty }
        #expect(server.received == ["A", "B"])
    }

    @Test func aPlayWithoutAnAccountIsNotQueued() async {
        let lastFM = client()
        lastFM.disconnect()
        scrobble(lastFM, ["A"])
        await settle(lastFM)

        #expect(lastFM.pending.isEmpty, "a play is a scrobble only when there is an account to take it")
        #expect(server.received.isEmpty)
        #expect(lastFM.rejected.isEmpty)
    }

    @Test func aLoveIsOnlySentWhenLastFmAnswersSuccessfully() async {
        let lastFM = client()

        server.mode = .broken
        #expect(await lastFM.love("Artist", "A", true) == .retry, "a 500 with an empty body is not a confirmation")

        server.mode = .error(11)
        #expect(await lastFM.love("Artist", "A", true) == .retry, "a service that is down keeps the wish for later")

        server.mode = .ok
        #expect(await lastFM.love("Artist", "A", true) == .sent)
    }

    @Test func aRefusedNameIsDroppedAndAnExpiredSessionIsNot() async {
        let lastFM = client()

        server.mode = .error(6)
        #expect(await lastFM.love("Artist", "A", true) == .dropped, "a name Last.fm refuses will never be accepted")

        server.mode = .error(9)
        #expect(await lastFM.love("Artist", "A", true) == .retry, "an expired session keeps the wish for after a reconnect")

        lastFM.disconnect()
        #expect(await lastFM.love("Artist", "A", true) == .retry)
    }

    @Test func keepsScrobblesOverTheDailyLimit() async {
        let lastFM = client()
        server.mode = .limit(["B"])
        scrobble(lastFM, ["A", "B", "C"])
        await settle(lastFM) { lastFM.pending.count == 1 }

        #expect(lastFM.pending.map { $0["track"] } == ["B"])
        #expect(server.received == ["A", "C"])

        server.mode = .ok
        await settle(lastFM) { lastFM.pending.isEmpty }
        #expect(server.received == ["A", "C", "B"])
    }

    @Test func isolatesAnInvalidScrobble() async {
        let lastFM = client()
        server.mode = .invalid("BAD")
        scrobble(lastFM, ["A", "BAD", "C"])
        await settle(lastFM) { lastFM.pending.isEmpty }

        #expect(server.received == ["A", "C"])
        #expect(lastFM.rejected.map { $0["track"] } == ["BAD"])
        #expect(lastFM.rejected.first?["_code"] == "6")
    }

    @Test func keepsScrobblesThatLastFMIgnores() async {
        let lastFM = client()
        server.mode = .filtered(["A": 1, "B": 2, "C": 3, "D": 4])
        scrobble(lastFM, ["A", "B", "C", "D", "E"])
        await settle(lastFM) { lastFM.pending.isEmpty }

        #expect(server.received == ["E"])
        #expect(lastFM.rejected.map { $0["_code"] } == ["1", "2", "3", "4"])
    }

    @Test func doesNotDuplicateWhenTheResponseIsLost() async {
        let lastFM = client()
        server.mode = .lost(keep: 2)
        scrobble(lastFM, ["A", "B", "C"])
        await settle(lastFM) { lastFM.pending.isEmpty }

        #expect(lastFM.pending.isEmpty)
        #expect(server.received == ["A", "B", "C"])
    }

    @Test func waitsBeforeItChecksTheHistory() async {
        let lastFM = client(settle: 3600)
        server.mode = .lost(keep: 1)
        scrobble(lastFM, ["A", "B"])
        await settle(lastFM)

        #expect(lastFM.pending.map { $0["track"] } == ["A", "B"])
        #expect(lastFM.pending.allSatisfy { $0["_uncertain"] != nil })
        #expect(server.received == ["A"])
    }

    @Test func keepsUncertainScrobblesWhenTheHistoryIsNotAvailable() async {
        let lastFM = client()
        server.mode = .lost(keep: 0)
        server.history = false
        scrobble(lastFM, ["A"])
        await settle(lastFM)

        #expect(lastFM.pending.map { $0["track"] } == ["A"])
        #expect(server.received.isEmpty)
    }

    @Test func sendsUncertainScrobblesBeforeTheLimit() async {
        let lastFM = client()
        server.mode = .lost(keep: 0)
        server.history = false
        scrobble(lastFM, ["Old"], ago: LastFM.limit - 3600)
        await settle(lastFM) { lastFM.pending.isEmpty }

        #expect(lastFM.pending.isEmpty)
        #expect(server.received == ["Old"])
    }

    @Test func uncertainScrobblesDoNotBlockNewScrobbles() async {
        let lastFM = client()
        server.mode = .lost(keep: 0)
        server.history = false
        scrobble(lastFM, ["A"])
        await settle(lastFM)

        scrobble(lastFM, ["B"], ago: 60)
        await settle(lastFM) { server.received.contains("B") }

        #expect(server.received == ["B"])
        #expect(lastFM.pending.map { $0["track"] } == ["A"])
    }

    @Test func keepsScrobblesWhenTheSessionExpires() async {
        let lastFM = client()
        server.mode = .error(9)
        scrobble(lastFM, ["A"])
        await settle(lastFM)

        #expect(lastFM.session.isEmpty)
        #expect(lastFM.pending.count == 1)

        server.mode = .ok
        lastFM.session = "key"
        lastFM.user = "tester"
        await settle(lastFM) { lastFM.pending.isEmpty }
        #expect(server.received == ["A"])
    }

    @Test func keepsScrobblesAfterARestart() async {
        let first = client()
        server.mode = .unsent
        scrobble(first, ["A", "B"])
        await settle(first)

        let second = client()
        #expect(second.pending.map { $0["track"] } == ["A", "B"])

        server.mode = .ok
        await settle(second) { second.pending.isEmpty }
        #expect(server.received == ["A", "B"])
    }

    @Test func sendsBatchesOfFiftyFromTheOldest() async {
        let lastFM = client()
        server.mode = .unsent
        let titles = (0..<120).map { "T\($0)" }
        scrobble(lastFM, titles, ago: 120 * 300)
        await settle(lastFM)

        server.mode = .ok
        await settle(lastFM) { lastFM.pending.isEmpty }

        #expect(server.received == titles)
        #expect(server.batches.suffix(3) == [50, 50, 20])
    }

    @Test func writesTheStoreAtomically() throws {
        let url = directory.appending(path: "store.plist")
        Persist.write(Data("first".utf8), to: url)
        Persist.write(Data("second".utf8), to: url)

        #expect(try Data(contentsOf: url) == Data("second".utf8))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
    }

    @Test func marksScrobblesOnDiskBeforeTheyAreSent() async throws {
        let lastFM = client()
        server.store = directory.appending(path: "Scrobbles.plist")
        scrobble(lastFM, ["A"])
        await settle(lastFM) { lastFM.pending.isEmpty }

        let snapshot = try #require(server.snapshot)
        let queue = try #require(try PropertyListSerialization.propertyList(from: snapshot, format: nil) as? [String: [[String: String]]])
        #expect(queue["pending"]?.map { $0["track"] } == ["A"])
        #expect(queue["pending"]?.allSatisfy { $0["_uncertain"] != nil } == true)
    }

    @Test func doesNotSendAgainAfterAQuitDuringTheSend() async throws {
        let first = client()
        let store = directory.appending(path: "Scrobbles.plist")
        server.store = store
        scrobble(first, ["A"])
        await settle(first) { first.pending.isEmpty }
        #expect(server.received == ["A"])

        try #require(server.snapshot).write(to: store)
        server.store = nil

        let second = client()
        #expect(second.pending.count == 1)
        await settle(second) { second.pending.isEmpty }

        #expect(second.pending.isEmpty)
        #expect(server.received == ["A"])
    }

    @Test func doesNotCrashOnAnInvalidSignInResponse() async {
        let lastFM = client()
        lastFM.disconnect()

        await lastFM.connect("user", "password")

        #expect(lastFM.session.isEmpty)
        #expect(!lastFM.status.isEmpty)
    }
}
