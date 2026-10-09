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
    private nonisolated static let agent = "Overdrive/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0") (https://github.com/skhaz/overdrive)"

    private(set) var track: Track?
    private(set) var loading = false
    private(set) var status = ""
    private(set) var original = ""
    private(set) var saved = ""
    var text = ""
    var visible = false
    var confirming = false

    @ObservationIgnored private var pending: (() -> Void)?
    @ObservationIgnored private var generation = 0

    var modified: Bool { text != original }
    var changed: Bool { text != saved }

    nonisolated static func ignored(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".lrc") || name.contains(".lrc.sb-")
    }

    func show(_ track: Track?) {
        guard let track else {
            visible = true
            return
        }

        guard !visible || track != self.track else { return }

        confirm { self.open(track) }
    }

    func hide() {
        confirm { self.visible = false }
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

    func save() {
        guard let track else { return }

        let url = Lyrics.file(track)

        do {
            if !text.isEmpty {
                try Data(text.utf8).write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }

            saved = text
            original = text
            status = "Saved."
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

        if let lyrics = Lyrics.read(Lyrics.key(track)) {
            apply(.success(lyrics))
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
        switch result {
        case .success(let lyrics) where !lyrics.isEmpty:
            original = lyrics
            text = lyrics
            status = "From LRCLIB. Click Save to keep them."
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
        return cache.appending(path: digest.map { String(format: "%02x", $0) }.joined() + ".txt")
    }

    private nonisolated static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    @concurrent
    private nonisolated static func lookup(_ track: Track) async -> Result<String, Failure> {
        if let lyrics = read(key(track)) { return .success(lyrics) }

        let result = await fetch(track)

        if case .success(let lyrics) = result {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? Data(lyrics.utf8).write(to: key(track), options: .atomic)
        }

        return result
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
            if let lyrics = (json as? [String: Any])?["plainLyrics"] as? String { return .success(lyrics) }
        }

        return await load(request("search", ["artist_name": track.artist, "track_name": track.title])).map { json in
            (json as? [[String: Any]] ?? [])
                .filter { $0["plainLyrics"] is String }
                .min { abs(($0["duration"] as? Double ?? 0) - track.duration) < abs(($1["duration"] as? Double ?? 0) - track.duration) }?["plainLyrics"] as? String ?? ""
        }
    }

    private nonisolated static func request(_ endpoint: String, _ parameters: [String: String]) -> URLRequest {
        var components = URLComponents(string: "https://lrclib.net/api/\(endpoint)")!
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")

        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private nonisolated static func load(_ request: URLRequest) async -> Result<Any, Failure> {
        var failure = Failure.busy

        for retry in 0...3 {
            if retry > 0 { try? await Task.sleep(for: .seconds(Double.random(in: 1...3))) }

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
