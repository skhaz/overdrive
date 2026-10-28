import Foundation
import Testing
@testable import Overdrive

/// The proof, on real objects, that a banned song cannot come out of any
/// discovery, and that the ban lives on the disk next to the music.
///
/// Every case builds a real `Library` out of tagged files, a real `Bans` on a
/// real folder, a real `Discovery` or `Infinity`, and a real `LastFM` reading a
/// fake chart. Nothing here reads source text: the pick runs, and the songs it
/// handed to the list are what the test asserts. The `Delivery` of `Discovery` is
/// replaced, so no audio starts.
///
/// The shape of every proof is the same: for each song S of the library, ban
/// every other song and run the path. The path must return exactly S. That
/// asserts both halves at once — S is reachable, so the test is not vacuous, and
/// none of the other eleven is, so no song escapes the ban.
@MainActor
@Suite(.serialized)
struct BansProofTests {
    private let artists = ["Krisiun", "Death", "Morra"]
    private let titles = ["Blood of Lions", "Combustion Inferno", "Bloodcraft", "South of the Border",
                          "Individual Thought Patterns", "Spiritual Healing", "Lepers of Apocalypse", "Flattening of Emotions",
                          "Sabado de Sol", "Mundo Cego", "Velas", "Oração"]

    /// A fresh sandbox per case, so a ban of one run cannot be read by the next.
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OverdriveBansProof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        return url
    }

    private func clean(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - the proof, one path at a time

    @Test func aBannedSongNeverComesOutOfTheWholeLibraryPool() async throws {
        let root = try sandbox()
        defer { clean(root) }
        let world = try await World(titles: titles, artists: artists, root: root)

        for survivor in world.songs {
            let picked = try await world.pick(banning: world.every(except: survivor)) { $0.pick(.songs, world.songs.count) }

            #expect(picked == [survivor], "Songs of \(world.songs.count) asked for, 11 banned: the path returned \(picked.map(\.title))")
        }
    }

    @Test func aBannedSongNeverComesOutOfTheNeverPlayedPool() async throws {
        let root = try sandbox()
        defer { clean(root) }
        let world = try await World(titles: titles, artists: artists, root: root)

        for survivor in world.songs {
            let picked = try await world.pick(banning: world.every(except: survivor)) { $0.pick(.unplayed, world.songs.count) }

            #expect(picked == [survivor], "Never Played: the path returned \(picked.map(\.title))")
        }
    }

    @Test func aBannedSongNeverComesOutOfTheMostPlayedPool() async throws {
        let root = try sandbox()
        defer { clean(root) }
        let world = try await World(titles: titles, artists: artists, root: root)
        world.played()

        for survivor in world.songs {
            let picked = try await world.pick(banning: world.every(except: survivor)) { $0.pick(.played, world.songs.count) }

            #expect(picked == [survivor], "Most Played: the path returned \(picked.map(\.title))")
        }
    }

    @Test func aBannedSongNeverComesOutOfTheLastFMArtistsPool() async throws {
        let root = try sandbox()
        defer { clean(root) }
        let world = try await World(titles: titles, artists: artists, root: root)
        world.chart()

        for survivor in world.songs {
            let picked = try await world.pick(banning: world.every(except: survivor)) { $0.pick(.artists, world.songs.count) }

            #expect(picked == [survivor], "Last.fm Artists: the path returned \(picked.map(\.title))")
            #expect(world.requests == ["artist.getTopTracks"],
                    "the two artists whose every song is banned must cost no request, and asked \(world.requests)")
        }
    }

    @Test func aBannedSongNeverComesOutOfTheTopBandsPool() async throws {
        let root = try sandbox()
        defer { clean(root) }
        let world = try await World(titles: titles, artists: artists, root: root)
        world.played()
        world.chart()

        for survivor in world.songs {
            let picked = try await world.pick(banning: world.every(except: survivor)) { $0.pick(.bands, world.songs.count) }

            #expect(picked == [survivor], "Top Bands: the path returned \(picked.map(\.title))")
            #expect(world.requests == ["artist.getTopTracks"],
                    "a band whose every song is banned must cost no request, and asked \(world.requests)")
        }
    }

    @Test func aBannedSongNeverComesOutOfInfinityStartOrRefill() async throws {
        let root = try sandbox()
        defer { clean(root) }
        let world = try await World(titles: titles, artists: artists, root: root)
        world.chart()

        for survivor in world.songs {
            let bans = world.bans(banning: world.every(except: survivor))
            let discovery = world.discovery(bans: bans)
            let infinity = Infinity(library: world.library, lastFM: world.lastFM, player: world.player, discovery: discovery, bans: bans)
            let start = Capture()
            let refill = Capture()
            discovery.delivery = Discovery.Delivery(replace: { start.put($0) }, append: { refill.put($0) })
            world.chart()

            let opened = start.token()
            infinity.toggle()
            #expect(infinity.on, "the mode turns on with an account, a key, and songs")

            let started = await start.wait(after: opened)
            #expect(started == [survivor], "Infinity start returned \(started.map(\.title))")

            let filled = refill.token()
            infinity.passed()
            let more = await refill.wait(after: filled)
            #expect(more == [survivor], "Infinity refill returned \(more.map(\.title))")

            infinity.off("proof")
            #expect(!infinity.on, "and one click leaves the mode")
        }
    }

    // MARK: - the disk

    @Test func theBanIsAFileInTheMusicFolderLikeLikes() async throws {
        let root = try sandbox()
        defer { clean(root) }
        let world = try await World(titles: titles, artists: artists, root: root)
        let victim = world.songs[3]
        let bans = world.bans(banning: [victim])
        let file = Bans.file(in: world.folder)
        Persist.flush()

        #expect(file.lastPathComponent == "Bans.plist", "one plist, like Likes.plist")
        #expect(file.deletingLastPathComponent().path == world.folder.path, "at the root of the first library folder")

        let stored = try #require(Persist.read([String].self, from: file))
        #expect(stored.count == 1, "one entry for one ban: \(stored)")
        #expect(!stored[0].hasPrefix("/"), "a relative path, so the folder can move: \(stored)")

        let reloaded = Bans(file: file, folder: world.folder)
        #expect(reloaded.contains(victim), "a fresh read of the file knows the ban")
        #expect(reloaded.paths == bans.paths, "and it reads back the same list, in the same order")
    }

    @Test func aMovedFolderKeepsItsBans() async throws {
        let root = try sandbox()
        defer { clean(root) }
        let world = try await World(titles: titles, artists: artists, root: root)
        let victim = world.songs[0]
        world.bans(banning: [victim])
        Persist.flush()

        let moved = root.appending(path: "Moved")
        try FileManager.default.moveItem(at: world.folder, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }

        let after = Bans(file: Bans.file(in: moved), folder: moved)
        // the file holds the path of the song relative to the folder, the same
        // base the cache and Likes use, so a move resolves it under the new root
        // instead of losing the song
        let transplant = Track(url: URL(fileURLWithPath: Library.real(moved)).appending(path: world.relative(victim)), title: victim.title, artist: victim.artist,
                               album: victim.album, number: victim.number, disc: victim.disc, albumArtist: victim.albumArtist,
                               year: victim.year, duration: victim.duration, albumID: victim.albumID)

        #expect(after.count == 1, "the file travelled with the folder")
        #expect(FileManager.default.fileExists(atPath: transplant.url.path), "the song is really there: \(transplant.url.path)")
        #expect(after.paths == [transplant.url.path], "and the ban points at exactly it")
        #expect(after.contains(transplant))
    }

    @Test func nothingIsWrittenWhileTheFolderIsMissing() async throws {
        let root = try sandbox()
        defer { clean(root) }
        let world = try await World(titles: titles, artists: artists, root: root)
        let gone = root.appending(path: "NotMounted")
        let file = Bans.file(in: gone)
        let at: () -> URL? = { gone }
        let bans = Bans(file: { file }, folder: at)

        bans.add([world.songs[0]])
        Persist.flush()

        #expect(bans.count == 1, "the ban is in memory at once, so a discovery on a missing drive still respects it")
        #expect(!FileManager.default.fileExists(atPath: file.path), "and nothing is written to a folder that is not there")
    }

    @Test func aBannedSongStaysInEveryOtherList() async throws {
        let root = try sandbox()
        defer { clean(root) }
        let world = try await World(titles: titles, artists: artists, root: root)
        let victim = world.songs[5]
        let bans = world.bans(banning: [victim])

        #expect(world.library.tracks.contains(victim), "the song stays in the library")
        #expect(world.library.albums(by: victim.artist).contains { $0.tracks.contains(victim) }, "and in its album")
        #expect(world.library.rows(bans.paths).map(\.track) == [victim], "and the banned page holds it")
        #expect(bans.allowed([victim]).isEmpty, "the pool of one banned song is empty")
        #expect(bans.allowed([victim, world.songs[6]]) == [world.songs[6]], "and a pool keeps the song that is not banned")
    }
}

