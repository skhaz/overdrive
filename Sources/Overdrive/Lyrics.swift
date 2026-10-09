import Foundation

@Observable
final class Lyrics {
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

        attempt { self.open(track) }
    }

    func hide() {
        attempt { self.visible = false }
    }

    func discard() {
        text = original
        pending?()
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

    private func attempt(_ action: @escaping () -> Void) {
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

        if let data = try? Data(contentsOf: Lyrics.file(track)) {
            saved = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
            original = saved
            text = saved
            loading = false
            return
        }

        saved = ""
        original = ""
        text = ""
        loading = true

        Task {
            let result = await Lyrics.fetch(track)
            guard generation == self.generation else { return }

            switch result {
            case .some(let lyrics) where !lyrics.isEmpty:
                original = lyrics
                text = lyrics
                status = "From LRCLIB. Click Save to keep them."
            case .some:
                status = "No lyrics found."
            case .none:
                status = "Could not reach LRCLIB."
            }

            loading = false
        }
    }

    private nonisolated static func file(_ track: Track) -> URL {
        track.url.deletingPathExtension().appendingPathExtension("lrc")
    }

    @concurrent
    private nonisolated static func fetch(_ track: Track) async -> String? {
        let get = request("get", [
            "artist_name": track.artist,
            "track_name": track.title,
            "album_name": track.album,
            "duration": String(Int(track.duration.rounded())),
        ])

        switch await load(get) {
        case .none:
            return nil
        case .some(let json as [String: Any]):
            if let lyrics = json["plainLyrics"] as? String { return lyrics }
        default:
            break
        }

        guard let results = await load(request("search", ["artist_name": track.artist, "track_name": track.title])) as? [[String: Any]] else { return "" }

        return results
            .filter { $0["plainLyrics"] is String }
            .min { abs(($0["duration"] as? Double ?? 0) - track.duration) < abs(($1["duration"] as? Double ?? 0) - track.duration) }?["plainLyrics"] as? String ?? ""
    }

    private nonisolated static func request(_ endpoint: String, _ parameters: [String: String]) -> URLRequest {
        var components = URLComponents(string: "https://lrclib.net/api/\(endpoint)")!
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")

        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private nonisolated static func load(_ request: URLRequest) async -> Any? {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode,
              status == 200 || status == 404 else { return nil }

        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }
}
