import Foundation

/// The Curiosity tab of the lyrics panel: the most curious facts about the
/// artist that shows, asked of OpenRouter with the key from Settings. Only the
/// key goes to the disk. The facts live in memory, for the artist that shows.
@Observable
final class Curiosity {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    nonisolated struct Configuration {
        var endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        /// Nil keeps the key in memory only.
        var file: URL? = URL.applicationSupportDirectory.appending(path: "Overdrive/openrouter.plist")
        var transport: Transport = Curiosity.session
        var language = Locale.preferredLanguages.first ?? "en"
    }

    private nonisolated struct Reply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]
    }

    private nonisolated struct Answer: Decodable {
        let facts: [String]
    }

    private nonisolated enum Outcome: Sendable {
        case facts([String])
        case failed(String)
    }

    nonisolated static let model = "openai/gpt-6.1-terra"
    nonisolated static let top = 5
    nonisolated static let timeout: TimeInterval = 60
    nonisolated static let none = "No curiosities found."

    nonisolated static let session: Transport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        return { try await session.data(for: $0) }
    }()

    private(set) var key: String
    private(set) var facts: [String] = []
    private(set) var loading = false
    private(set) var note = Curiosity.none

    @ObservationIgnored private let configuration: Configuration
    @ObservationIgnored private var shown = ""
    @ObservationIgnored private var filled = ""
    @ObservationIgnored private var artist = ""
    @ObservationIgnored private var album = ""
    @ObservationIgnored private var song = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    init(_ configuration: Configuration = Configuration()) {
        self.configuration = configuration
        key = configuration.file.flatMap { Persist.read([String: String].self, from: $0)?["key"] } ?? ""
    }

    /// The tab only exists with a key.
    var available: Bool { !key.isEmpty }

    func save(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Log.curiosity.debug("key ignored", metadata: ["reason": "empty"]) }

        key = trimmed
        Log.curiosity.info("key saved")
        guard let file = configuration.file, let data = Persist.encode(["key": trimmed], for: file) else { return }

        Persist.write(data, to: file)
    }

    func remove() {
        Log.curiosity.info("key removed")
        reset()
        key = ""
        if let file = configuration.file { Persist.remove(file) }
    }

    /// The artist of the panel changed: what was asked for the last one goes.
    func show(_ track: Track) {
        reset()
        shown = Fuzzy.fold(track.artist)
        artist = track.artist
        album = track.album
        song = track.title
    }

    func reload() {
        filled = ""
        load()
    }

    /// Asks once per artist: the answer stays while the artist shows, and an
    /// empty or failed answer is not kept, so Retry asks again.
    func load() {
        guard available else { return Log.curiosity.debug("load ignored", metadata: ["reason": "no key"]) }
        guard !artist.isEmpty else { return Log.curiosity.debug("load ignored", metadata: ["reason": "no artist"]) }
        guard shown != filled else { return Log.curiosity.debug("load ignored", metadata: ["artist": "\(artist)", "reason": "cached"]) }
        guard !loading else { return Log.curiosity.debug("load ignored", metadata: ["artist": "\(artist)", "reason": "in flight"]) }
        guard let request = Self.request(artist: artist, album: album, song: song, key: key, language: configuration.language, endpoint: configuration.endpoint) else {
            note = Self.failure(0)
            return Log.curiosity.error("load failed", metadata: ["artist": "\(artist)", "reason": "request"])
        }

        let asked = artist, folded = shown
        loading = true
        facts = []
        note = Self.none
        Log.curiosity.info("load", metadata: ["artist": "\(asked)", "model": "\(Self.model)", "language": "\(configuration.language)"])

        task = Task { [weak self, transport = configuration.transport] in
            let outcome = await Self.fetch(request, transport, asked)
            guard let self, !Task.isCancelled, shown == folded else {
                return Log.curiosity.debug("load dropped", metadata: ["artist": "\(asked)", "reason": Task.isCancelled ? "cancelled" : "superseded"])
            }

            loading = false
            switch outcome {
            case .facts(let found):
                facts = found
                if !found.isEmpty { filled = folded }
                Log.curiosity.info("loaded", metadata: ["artist": "\(asked)", "got": "\(found.count)"])
            case .failed(let message):
                note = message
            }
        }
    }

    private func reset() {
        task?.cancel()
        task = nil
        shown = ""
        filled = ""
        artist = ""
        album = ""
        song = ""
        facts = []
        loading = false
        note = Self.none
    }

    private nonisolated static func fetch(_ request: URLRequest, _ transport: Transport, _ artist: String) async -> Outcome {
        do {
            let (data, response) = try await transport(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                Log.curiosity.warning("load failed", metadata: ["artist": "\(artist)", "status": "\(status)", "bytes": "\(data.count)"])
                return .failed(failure(status))
            }
            guard let found = parse(data) else {
                Log.curiosity.warning("load failed", metadata: ["artist": "\(artist)", "reason": "invalid response", "bytes": "\(data.count)"])
                return .failed(failure(0))
            }

            return .facts(found)
        } catch {
            Log.curiosity.warning("load failed", metadata: ["artist": "\(artist)", "error": "\(error.localizedDescription)"])
            return .failed(failure(0))
        }
    }

    nonisolated static func request(artist: String, album: String, song: String, key: String, language: String, endpoint: URL) -> URLRequest? {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["facts": ["type": "array", "items": ["type": "string"]]],
            "required": ["facts"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions(language)],
                ["role": "user", "content": "Artist: \(artist)\nAlbum: \(album)\nSong: \(song)"],
            ],
            "provider": ["require_parameters": true],
            "response_format": ["type": "json_schema", "json_schema": ["name": "curiosities", "strict": true, "schema": schema]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    nonisolated static func instructions(_ language: String) -> String {
        let name = Locale(identifier: "en").localizedString(forIdentifier: language) ?? language
        return """
        You write music trivia about a band or music artist. Give the most surprising true facts about the artist as a whole \
        (its people, its history, its name, its odd events), at most \(top), the most curious first. The album and song only tell you \
        which artist this is; do not write about them unless the fact is about the artist. Give fewer when fewer are known, and none \
        when you do not know this artist or cannot tell which artist this is. Never guess or invent. Each fact is one direct sentence \
        with a concrete detail. Plain text only, no markdown. No introduction, no conclusion, no opinion, no hedging, no promotional \
        words, no bullet characters. Never address the reader. Write every fact in \(name), language tag \(language).
        """
    }

    /// The facts of one answer, or nil when it is not the shape the schema
    /// asks. The panel draws the bullets, and a repeated fact would repeat the
    /// identity of its row.
    nonisolated static func parse(_ data: Data) -> [String]? {
        let decoder = JSONDecoder()
        guard let content = (try? decoder.decode(Reply.self, from: data))?.choices.first?.message.content,
              let answer = try? decoder.decode(Answer.self, from: Data(content.utf8)) else { return nil }

        let extra = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-•*"))
        var seen = Set<String>()
        var facts: [String] = []

        for fact in answer.facts where facts.count < top {
            let clean = fact.trimmingCharacters(in: extra)
            if !clean.isEmpty, seen.insert(clean).inserted { facts.append(clean) }
        }

        return facts
    }

    nonisolated static func failure(_ status: Int) -> String {
        switch status {
        case 401, 403: "OpenRouter refused the API key."
        case 402: "OpenRouter has no credits left."
        case 429: "OpenRouter is busy. Try again soon."
        default: "Could not load curiosities."
        }
    }
}
