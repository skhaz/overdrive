import CryptoKit
import Foundation

nonisolated struct SyncedLine: Equatable, Sendable {
    let time: Double
    let text: String
}

@Observable
final class Lyrics {
    nonisolated enum Failure: Error {
        case offline
        case busy
        case status(Int)
    }

    private nonisolated static let cache = URL.applicationSupportDirectory.appending(path: "Overdrive/Lyrics")
    private nonisolated static let agent = "Overdrive/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") (https://github.com/skhaz/overdrive)"
    private nonisolated static let timeout: TimeInterval = 10
    private nonisolated static let attempts = 3
    private nonisolated static let retryDelay: ClosedRange<Double> = 1...3

    private(set) var track: Track?
    private(set) var loading = false
    private(set) var status = ""
    private(set) var original = ""
    private(set) var saved = ""
    var text = "" { didSet { if text != oldValue { synced = Lyrics.parse(text) } } }
    var visible = false
    var confirming = false

    @ObservationIgnored private var pending: (() -> Void)?
    @ObservationIgnored private var generation = 0

    var modified: Bool { text != original }
    var changed: Bool { text != saved }
    private(set) var synced: [SyncedLine] = []

    nonisolated static func ignored(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".lrc") || name.contains(".lrc.sb-")
    }

    func show(_ track: Track) {
        guard !visible || track != self.track else { return }

        confirm { self.open(track) }
    }

    func discard() {
        text = original
        pending?()
        pending = nil
    }

    func commit() {
        save()
        if !modified { pending?() }
        pending = nil
    }

    func cancel() {
        pending = nil
    }

    func refresh() {
        confirm {
            guard let track = self.track else { return }
            try? FileManager.default.removeItem(at: Lyrics.key(track))
            try? FileManager.default.removeItem(at: Lyrics.oldKey(track))
            self.open(track)
        }
    }

    func save() {
        guard let track else { return }
        generation += 1

        let url = Lyrics.file(track)

        do {
            if !text.isEmpty {
                try Data(text.utf8).write(to: url, options: .atomic)
                try? FileManager.default.createDirectory(at: Lyrics.cache, withIntermediateDirectories: true)
                try? Data(text.utf8).write(to: Lyrics.key(track), options: .atomic)
            } else {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try? FileManager.default.createDirectory(at: Lyrics.cache, withIntermediateDirectories: true)
                try? Data().write(to: Lyrics.key(track), options: .atomic)
                try? FileManager.default.removeItem(at: Lyrics.oldKey(track))
            }

            saved = text
            original = text
            status = "Saved"
        } catch {
            status = error.localizedDescription
        }
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
        status = ""

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
            if !lyrics.isEmpty { apply(.success(lyrics), from: "cache") }
            loading = false
            return
        }

        loading = true
        status = "Searching..."

        Task {
            let (result, source) = await Lyrics.lookup(track)
            guard generation == self.generation else { return }

            apply(result, from: source)
            loading = false
        }
    }

    private func apply(_ result: Result<String, Failure>, from source: String = "LRCLIB or lyrics.ovh") {
        switch result {
        case .success(let lyrics) where !lyrics.isEmpty:
            guard text.isEmpty else { return }
            original = lyrics
            text = lyrics
            status = "From \(source). Click Save to keep them."
        case .success:
            status = "No lyrics found."
        case .failure(.offline):
            status = "Could not reach LRCLIB."
        case .failure(.busy):
            status = "LRCLIB is busy. Open the song again later."
        case .failure(.status(let code)):
            status = "LRCLIB returned HTTP \(code)."
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
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: oldKey(track), to: key(track))
        return lyrics
    }

    private nonisolated static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    nonisolated static func parse(_ text: String) -> [SyncedLine] {
        var offset = 0.0
        var lines: [SyncedLine] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            var times: [Double] = []
            var plain = true
            while line.first == "[", let close = line.firstIndex(of: "]") {
                let tag = String(line[line.index(after: line.startIndex)..<close])
                if let time = stamp(tag) {
                    times.append(time)
                } else if tag.hasPrefix("offset:") {
                    offset = -(Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0) / 1000
                } else if !tag.contains(":") {
                    plain = false
                    break
                }
                line = String(line[line.index(after: close)...])
            }
            let words = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard plain, !times.isEmpty, !words.isEmpty else { continue }
            for time in times { lines.append(SyncedLine(time: max(time + offset, 0), text: words)) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    nonisolated static func index(at position: Double, in lines: [SyncedLine]) -> Int? {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= position {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : low - 1
    }

    private nonisolated static func stamp(_ tag: String) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, parts[0].allSatisfy(\.isNumber), let minutes = Double(parts[0]), let seconds = Double(parts[1]), seconds < 60 else { return nil }
        return minutes * 60 + seconds
    }

    @concurrent
    private nonisolated static func lookup(_ track: Track) async -> (Result<String, Failure>, String) {
        if let lyrics = cached(track), !lyrics.isEmpty { return (.success(lyrics), "cache") }
        try? FileManager.default.removeItem(at: key(track))
        try? FileManager.default.removeItem(at: oldKey(track))

        let result = await fetch(track)

        if case .success(let lyrics) = result, !lyrics.isEmpty {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? Data(lyrics.utf8).write(to: key(track), options: .atomic)
            return (result, "LRCLIB")
        }

        if let fallback = await ovh(artist: track.artist, title: track.title), !fallback.isEmpty {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? Data(fallback.utf8).write(to: key(track), options: .atomic)
            return (.success(fallback), "lyrics.ovh")
        }

        return (result, "LRCLIB")
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