// MARK: - the world

/// A real library, bans, player, Last.fm, and discovery over one temporary
/// folder, so every path runs on the objects the app builds.
@MainActor
private final class World {
    let library: Library
    let player: Player
    let lastFM: LastFM
    let folder: URL
    let songs: [Track]
    private var written: [Track.ID: String] = [:]
    private var charted: [String: [(String, Int)]] = [:]
    private var delivery = Capture()

    init(titles: [String], artists: [String], root: URL) async throws {
        let folder = root.appending(path: "Music-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = try Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Tests/OverdriveTests/Fixtures/cbr.mp3"))
        let skip = 10 + (Int(audio[6]) << 21 | Int(audio[7]) << 14 | Int(audio[8]) << 7 | Int(audio[9]))
        let bytes = audio[audio.index(audio.startIndex, offsetBy: skip)...]

        // the path each song was written under, keyed by the tags the scan reads
        // back, so no path arithmetic is involved
        var under: [String: String] = [:]

        for (index, title) in titles.enumerated() {
            let artist = artists[index / 4]
            let directory = folder.appending(path: artist)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Chart.tagged(artist: artist, title: title, album: "\(artist) Album", audio: bytes).write(to: directory.appending(path: "\(index).mp3"))
            under["\(artist)\u{1F}\(title)"] = "\(artist)/\(index).mp3"
        }

