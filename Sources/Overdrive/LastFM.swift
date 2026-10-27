import CryptoKit
import Foundation
import Network

@Observable
final class LastFM {
    nonisolated struct Configuration {
        var endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
        var credentials = URL.applicationSupportDirectory.appending(path: "Overdrive/lastfm.plist")
        var store = URL.applicationSupportDirectory.appending(path: "Overdrive/Scrobbles.plist")
        var transport = URLSession.shared
        var retry: Duration = .seconds(60)
        var settle: TimeInterval = 120
        var monitor = true
    }

    private nonisolated struct Queue: Codable {
    var pending: [[String: String]] = []
        var rejected: [[String: String]] = []
    }

    struct Failure: Error {
        let code: Int
        let message: String
    }

    static let limit: TimeInterval = 14 * 86400
    static let key = Bundle.main.object(forInfoDictionaryKey: "LastFMKey") as? String ?? ""
    static let secret = Bundle.main.object(forInfoDictionaryKey: "LastFMSecret") as? String ?? ""

    private static let unsent: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                                                     .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed]

    var session: String { didSet { save() } }
    var user: String { didSet { save() } }
    @ObservationIgnored private var limited: Date?
    var pending: [[String: String]] { didSet { persist() } }
    var rejected: [[String: String]] { didSet { persist() } }
    var status = ""
    var connecting = false

    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var flushing = false

    init(_ configuration: Configuration = Configuration()) {
        self.configuration = configuration

        let saved = Persist.read([String: String].self, from: configuration.credentials) ?? [:]
        session = saved["session"] ?? ""
        user = saved["user"] ?? ""

        let queue = LastFM.load(configuration)
        pending = queue.pending
        rejected = queue.rejected

        if configuration.monitor {
            monitor.pathUpdateHandler = { [weak self] path in
                Log.lastFM.debug("network", metadata: ["status": "\(path.status)", "expensive": "\(path.isExpensive)", "interfaces": Log.list(Set(path.availableInterfaces.map(\.name)).sorted())])
                guard path.status == .satisfied else { return }

                Task { @MainActor in
                    guard let self else { return }

                    await self.flush()
                    self.connected?()
                }
            }
            monitor.start(queue: .main)
        }

        Task { [weak self, retry = configuration.retry] in
            while true {
                try? await Task.sleep(for: retry)
                guard let self else { return }
                if !pending.isEmpty, limited.map({ Date() >= $0 }) ?? true { await flush() }
            }
        }
    }

    private static func load(_ configuration: Configuration) -> Queue {
        Persist.read(Queue.self, from: configuration.store) ?? Queue()
    }

    private func persist() {
        guard let data = Persist.encode(Queue(pending: pending, rejected: rejected), for: configuration.store) else { return }

        Persist.write(data, to: configuration.store)
    }

    func connect(_ username: String, _ password: String) async {
        Log.lastFM.info("connect", metadata: ["user": "\(username)"])
        connecting = true
        defer { connecting = false }

        do {
            guard let result = try await call("auth.getMobileSession", ["username": username, "password": password])["session"] as? [String: Any],
                  let key = result["key"] as? String, let name = result["name"] as? String else {
                Log.lastFM.warning("connect failed", metadata: ["reason": "invalid response"])
                status = "Last.fm sent a response that is not valid."
                return
            }

            Log.lastFM.info("connected", metadata: ["user": "\(name)"])
            session = key
            user = name
            status = ""
            await flush()
            connected?()
        } catch let failure as Failure where failure.code == 4 && username.contains("@") {
            Log.lastFM.warning("connect failed", metadata: ["reason": "email", "code": "\(failure.code)"])
            status = "Enter the Last.fm username, not the email."
        } catch let failure as Failure {
            Log.lastFM.warning("connect failed", metadata: ["reason": "api", "code": "\(failure.code)", "message": "\(failure.message)"])
            status = failure.message
        } catch {
            Log.lastFM.warning("connect failed", metadata: ["reason": "network", "error": "\(error)"])
            status = error.localizedDescription
        }
    }

    private func save() {
        guard let data = Persist.encode(["session": session, "user": user], for: configuration.credentials) else { return }

        Persist.write(data, to: configuration.credentials)
    }

    func disconnect() {
        Log.lastFM.info("disconnect")
        session = ""
        user = ""
    }

    func nowPlaying(_ track: Track) {
        guard !session.isEmpty else { return }

        Task {
            let sent = (try? await call("track.updateNowPlaying", parameters(track), session: true)) != nil
            Log.lastFM.debug("now playing", metadata: ["artist": "\(track.artist)", "title": "\(track.title)", "sent": "\(sent)"])
        }
    }

    func scrobble(_ track: Track, at date: Date) {
        guard !session.isEmpty else {
            return Log.lastFM.debug("scrobble skipped", metadata: ["reason": "no account", "artist": "\(track.artist)", "title": "\(track.title)"])
        }

        Log.lastFM.info("queue scrobble", metadata: ["artist": "\(track.artist)", "title": "\(track.title)", "date": "\(date)", "pending": "\(pending.count + 1)"])
        pending.append(parameters(track).merging(["timestamp": String(Int(date.timeIntervalSince1970)), "_id": UUID().uuidString]) { $1 })

        Task { await flush() }
    }

    func topArtists(_ count: Int) async -> [String] {
        guard count > 0, !user.isEmpty else { return [] }

        guard let json = try? await call("user.getTopArtists", ["user": user, "limit": String(count)]) else { return [] }
        let artists = LastFM.items(json["topartists"], "artist")
        Log.lastFM.debug("top artists", metadata: ["user": "\(user)", "asked": "\(count)", "got": "\(artists.count)"])

        return artists.compactMap { $0["name"] as? String }.prefix(count).map { $0 }
    }

    func topTracks(_ artist: String, _ count: Int) async -> [String] {
        guard count > 0, !artist.isEmpty else { return [] }

        guard let json = try? await call("artist.getTopTracks", ["artist": artist, "limit": String(count), "autocorrect": "1"]) else { return [] }
        let tracks = LastFM.items(json["toptracks"], "track")
        Log.lastFM.debug("top tracks", metadata: ["artist": "\(artist)", "asked": "\(count)", "got": "\(tracks.count)"])

        return tracks.compactMap { $0["name"] as? String }.prefix(count).map { $0 }
    }

    /// What one love write did. Only an unknown track is given up on: an auth
    /// failure keeps the entry, so the like the user made goes up after a reconnect.
    enum Outcome {
        case sent, retry, dropped
    }

    var connected: (() -> Void)?

    func love(_ artist: String, _ title: String, _ love: Bool) async -> Outcome {
        guard !session.isEmpty else { return .retry }
        guard !artist.isEmpty, !title.isEmpty else {
            Log.lastFM.warning("love dropped", metadata: ["reason": "no name", "artist": "\(artist)"])
            return .dropped
        }

        do {
            _ = try await call(love ? "track.love" : "track.unlove", ["artist": artist, "track": title], session: true)
            Log.lastFM.info("love", metadata: ["action": "\(love ? "loved" : "unloved")", "artist": "\(artist)", "title": "\(title)"])
            return .sent
        } catch let failure as Failure where failure.code == 6 {
            Log.lastFM.warning("love dropped", metadata: ["artist": "\(artist)", "title": "\(title)", "code": "\(failure.code)", "message": "\(failure.message)"])
            return .dropped
        } catch let failure as Failure {
            Log.lastFM.warning("love retry", metadata: ["artist": "\(artist)", "title": "\(title)", "code": "\(failure.code)", "message": "\(failure.message)"])
            return .retry
        } catch {
            Log.lastFM.warning("love retry", metadata: ["artist": "\(artist)", "title": "\(title)", "error": "\(error)"])
            return .retry
        }
    }

    /// One page of the loved tracks, newest first, with the count the server
    /// reports. The order is what lets the cache be read from the top: a page that
    /// reaches a song the cache already holds has every song above it. Nil when the
    /// answer is not a list, so a broken page is never mistaken for an unlove.
    func loved(page: Int = 1, limit: Int = LastFM.wide) async -> LastFM.Page? {
        guard !user.isEmpty else { return nil }

        guard let json = try? await call("user.getLovedTracks", ["user": user, "limit": String(limit), "page": String(page)]) else { return nil }
        guard let container = json["lovedtracks"] as? [String: Any] else {
            Log.lastFM.debug("loved invalid", metadata: ["keys": Log.list(json.keys.sorted())])
            return nil
        }

        var tracks: [Loved] = []
        tracks.reserveCapacity(LastFM.items(container, "track").count)

        for track in LastFM.items(container, "track") {
            guard let title = track["name"] as? String, let artist = track["artist"] as? [String: Any], let name = artist["name"] as? String else { continue }

            tracks.append(Loved(artist: name, title: title))
        }

        let attributes = container["@attr"] as? [String: Any]
        let total = LastFM.count(attributes?["total"]) ?? -1
        let pages = LastFM.count(attributes?["totalPages"]) ?? 1

        Log.lastFM.debug("loved page", metadata: ["page": "\(page)", "limit": "\(limit)", "tracks": "\(tracks.count)", "total": "\(total)"])

        return Page(tracks: tracks, total: total, pages: pages)
    }

    nonisolated static let pages = 20
    nonisolated static let wide = 1000

    nonisolated struct Page: Sendable {
        let tracks: [Loved]
        let total: Int
        let pages: Int
    }

    nonisolated struct Loved: Sendable {
        let artist: String
        let title: String
    }

    /// Last.fm writes every count as a string; a few answers give a number.
    nonisolated static func count(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text) }

        return value as? Int
    }

    nonisolated static func items(_ value: Any?, _ key: String) -> [[String: Any]] {
        guard let container = value as? [String: Any] else { return [] }
        return container[key] as? [[String: Any]] ?? (container[key] as? [String: Any]).map { [$0] } ?? []
    }

    nonisolated static func resume(after date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 86400).rounded(.down) * 86400 + 86400)
    }

    func flush() async {
        guard !session.isEmpty, !flushing else { return }

        flushing = true
        defer { flushing = false }

        Log.lastFM.info("flush", metadata: ["pending": "\(pending.count)", "rejected": "\(rejected.count)"])
        if pending.contains(where: { $0["_uncertain"] != nil }) { await settle() }

        var size = 50

        while !session.isEmpty {
            let batch = Array(pending.lazy.filter { $0["_uncertain"] == nil }.prefix(size))
            guard !batch.isEmpty else { return }

            var parameters: [String: String] = [:]

            for (index, entry) in batch.enumerated() {
                for (name, value) in entry where !name.hasPrefix("_") {
                    parameters["\(name)[\(index)]"] = value
                }
            }

            mark(batch, String(Int(Date.now.timeIntervalSince1970)))

            do {
                let json = try await call("track.scrobble", parameters, session: true)
                guard let codes = LastFM.codes(json, batch.count) else {
                    return Log.lastFM.error("scrobble response invalid", metadata: ["count": "\(batch.count)", "keys": Log.list(json.keys.sorted())])
                }

                Log.lastFM.info("scrobbled", metadata: ["count": "\(batch.count)", "codes": Log.list(codes)])
                let limited = zip(batch, codes).filter { $1 == 5 }.map(\.0)
                rejected.append(contentsOf: zip(batch, codes).filter { $1 != 0 && $1 != 5 }.map { $0.merging(["_code": String($1)]) { $1 } })
                remove(batch.filter { entry in !limited.contains { $0["_id"] == entry["_id"] } })
                mark(limited, nil)
                status = ""

                guard limited.isEmpty else {
                    self.limited = LastFM.resume(after: Date())
                    Log.lastFM.warning("flush stopped", metadata: ["action": "daily limit", "kept": "\(limited.count)", "retry": "\(self.limited.map { "\($0)" } ?? "")"])
                    status = "Last.fm daily scrobble limit reached. The app will send the rest later."
                    return
                }
            } catch let failure as Failure {
                mark(batch, nil)
                status = failure.message

                switch failure.code {
                case 9:
                    Log.lastFM.warning("flush stopped", metadata: ["action": "disconnect", "code": "\(failure.code)"])
                    disconnect()
                case 6, 7, 13:
                    guard batch.count == 1 else {
                        Log.lastFM.warning("flush split", metadata: ["code": "\(failure.code)", "batch": "\(batch.count)"])
                        size = 1
                        continue
                    }

                    Log.lastFM.warning("scrobble isolated", metadata: ["code": "\(failure.code)", "artist": "\(batch[0]["artist"] ?? "")", "title": "\(batch[0]["track"] ?? "")"])
                    rejected.append(batch[0].merging(["_code": String(failure.code)]) { $1 })
                    remove(batch)
                default:
                    Log.lastFM.warning("flush stopped", metadata: ["action": "abort", "code": "\(failure.code)"])
                    return
                }
            } catch let error as URLError where LastFM.unsent.contains(error.code) {
                Log.lastFM.warning("flush stopped", metadata: ["action": "offline", "error": "\(error)"])
                mark(batch, nil)
                status = error.localizedDescription
                return
            } catch {
                Log.lastFM.error("flush stopped", metadata: ["action": "uncertain", "error": "\(error)"])
                status = error.localizedDescription
                return
            }
        }
    }

    private func remove(_ batch: [[String: String]]) {
        let ids = Set(batch.compactMap { $0["_id"] })
        pending.removeAll { $0["_id"].map(ids.contains) ?? false }
    }

    private func mark(_ batch: [[String: String]], _ value: String?) {
        guard !batch.isEmpty else { return }

        let ids = Set(batch.compactMap { $0["_id"] })
        var entries = pending

        for index in entries.indices where entries[index]["_id"].map(ids.contains) ?? false {
            entries[index]["_uncertain"] = value
        }

        pending = entries
    }

    private func settle() async {
        let uncertain = pending.filter { $0["_uncertain"] != nil }
        let now = Date.now.timeIntervalSince1970
        let marked = uncertain.compactMap { $0["_uncertain"].flatMap(Double.init) }.max() ?? 0
        guard now - marked > configuration.settle else {
            return Log.lastFM.debug("settle skipped", metadata: ["uncertain": "\(uncertain.count)"])
        }

        let stamps = uncertain.compactMap { $0["timestamp"].flatMap(Int.init) }

        if let low = stamps.min(), let high = stamps.max(), let found = await history(low, high) {
            let matched = uncertain.filter { $0["timestamp"].map(found.contains) ?? false }
            Log.lastFM.info("settle", metadata: ["uncertain": "\(uncertain.count)", "matched": "\(matched.count)", "result": "history"])
            remove(matched)
            pending = pending.map { $0.filter { $0.key != "_uncertain" } }
            return
        }

        let deadline = now - LastFM.limit + 86400
        var entries = pending

        var expired = 0
        for index in entries.indices where entries[index]["_uncertain"] != nil {
            if let stamp = entries[index]["timestamp"].flatMap(Double.init), stamp < deadline {
                entries[index]["_uncertain"] = nil
                expired += 1
            }
        }

        Log.lastFM.warning("settle", metadata: ["uncertain": "\(uncertain.count)", "expired": "\(expired)", "result": "no history"])
        pending = entries
    }

    private func history(_ low: Int, _ high: Int) async -> Set<String>? {
        guard !user.isEmpty else { return nil }

        var found = Set<String>()
        var page = 1
        var pages = 1

        repeat {
            guard let json = try? await call("user.getRecentTracks", ["user": user, "from": String(low), "to": String(high + 1), "limit": "200", "page": String(page)]) else { return nil }
            guard let recent = json["recenttracks"] as? [String: Any] else {
                Log.lastFM.debug("history invalid", metadata: ["keys": Log.list(json.keys.sorted())])
                return nil
            }

            let tracks = recent["track"] as? [[String: Any]] ?? (recent["track"] as? [String: Any]).map { [$0] } ?? []

            for track in tracks {
                if let date = track["date"] as? [String: Any], let uts = date["uts"] as? String { found.insert(uts) }
            }

            pages = Int((recent["@attr"] as? [String: Any])?["totalPages"] as? String ?? "1") ?? 1
            page += 1
        } while page <= pages

        return found
    }

    private static func codes(_ json: [String: Any], _ count: Int) -> [Int]? {
        guard let scrobbles = json["scrobbles"] as? [String: Any] else { return nil }

        let items = scrobbles["scrobble"] as? [[String: Any]] ?? (scrobbles["scrobble"] as? [String: Any]).map { [$0] } ?? []
        guard items.count == count else { return nil }

        return items.map { item in
            let message = item["ignoredMessage"] as? [String: Any]
            return Int(message?["code"] as? String ?? "") ?? (message?["code"] as? Int) ?? 0
        }
    }

    private func parameters(_ track: Track) -> [String: String] {
        var parameters = ["artist": track.artist, "track": track.title, "album": track.album]
        if track.duration > 0 { parameters["duration"] = String(Int(track.duration)) }
        return parameters
    }

    private func call(_ method: String, _ parameters: [String: String], session: Bool = false) async throws -> [String: Any] {
        var parameters = parameters
        parameters["method"] = method
        parameters["api_key"] = LastFM.key
        if session { parameters["sk"] = self.session }

        let signature = parameters.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + LastFM.secret
        parameters["api_sig"] = Insecure.MD5.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        parameters["format"] = "json"

        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(parameters.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await configuration.transport.data(for: request)
        } catch {
            Log.lastFM.error("request failed", metadata: ["method": "\(method)", "error": "\(error)"])
            throw error
        }
        Log.lastFM.debug("response", metadata: ["method": "\(method)", "status": "\((response as? HTTPURLResponse)?.statusCode ?? 0)", "bytes": "\(data.count)"])
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            Log.lastFM.error("http failed", metadata: ["method": "\(method)", "status": "\(http.statusCode)"])
            throw Failure(code: http.statusCode, message: "Last.fm answered \(http.statusCode).")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        if let code = json["error"] as? Int {
            Log.lastFM.error("api error", metadata: ["method": "\(method)", "code": "\(code)", "reason": "\(json["message"] as? String ?? "")"])
            throw Failure(code: code, message: json["message"] as? String ?? "Last.fm error \(code)")
        }

        return json
    }
}
