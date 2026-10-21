import CryptoKit
import Foundation

@Observable
final class Lyrics {
    nonisolated enum Failure: Error {
        case offline
        case busy
        case status(Int)
    }

    private nonisolated static let cache = URL.applicationSupportDirectory.appending(path: "Overdrive/Lyrics")
    private nonisolated static let agent = "Overdrive/v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")"
    private nonisolated static let timeout: TimeInterval = 10
    private nonisolated static let attempts = 3
    private nonisolated static let retryDelay: ClosedRange<Double> = 1...3

    private(set) var track: Track?
    private(set) var loading = false
    private(set) var original = ""
    private(set) var saved = ""
    var text = "" { didSet { if text != oldValue { synced = LRC.parse(text) } } }
    var visible = false
    var floating = false
    var confirming = false

    @ObservationIgnored private var pending: (() -> Void)?
    @ObservationIgnored private var saver: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    var modified: Bool { text != original }
    private(set) var synced: [SyncedLine] = []

    nonisolated static func ignored(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".lrc") || name.contains(".lrc.sb-")
    }

    func show(_ track: Track) {
        guard !visible || track != self.track else { return }

        confirm { self.open(track) }
    }

    func edit(_ value: String) {
        guard value != text else { return }

        text = value
        saver?.cancel()
        guard let track else { return }
        saver = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            save(value, for: track)
        }
    }

    func flush() {
        saver?.cancel()
        saver = nil
        if let track, modified { save(text, for: track) }
    }

    func discard() {
        saver?.cancel()
        saver = nil
        text = original
        pending?()
        pending = nil
    }

    func commit() {
        flush()
        if !modified { pending?() }
        pending = nil
    }

    func cancel() {
        pending = nil
    }

    func refresh() {
        confirm {
            guard let track = self.track else { return }
            Persist.remove(Lyrics.key(track))
            Persist.remove(Lyrics.oldKey(track))
            self.open(track)
        }
    }

    func save(_ value: String, for track: Track) {
        generation += 1

        let url = Lyrics.file(track)

        if !value.isEmpty {
            guard Persist.write(Data(value.utf8), to: url) else { return }

            Persist.write(Data(value.utf8), to: Lyrics.key(track))
        } else {
            if FileManager.default.fileExists(atPath: url.path) { Persist.remove(url) }

            Persist.write(Data(), to: Lyrics.key(track))
            Persist.remove(Lyrics.oldKey(track))
        }

        guard track == self.track else { return }

        saved = value
        original = value
    }

    func confirm(_ action: @escaping () -> Void) {
        if modified {
            pending = action
            confirming = true
        } else {
            action()
        }
    }

    private func open(_ track: Track) {
        generation += 1
        let generation = generation

        self.track = track
        visible = true

        if let lyrics = Lyrics.read(Lyrics.file(track)) {
            saved = lyrics
            original = saved
            text = saved
            loading = false
            return
        }

        saved = ""
        original = ""
        text = ""

        if let lyrics = Lyrics.cached(track) {
            if !lyrics.isEmpty { apply(.success(lyrics)) }
            loading = false
            return
        }

        loading = true

        Task {
            let result = await Lyrics.lookup(track)
            guard generation == self.generation else { return }

            apply(result)
            loading = false
        }
    }

    private func apply(_ result: Result<String, Failure>) {
        if case .success(let lyrics) = result, !lyrics.isEmpty {
            guard text.isEmpty else { return }
            original = lyrics
            text = lyrics
        }
    }

    private nonisolated static func file(_ track: Track) -> URL {
        track.url.deletingPathExtension().appendingPathExtension("lrc")
    }

    private nonisolated static func key(_ track: Track) -> URL {
        let digest = SHA256.hash(data: Data("\(track.artist)\n\(track.title)\n\(track.album)\n\(Int(track.duration.rounded()))".utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let name = "\(safe(track.artist)) - \(safe(track.album)) - \(safe(track.title)) - \(Int(track.duration.rounded()))s-\(hash.prefix(8)).txt"
        return cache.appending(path: name)
    }

    private nonisolated static func oldKey(_ track: Track) -> URL {
        let digest = SHA256.hash(data: Data("\(track.artist)\n\(track.title)\n\(track.album)\n\(Int(track.duration.rounded()))".utf8))
        return cache.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".txt")
    }

    private nonisolated static func safe(_ text: String, _ limit: Int = 40) -> String {
        var name = text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix(".") { name.removeLast() }
        if name.isEmpty { name = "unknown" }
        return String(name.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func cached(_ track: Track) -> String? {
        if let lyrics = read(key(track)) { return lyrics }
        guard let lyrics = read(oldKey(track)) else { return nil }
        Persist.move(oldKey(track), to: key(track))
        return lyrics
    }

    private nonisolated static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    @concurrent
    private nonisolated static func lookup(_ track: Track) async -> Result<String, Failure> {
        if let lyrics = cached(track), !lyrics.isEmpty { return .success(lyrics) }
        Persist.remove(key(track))
        Persist.remove(oldKey(track))

        let result = await fetch(track)

        if case .success(let lyrics) = result, !lyrics.isEmpty {
            Persist.write(Data(lyrics.utf8), to: key(track))
            return .success(lyrics)
        }

        if let fallback = await ovh(artist: track.artist, title: track.title), !fallback.isEmpty {
            Persist.write(Data(fallback.utf8), to: key(track))
            return .success(fallback)
        }

        return result
    }

    private nonisolated static func ovh(artist: String, title: String) async -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let artist = artist.addingPercentEncoding(withAllowedCharacters: allowed),
            let title = title.addingPercentEncoding(withAllowedCharacters: allowed),
            let url = URL(string: "https://api.lyrics.ovh/v1/\(artist)/\(title)")
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(for: .seconds(Double.random(in: retryDelay))) }
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let lyrics = json["lyrics"] as? String
            {
                let text = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            if status == 404 { return nil }
            guard status == 429 || status >= 500 else { return nil }
        }
        return nil
    }

    private nonisolated static func fetch(_ track: Track) async -> Result<String, Failure> {
        let get = request("get", [
            "artist_name": track.artist,
            "track_name": track.title,
            "album_name": track.album,
            "duration": String(Int(track.duration.rounded())),
        ])

        switch await load(get) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let json):
            let song = json as? [String: Any]
            if let lyrics = song?["syncedLyrics"] as? String, !lyrics.isEmpty { return .success(lyrics) }
            if let lyrics = song?["plainLyrics"] as? String { return .success(lyrics) }
        }

        return await load(request("search", ["artist_name": track.artist, "track_name": track.title])).map { json in
            let songs = json as? [[String: Any]] ?? []
            let distance = { (song: [String: Any]) in abs((song["duration"] as? Double ?? 0) - track.duration) }
            if let match = songs.filter({ ($0["syncedLyrics"] as? String)?.isEmpty == false }).min(by: { distance($0) < distance($1) }),
                let lyrics = match["syncedLyrics"] as? String, !lyrics.isEmpty
            {
                return lyrics
            }
            let match = songs.filter({ $0["plainLyrics"] is String }).min(by: { distance($0) < distance($1) })
            return match?["plainLyrics"] as? String ?? ""
        }
    }

    private nonisolated static func request(_ endpoint: String, _ parameters: [String: String]) -> URLRequest {
        var components = URLComponents(string: "https://lrclib.net/api/\(endpoint)")!
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")

        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private nonisolated static func load(_ request: URLRequest) async -> Result<Any, Failure> {
        var failure = Failure.busy

        for retry in 0..<attempts {
            if retry > 0 { try? await Task.sleep(for: .seconds(Double.random(in: retryDelay))) }

            guard let (data, response) = try? await URLSession.shared.data(for: request) else {
                failure = .offline
                continue
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 || status == 404 { return .success((try? JSONSerialization.jsonObject(with: data)) ?? [:]) }
            guard status == 429 || status >= 500 else { return .failure(.status(status)) }

            failure = .busy
        }

        return .failure(failure)
    }
}