        let library = Library(loudness: Loudness(), folders: [folder])
        let end = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < end, !library.settled { try? await Task.sleep(for: .milliseconds(20)) }
        guard library.settled else { throw Chart.failed("the library never settled") }

        var configuration = LastFM.Configuration()
        configuration.endpoint = URL(string: "https://proof.invalid/2.0/")!
        configuration.credentials = root.appending(path: "lastfm.plist")
        configuration.store = root.appending(path: "Scrobbles.plist")
        configuration.transport = URLSession(configuration: Chart.session())
        configuration.retry = .seconds(3600)
        configuration.monitor = false
        configuration.key = "proof-key"
        configuration.secret = "proof-secret"

        self.folder = folder
        self.library = library
        self.songs = library.tracks.sorted { $0.title < $1.title }
        self.written = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, under["\($0.artist)\u{1F}\($0.title)"] ?? "\($0.artist)/\($0.url.lastPathComponent)") })
        self.lastFM = LastFM(configuration)
        self.player = Player(lastFM: lastFM, loudness: Loudness(), plays: library.plays)

        lastFM.user = "tester"
        #expect(self.songs.count == titles.count, "every tagged song is in the library")
        #expect(Set(self.songs.map(\.artist)) == Set(artists), "three artists of their own")

        var chart: [String: [(String, Int)]] = [:]

        for artist in artists {
            let held = library.songs(by: artist)
            #expect(held.count == titles.count / artists.count, "\(artist) holds its four songs")
            chart[artist] = held.enumerated().map { ($0.element.title, 1000 - $0.offset * 10) }
        }

        charted = chart
        Chart.reset(chart)
    }

    func chart() { Chart.reset(charted) }

    /// The path a song was written under, relative to the library folder: the
    /// very string the ban file holds.
    func relative(_ song: Track) -> String { written[song.id] ?? song.url.lastPathComponent }


    func played() {
        for song in songs { library.plays.bump(song) }
    }

    func bans(banning list: [Track]) -> Bans {
        let bans = Bans(file: { Bans.file(in: self.folder) }, folder: { self.folder })
        bans.remove(self.songs)
        bans.add(list)

        return bans
    }

    func every(except survivor: Track) -> [Track] { songs.filter { $0.id != survivor.id } }

    func discovery(bans: Bans) -> Discovery {
        let discovery = Discovery(library: library, lastFM: lastFM, player: player, bans: bans)
        discovery.delivery = Discovery.Delivery(replace: { self.delivery.put($0) }, append: { self.delivery.put($0) })

        return discovery
    }

    var requests: [String] { Chart.calls.filter { $0 == "artist.getTopTracks" } }

    /// One pick, and the songs it handed to the list.
    func pick(banning list: [Track], _ run: @MainActor (Discovery) -> Void) async throws -> [Track] {
        let discovery = self.discovery(bans: self.bans(banning: list))
        delivery = Capture()
        discovery.delivery = Discovery.Delivery(replace: { self.delivery.put($0) }, append: { self.delivery.put($0) })
        Chart.reset(self.charted)

        let mine = delivery.token()
        run(discovery)

        return await delivery.wait(after: mine)
    }
}

