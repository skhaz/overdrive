import Foundation

@Observable
final class Lyrics {
    nonisolated enum Failure: Error {
        case offline
        case busy
        case cancelled
        case status(Int)
    }

    private nonisolated static let agent = "Overdrive/v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0")"
    private nonisolated static let timeout: TimeInterval = 10
    private nonisolated static let attempts = 3
    private nonisolated static let retryDelay: ClosedRange<Double> = 1...3
    nonisolated static let validity: TimeInterval = 30 * 24 * 60 * 60
    nonisolated static let kept = "lyrics"
    nonisolated static let cached = "cache.lyrics"

    private(set) var track: Track?
    private(set) var loading = false
    private(set) var original = ""
    private(set) var saved = ""
    var text = "" { didSet { if text != oldValue { synced = LRC.parse(text) } } }
    var floating = false { didSet { if floating != oldValue { Log.lyrics.info("floating", metadata: ["floating": "\(floating)"]) } } }
    var selected = false
    var enabled: Bool { didSet { if !enabled, oldValue { stop() } } }
    private(set) var remote = false
    private(set) var hasLocalLyrics = false
    var pendingReplace: Bool = false
    var pendingLyrics: String = ""

    @ObservationIgnored var source: @Sendable (Track) async -> Result<String, Failure> = { await Lyrics.lookup($0) }
    @ObservationIgnored var refresher: @Sendable (Track) async -> Result<String, Failure> = { await Lyrics.forceLookup($0) }
    @ObservationIgnored private var saver: Task<Void, Never>?
    @ObservationIgnored private var lookupTask: Task<Void, Never>?

    var modified: Bool { text != original }
    private(set) var synced: [SyncedLine] = []

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    func show(_ track: Track) {
        guard enabled, track != self.track else { return }

        Log.lyrics.info("show", metadata: ["path": "\(track.url.path)"])

        settle { self.open(track) }
    }

    private func stop() {
        hasLocalLyrics = false
        Log.lyrics.info("stop")
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

        Log.lyrics.debug("edit", metadata: ["characters": "\(value.count)"])

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
        flush()
        guard let track = self.track else { return }

        Log.lyrics.info("refresh", metadata: ["path": "\(track.url.path)"])
        loading = true
        lookupTask?.cancel()
        lookupTask = Task {
            let result = await refresher(track)
            guard !Task.isCancelled, track == self.track else { return Log.lyrics.debug("refresh dropped", metadata: ["path": "\(track.url.path)"]) }
            if case .success(let lyrics) = result, !lyrics.isEmpty {
                Persist.write(Data(lyrics.utf8), to: Self.key(track))
                let local = !(Self.read(file(track)) ?? "").isEmpty
                Log.lyrics.info("refresh result", metadata: ["path": "\(track.url.path)", "characters": "\(lyrics.count)", "pending": "\(local)"])
                if !local {
                    original = lyrics
                    text = lyrics
                    remote = true
                } else {
                    pendingReplace = true
                    pendingLyrics = lyrics
                }
            } else {
                Log.lyrics.info("refresh result", metadata: ["path": "\(track.url.path)", "result": "\(String(describing: result))"])
            }
            loading = false
        }
    }

    @concurrent
    private nonisolated static func forceLookup(_ track: Track) async -> Result<String, Failure> {
        let result = await fetch(track)
        if case .failure(.cancelled) = result { return result }

        if case .success(let lyrics) = result, !lyrics.isEmpty {
            return .success(lyrics)
        }

        if let fallback = await ovh(artist: track.artist, title: track.title), !fallback.isEmpty {
            return .success(fallback)
        }

        return result
    }

    func confirmReplace() {
        guard pendingReplace, !pendingLyrics.isEmpty, let track else { return }

        Log.lyrics.info("replace", metadata: ["path": "\(track.url.path)", "accepted": "true", "characters": "\(pendingLyrics.count)"])
        let lyrics = pendingLyrics
        original = lyrics
        text = lyrics
        remote = true
        pendingReplace = false
        pendingLyrics = ""
        save(lyrics, for: track)
    }

    func cancelReplace() {
        Log.lyrics.info("replace", metadata: ["path": "\(track?.url.path ?? "")", "accepted": "false"])
        pendingReplace = false
        pendingLyrics = ""
    }

    func save(_ value: String, for track: Track) {
        let url = file(track)
        Log.lyrics.info("save", metadata: ["path": "\(url.path)", "characters": "\(value.count)"])

        if !value.isEmpty {
            guard Persist.write(Data(value.utf8), to: url) else { return }

            Persist.write(Data(value.utf8), to: Self.key(track))
        } else {
            if FileManager.default.fileExists(atPath: url.path) { Persist.remove(url) }

            if FileManager.default.fileExists(atPath: Self.key(track).path) { Persist.remove(Self.key(track)) }
        }

        guard track == self.track else { return }

        saved = value
        original = value
        remote = false
        loading = false
        hasLocalLyrics = !value.isEmpty
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
        lookupTask?.cancel()
        lookupTask = nil
        loading = false
        pendingReplace = false
        pendingLyrics = ""
        self.track = track
        hasLocalLyrics = false

        if let lyrics = Self.read(file(track)), !lyrics.isEmpty {
            Log.lyrics.info("local", metadata: ["path": "\(file(track).path)"])
            hasLocalLyrics = true
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

        let key = Self.key(track)
        if let lyrics = Self.read(key), !lyrics.isEmpty {
            apply(.success(lyrics))
            loading = false
            guard Self.isCacheStale(key) else { return Log.lyrics.info("cached", metadata: ["path": "\(track.url.path)"]) }

            Log.lyrics.info("cache expired", metadata: ["path": "\(key.path)"])
            lookupTask = Task {
                let result = await source(track)
                guard !Task.isCancelled, track == self.track else { return }
                guard case .success(let fresh) = result, !fresh.isEmpty, fresh != text, remote, !modified else {
                    return Log.lyrics.info("cache kept", metadata: ["path": "\(track.url.path)", "edited": "\(modified)"])
                }

                Log.lyrics.info("cache replaced", metadata: ["path": "\(track.url.path)", "characters": "\(fresh.count)"])
                original = fresh
                text = fresh
            }
            return
        }

        loading = true

        lookupTask?.cancel()
        lookupTask = Task {
            let result = await source(track)
            guard !Task.isCancelled else { return Log.lyrics.debug("lookup cancelled", metadata: ["path": "\(track.url.path)"]) }

            Log.lyrics.info("lookup", metadata: ["path": "\(track.url.path)", "result": "\((try? result.get()).map { "\($0.count) characters" } ?? String(describing: result))"])

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
        track.url.deletingPathExtension().appendingPathExtension(Self.kept)
    }

    nonisolated static func key(_ track: Track) -> URL {
        track.url.deletingPathExtension().appendingPathExtension(cached)
    }

    nonisolated static func isCacheStale(_ url: URL, at now: Date = Date()) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modDate = attrs[.modificationDate] as? Date else { return true }
        return now.timeIntervalSince(modDate) > validity
    }

    private nonisolated static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }

        Log.lyrics.debug("latin1 fallback", metadata: ["path": "\(url.path)"])
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    @concurrent
    nonisolated static func lookup(
        _ track: Track,
        fetch: @Sendable (Track) async -> Result<String, Failure> = { await Lyrics.fetch($0) },
        ovh: @Sendable (Track) async -> String? = { await Lyrics.ovh(artist: $0.artist, title: $0.title) }
    ) async -> Result<String, Failure> {
        let keyURL = key(track)
        let staleLyrics = read(keyURL)

        if let lyrics = staleLyrics, !lyrics.isEmpty, !isCacheStale(keyURL) {
            Log.lyrics.debug("source", metadata: ["path": "\(track.url.path)", "source": "cache"])
            return .success(lyrics)
        }

        let result = await fetch(track)
        if case .failure(.cancelled) = result { return result }

        if case .success(let lyrics) = result, !lyrics.isEmpty {
            Log.lyrics.info("source", metadata: ["path": "\(track.url.path)", "source": "lrclib"])
            Persist.write(Data(lyrics.utf8), to: keyURL)
            return .success(lyrics)
        }

        if let fallback = await ovh(track), !fallback.isEmpty {
            Log.lyrics.info("source", metadata: ["path": "\(track.url.path)", "source": "lyrics.ovh"])
            Persist.write(Data(fallback.utf8), to: keyURL)
            return .success(fallback)
        }

        if let lyrics = staleLyrics, !lyrics.isEmpty {
            Log.lyrics.info("source", metadata: ["path": "\(track.url.path)", "source": "stale cache"])
            return .success(lyrics)
        }

        Log.lyrics.info("source", metadata: ["path": "\(track.url.path)", "source": "none", "result": "\(String(describing: result))"])
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
            if attempt > 0, (try? await Task.sleep(for: .seconds(Double.random(in: retryDelay)))) == nil { return nil }
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                if Self.cancelled(error) {
                    Log.lyrics.debug("request cancelled", metadata: ["url": "\(url.absoluteString)"])
                    return nil
                }
                Log.lyrics.warning("request failed", metadata: ["url": "\(url.absoluteString)", "error": "\(error)"])
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Log.lyrics.info("response", metadata: ["url": "\(url.absoluteString)", "status": "\(status)", "bytes": "\(data.count)"])
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

    nonisolated static func cancelled(_ error: any Error) -> Bool {
        Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private nonisolated static func load(_ request: URLRequest) async -> Result<Any, Failure> {
        var failure = Failure.busy

        for retry in 0..<attempts {
            if retry > 0, (try? await Task.sleep(for: .seconds(Double.random(in: retryDelay)))) == nil { return .failure(.cancelled) }

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                if Self.cancelled(error) {
                    Log.lyrics.debug("request cancelled", metadata: ["url": "\(request.url?.absoluteString ?? "")"])
                    return .failure(.cancelled)
                }
                Log.lyrics.warning("request failed", metadata: ["url": "\(request.url?.absoluteString ?? "")", "error": "\(error)"])
                failure = .offline
                continue
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Log.lyrics.info("response", metadata: ["url": "\(request.url?.absoluteString ?? "")", "status": "\(status)", "bytes": "\(data.count)"])
            if status == 200 || status == 404 {
                guard let json = try? JSONSerialization.jsonObject(with: data) else {
                    if status == 200 { Log.lyrics.warning("invalid json", metadata: ["url": "\(request.url?.absoluteString ?? "")", "bytes": "\(data.count)"]) }
                    return .success([:])
                }
                return .success(json)
            }
            guard status == 429 || status >= 500 else { return .failure(.status(status)) }

            failure = .busy
        }

        Log.lyrics.error("request gave up", metadata: ["url": "\(request.url?.absoluteString ?? "")", "failure": "\(failure)"])
        return .failure(failure)
    }
}
