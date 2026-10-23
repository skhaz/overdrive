import CryptoKit
import Foundation

@Observable
final class Lyrics {
    nonisolated enum Failure: Error {
        case offline
        case busy
        case status(Int)
    }

    private nonisolated static let agent = "Overdrive/v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")"
    private nonisolated static let timeout: TimeInterval = 10
    private nonisolated static let attempts = 3
    private nonisolated static let retryDelay: ClosedRange<Double> = 1...3
    private nonisolated static let maxCacheAge: TimeInterval = 30 * 24 * 60 * 60

    nonisolated static func directory(in folder: URL?) -> URL {
        (folder ?? URL.homeDirectory.appending(path: "Music/Library", directoryHint: .isDirectory))
            .appending(path: "Lyrics", directoryHint: .isDirectory)
    }

    private(set) var track: Track?
    private(set) var loading = false
    private(set) var original = ""
    private(set) var saved = ""
    var text = "" { didSet { if text != oldValue { synced = LRC.parse(text) } } }
    var floating = false
    var selected = false
    var enabled: Bool { didSet { if !enabled, oldValue { stop() } } }
    private(set) var remote = false
    var hasLocalLyrics: Bool {
        guard let track else { return false }
        return (Self.read(file(track)) ?? "").isEmpty == false
    }
    var pendingReplace: Bool = false
    var pendingLyrics: String = ""

    @ObservationIgnored private let cache: URL
    @ObservationIgnored private var saver: Task<Void, Never>?
    @ObservationIgnored private var lookupTask: Task<Void, Never>?

    var modified: Bool { text != original }
    private(set) var synced: [SyncedLine] = []

    init(cache: URL, enabled: Bool = true) {
        self.cache = cache
        self.enabled = enabled
    }

    nonisolated static func ignored(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let cached = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent == "Lyrics" && (name.hasSuffix(".txt") || name.hasSuffix(".txt.tmp"))
        return cached || name.hasSuffix(".lrc") || name.hasSuffix(".lrc.tmp") || name.contains(".lrc.sb-")
    }

    func show(_ track: Track) {
        guard enabled, track != self.track else { return }

        settle { self.open(track) }
    }

    private func stop() {
        flush()
        lookupTask?.cancel()
        lookupTask = nil
        track = nil
        loading = false
        original = ""
        saved = ""
        text = ""
        remote = false
        floating = false
        pendingReplace = false
        pendingLyrics = ""
    }

    func edit(_ value: String) {
        guard value != text else { return }

        text = value
        lookupTask?.cancel()
        loading = false
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

    func refresh() {
        guard let track = self.track else { return }
        loading = true
        lookupTask?.cancel()
        lookupTask = Task {
            let result = await Self.forceLookup(track, cache: cache)
            guard !Task.isCancelled else { return }
            if case .success(let lyrics) = result, !lyrics.isEmpty {
                Persist.write(Data(lyrics.utf8), to: key(track))
                if (Self.read(file(track)) ?? "").isEmpty {
                    original = lyrics
                    text = lyrics
                    remote = true
                } else {
                    pendingReplace = true
                    pendingLyrics = lyrics
                }
            }
            loading = false
        }
    }

    @concurrent
    private nonisolated static func forceLookup(_ track: Track, cache: URL) async -> Result<String, Failure> {
        let result = await fetch(track)

        if case .success(let lyrics) = result, !lyrics.isEmpty {
            return .success(lyrics)
        }

        if let fallback = await ovh(artist: track.artist, title: track.title), !fallback.isEmpty {
            return .success(fallback)
        }

        return .failure(Failure.offline)
    }

    func confirmReplace() {
        guard pendingReplace, !pendingLyrics.isEmpty, let track else { return }
        let lyrics = pendingLyrics
        original = lyrics
        text = lyrics
        remote = true
        pendingReplace = false
        pendingLyrics = ""
        save(lyrics, for: track)
    }

    func cancelReplace() {
        pendingReplace = false
        pendingLyrics = ""
    }

    func save(_ value: String, for track: Track) {
        let url = file(track)

        if !value.isEmpty {
            guard Persist.write(Data(value.utf8), to: url) else { return }

            Persist.write(Data(value.utf8), to: key(track))
        } else {
            if FileManager.default.fileExists(atPath: url.path) { Persist.remove(url) }

            Persist.remove(key(track))
        }

        guard track == self.track else { return }

        saved = value
        original = value
        remote = false
        loading = false
    }

    func persist() {
        guard let track else { return }
        save(text, for: track)
    }

    func settle(_ action: @escaping () -> Void) {
        if modified { flush() }
        action()
    }

    private func open(_ track: Track) {
        self.track = track

        if let lyrics = Self.read(file(track)), !lyrics.isEmpty {
            saved = lyrics
            original = saved
            text = saved
            remote = false
            loading = false
            return
        }

        saved = ""
        original = ""
        text = ""

        if let lyrics = cached(track), !lyrics.isEmpty {
            apply(.success(lyrics))
            loading = false
            return
        }

        loading = true

        lookupTask?.cancel()
        lookupTask = Task {
            let result = await Self.lookup(track, cache: cache)
            guard !Task.isCancelled else { return }

            apply(result)
            loading = false
        }
    }

    private func apply(_ result: Result<String, Failure>) {
        if case .success(let lyrics) = result, !lyrics.isEmpty {
            guard text.isEmpty else { return }
            original = lyrics
            text = lyrics
            remote = true
        }
    }

    private func file(_ track: Track) -> URL {
        track.url.deletingPathExtension().appendingPathExtension("lrc")
    }

    func key(_ track: Track) -> URL {
        Self.key(track, cache: cache)
    }

    private nonisolated static func key(_ track: Track, cache: URL) -> URL {
        let digest = SHA256.hash(data: Data("\(track.artist)\n\(track.title)\n\(track.album)\n\(Int(track.duration.rounded()))".utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let name = "\(safe(track.artist)) - \(safe(track.album)) - \(safe(track.title)) - \(Int(track.duration.rounded()))s-\(hash.prefix(8)).txt"
        return cache.appending(path: name)
    }

    private nonisolated static func safe(_ text: String, _ limit: Int = 40) -> String {
        var name = text.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix(".") { name.removeLast() }
        if name.isEmpty { name = "unknown" }
        return String(name.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cached(_ track: Track) -> String? {
        let keyURL = key(track)
        guard let lyrics = Self.read(keyURL), !lyrics.isEmpty else { return nil }
        if Self.isCacheStale(keyURL) {
            return nil
        }
        return lyrics
    }

    private nonisolated static func isCacheStale(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(modDate) > maxCacheAge
    }

    private nonisolated static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    @concurrent
    private nonisolated static func lookup(_ track: Track, cache: URL) async -> Result<String, Failure> {
        let keyURL = key(track, cache: cache)
        let staleLyrics = read(keyURL)

        if let lyrics = staleLyrics, !lyrics.isEmpty, !isCacheStale(keyURL) {
            return .success(lyrics)
        }

        let result = await fetch(track)

        if case .success(let lyrics) = result, !lyrics.isEmpty {
            Persist.write(Data(lyrics.utf8), to: keyURL)
            return .success(lyrics)
        }

        if let fallback = await ovh(artist: track.artist, title: track.title), !fallback.isEmpty {
            Persist.write(Data(fallback.utf8), to: keyURL)
            return .success(fallback)
        }

        if let lyrics = staleLyrics, !lyrics.isEmpty {
            return .success(lyrics)
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