/// The songs a pick handed to the list, read from the main actor. A caller takes
/// a token **before** it runs the pick, so a delivery that already landed returns
/// at once instead of burning the whole timeout.
@MainActor
private final class Capture {
    nonisolated static let limit: Duration = .seconds(20)

    private(set) var songs: [Track] = []
    private var generation = 0

    func put(_ list: [Track]) {
        songs = list
        generation += 1
    }

    func token() -> Int { generation }

    func wait(after mine: Int) async -> [Track] {
        let end = ContinuousClock.now + Capture.limit

        while ContinuousClock.now < end, generation == mine {
            try? await Task.sleep(for: .milliseconds(2))
        }

        return songs
    }
}

// MARK: - the fake chart

private nonisolated final class Chart: @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var artists: [String: [(String, Int)]] = [:]
    private nonisolated(unsafe) static var sent: [String] = []

    static func reset(_ chart: [String: [(String, Int)]]) {
        lock.withLock {
            if !chart.isEmpty { artists = chart }
            sent = []
        }
    }

    static var calls: [String] { lock.withLock { sent } }

    static func failed(_ text: String) -> Error { NSError(domain: "proof", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    static func session() -> URLSessionConfiguration {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [ChartFake.self]
        return session
    }

    static func reply(method: String?, artist: String?) -> [String: Any]? {
        lock.withLock {
            sent.append(method ?? "")

            switch method {
            case "user.getTopArtists":
                return ["topartists": ["artist": artists.keys.sorted().map { ["name": $0] }]]
            case "artist.getTopTracks":
                return ["toptracks": ["track": (artists[artist ?? ""] ?? []).map { ["name": $0.0, "playcount": String($0.1)] }]]
            default:
                return ["error": 3, "message": "Invalid Method"]
            }
        }
    }

    /// An ID3v2.3 tag over the real audio of a fixture, so the library holds
    /// three artists and twelve titles of its own instead of one "Unknown
    /// Artist" built from a file name.
    static func tagged(artist: String, title: String, album: String, audio: Data) -> Data {
        func frame(_ id: String, _ text: String) -> Data {
            var payload = Data([1, 0xff, 0xfe])
            payload.append(text.data(using: .utf16LittleEndian)!)
            payload.append(contentsOf: [0, 0])
            var out = Data(id.utf8)
            let size = UInt32(payload.count)
            out.append(contentsOf: [UInt8(size >> 24), UInt8(size >> 16), UInt8(size >> 8), UInt8(size)])
            out.append(contentsOf: [0, 0])
            return out + payload
        }

        let body = frame("TPE1", artist) + frame("TIT2", title) + frame("TALB", album)
        var head = Data([0x49, 0x44, 0x33, 3, 0, 0])
        let size = UInt32(body.count)
        head.append(contentsOf: [UInt8((size >> 21) & 0x7f), UInt8((size >> 14) & 0x7f), UInt8((size >> 7) & 0x7f), UInt8(size & 0x7f)])

        return head + body + audio
    }
}

private nonisolated final class ChartFake: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = Data()

        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                body.append(buffer, count: read)
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

        guard let object = Chart.reply(method: form["method"], artist: form["artist"]) else {
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
