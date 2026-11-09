import Foundation
import Testing
@testable import Overdrive

private final class CuriosityStub: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _status = 200
    private var _facts = ["One", "Two"]
    private var _fail = false
    private var _wait: Duration = .zero

    var requests: [URLRequest] { lock.withLock { _requests } }

    func answer(status: Int = 200, facts: [String] = ["One", "Two"], fail: Bool = false, wait: Duration = .zero) {
        lock.withLock {
            _status = status
            _facts = facts
            _fail = fail
            _wait = wait
        }
    }

    static func reply(_ facts: [String]) -> Data {
        let content = String(decoding: try! JSONSerialization.data(withJSONObject: ["facts": facts]), as: UTF8.self)
        return try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    }

    var transport: Curiosity.Transport {
        { [self] request in
            let (status, facts, fail, wait) = lock.withLock {
                _requests.append(request)
                return (_status, _facts, _fail, _wait)
            }
            if wait > .zero { try? await Task.sleep(for: wait) }
            if fail { throw URLError(.notConnectedToInternet) }

            return (Self.reply(facts), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

@MainActor
struct CuriosityTests {
    private static let endpoint = URL(string: "https://curiosity.invalid/chat")!
    private let stub = CuriosityStub()

    private func model(key: String = "secret-value", language: String = "pt-BR") -> Curiosity {
        var configuration = Curiosity.Configuration()
        configuration.endpoint = Self.endpoint
        configuration.file = nil
        configuration.transport = stub.transport
        configuration.language = language
        let curiosity = Curiosity(configuration)
        curiosity.save(key)
        return curiosity
    }

    private func lastFM(user: String) -> LastFM {
        let folder = FileManager.default.temporaryDirectory.appending(path: "curiosity-\(UUID().uuidString)")
        var configuration = LastFM.Configuration()
        configuration.endpoint = URL(string: "https://lastfm.invalid/")!
        configuration.credentials = folder.appending(path: "lastfm.plist")
        configuration.store = folder.appending(path: "Scrobbles.plist")
        configuration.monitor = false
        configuration.key = "key"
        configuration.secret = "secret"
        let lastFM = LastFM(configuration)
        lastFM.user = user
        return lastFM
    }

    private func track(_ artist: String) -> Track {
        Track(url: URL(fileURLWithPath: "/m/\(artist).mp3"), title: "Song", artist: artist, album: "Album", number: 1, disc: 1, albumArtist: "", year: 2000, duration: 200, albumID: "x")
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the tab never settled")
    }

    @Test func theAnswerBecomesFiveCleanFacts() throws {
        let many = ["• One", "- Two", "Two", "  ", "Three", "Four", "Five", "Six"]

        #expect(Curiosity.parse(CuriosityStub.reply(many)) == ["One", "Two", "Three", "Four", "Five"], "no bullets of its own, no repeats, no more than five")
        #expect(Curiosity.parse(CuriosityStub.reply([])) == [], "an artist with no curiosities is a valid answer")
        #expect(Curiosity.parse(Data("{\"error\":{\"code\":502}}".utf8)) == nil, "an error inside a 200 is not an answer")
        #expect(Curiosity.parse(try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "not json"]]]])) == nil, "the content must be the schema")
    }

    @Test func theRequestAsksForStructuredFactsInTheSystemLanguage() throws {
        let request = try #require(Curiosity.request(artist: "Sepultura", album: "Roots", song: "Ratamahatta", key: "secret-value", language: "pt-BR", endpoint: Self.endpoint))
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let format = try #require(body["response_format"] as? [String: Any])
        let schema = try #require(format["json_schema"] as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-value", "the key comes from the settings")
        #expect(format["type"] as? String == "json_schema")
        #expect(schema["strict"] as? Bool == true)
        #expect((body["provider"] as? [String: Bool])?["require_parameters"] == true, "only a provider that keeps the schema may answer")
        #expect(body["model"] as? String == Curiosity.model)
        #expect(messages[0]["content"]?.contains("Portuguese (Brazil), language tag pt-BR") == true, "the facts come in the language of the system")
        #expect(messages[0]["content"]?.contains("at most 5") == true)
        #expect(messages[1]["content"] == "Artist: Sepultura\nAlbum: Roots\nSong: Ratamahatta")
    }

    @Test func theTabExistsOnlyWithItsOwnKey() {
        let keyed = model(), empty = Curiosity(Curiosity.Configuration(endpoint: Self.endpoint, file: nil, transport: stub.transport))

        #expect(Similar(lastFM: lastFM(user: "")).tabs == [.lyrics])
        #expect(Similar(lastFM: lastFM(user: ""), curiosity: empty).tabs == [.lyrics], "no key, no tab")
        #expect(Similar(lastFM: lastFM(user: "me"), curiosity: empty).tabs == [.lyrics, .similar])
        #expect(Similar(lastFM: lastFM(user: ""), curiosity: keyed).tabs == [.lyrics, .curiosity], "the key does not need a Last.fm account")
        #expect(Similar(lastFM: lastFM(user: "me"), curiosity: keyed).tabs == [.lyrics, .similar, .curiosity])
    }

    @Test func noKeyAsksNothing() async {
        let curiosity = Curiosity(Curiosity.Configuration(endpoint: Self.endpoint, file: nil, transport: stub.transport))
        let similar = Similar(lastFM: lastFM(user: "me"), curiosity: curiosity)
        similar.show(track("Artist"))
        similar.select(.curiosity)
        curiosity.load()

        #expect(similar.tab == .lyrics)
        #expect(stub.requests.isEmpty)
    }

    @Test func oneArtistAsksOnce() async {
        let curiosity = model()
        let similar = Similar(lastFM: lastFM(user: ""), curiosity: curiosity)
        similar.show(track("Artist"))
        similar.select(.curiosity)
        #expect(curiosity.loading, "the wait shows at once")
        await settle { !curiosity.loading }
        #expect(curiosity.facts == ["One", "Two"])

        similar.select(.lyrics)
        similar.select(.curiosity)
        similar.show(track("artist"))
        await settle { !curiosity.loading }
        #expect(stub.requests.count == 1, "a re-pick of the tab costs nothing")
        #expect(similar.tab == .curiosity, "the same artist keeps the tab")
    }

    @Test func aSecondPickWhileAskingSpendsNoRequest() async {
        stub.answer(wait: .milliseconds(50))
        let curiosity = model()
        let similar = Similar(lastFM: lastFM(user: ""), curiosity: curiosity)
        similar.show(track("Artist"))
        similar.select(.curiosity)
        similar.select(.lyrics)
        similar.select(.curiosity)
        await settle { !curiosity.loading }

        #expect(stub.requests.count == 1)
        #expect(curiosity.facts == ["One", "Two"])
    }

    @Test func aNewArtistGoesBackToTheLyricsAndDropsTheLateAnswer() async throws {
        stub.answer(wait: .milliseconds(80))
        let curiosity = model()
        let similar = Similar(lastFM: lastFM(user: ""), curiosity: curiosity)
        similar.show(track("Old"))
        similar.select(.curiosity)
        await settle { stub.requests.count == 1 }

        similar.show(track("New"))
        #expect(similar.tab == .lyrics)
        #expect(!curiosity.loading)
        try await Task.sleep(for: .milliseconds(160))
        #expect(curiosity.facts.isEmpty, "the answer about the old artist never shows")
    }

    @Test(arguments: [(401, "OpenRouter refused the API key."), (402, "OpenRouter has no credits left."), (500, "Could not load curiosities.")])
    func aFailureSaysWhyAndRetryAsksAgain(status: Int, message: String) async {
        stub.answer(status: status)
        let curiosity = model()
        curiosity.show(track("Artist"))
        curiosity.load()
        await settle { !curiosity.loading }
        #expect(curiosity.note == message)
        #expect(curiosity.facts.isEmpty)

        stub.answer()
        curiosity.reload()
        await settle { !curiosity.loading }
        #expect(curiosity.facts == ["One", "Two"])
        #expect(stub.requests.count == 2, "a failed answer is not kept")
    }

    @Test func anEmptyAnswerIsNotKept() async {
        stub.answer(facts: [])
        let curiosity = model()
        curiosity.show(track("Artist"))
        curiosity.load()
        await settle { !curiosity.loading }
        #expect(curiosity.note == Curiosity.none)

        curiosity.load()
        await settle { !curiosity.loading }
        #expect(stub.requests.count == 2)
    }

    @Test func offlineLeavesTheNote() async {
        stub.answer(fail: true)
        let curiosity = model()
        curiosity.show(track("Artist"))
        curiosity.load()
        await settle { !curiosity.loading }
        #expect(curiosity.note == "Could not load curiosities.")
    }

    @Test func removingTheKeyHidesTheTabAndStopsTheAnswer() async throws {
        stub.answer(wait: .milliseconds(50))
        let curiosity = model()
        let similar = Similar(lastFM: lastFM(user: ""), curiosity: curiosity)
        similar.show(track("Artist"))
        similar.select(.curiosity)
        curiosity.remove()

        #expect(similar.tabs == [.lyrics])
        #expect(similar.face == .lyrics, "a tab that left falls back to the lyrics")
        try await Task.sleep(for: .milliseconds(120))
        #expect(curiosity.facts.isEmpty)
    }

    @Test func theKeyLivesInItsOwnFileAndNeverInTheLog() throws {
        let records = logRecords
        let folder = FileManager.default.temporaryDirectory.appending(path: "curiosity-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "openrouter.plist")
        let configuration = Curiosity.Configuration(endpoint: Self.endpoint, file: file, transport: stub.transport)
        let marker = "unique-\(UUID().uuidString)"

        Curiosity(configuration).save("  \(marker)\n")
        #expect(Curiosity(configuration).key == marker, "the key comes back at the next launch, with no spaces around it")
        #expect(records.find("curiosity", "key saved"), "the save logs, so the check below is not empty")
        #expect(!records.contains(marker), "the key never goes to the log")

        Curiosity(configuration).remove()
        #expect(Curiosity(configuration).key.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path), "removing the key removes the file")
    }

    @Test func aBlankKeyIsNotAKey() {
        let curiosity = model(key: "   ")
        #expect(!curiosity.available)
    }
}
