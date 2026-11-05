import AppKit
import Foundation

/// The Similar tab of the lyrics panel: the artists Last.fm says sound like
/// the song that plays. It lives only while an account is connected, and it
/// keeps nothing on the disk.
@Observable
final class Similar {
    /// Which half of the lyrics panel shows. The lyrics are the default.
    nonisolated enum Tab: String {
        case lyrics, similar
    }

    /// The tab shows the ten artists the service ranks most similar.
    nonisolated static let top = 10

    /// The place between the requests that add the genre and the listeners to
    /// the list. The rows run together, `lanes` at a time, but each waits its
    /// own place times this before it asks Last.fm, so ten artists never start
    /// ten requests in the same second and the service does not answer 29.
    nonisolated static let space: Duration = .milliseconds(60)

    /// How many rows are filled at the same time: the photos and the counts
    /// run together, this many artists at once.
    nonisolated static let lanes = ProcessInfo.processInfo.activeProcessorCount * 2

    nonisolated struct Entry: Identifiable, Equatable {
        let name: String
        let url: URL?
        var image: URL?
        var listeners: Int?
        var genre: String?

        var id: String { name }
    }

    private(set) var tab = Tab.lyrics
    private(set) var artists: [Entry] = []
    private(set) var loading = false

    @ObservationIgnored var space = Similar.space
    /// The photo the API gives is the same default silhouette for every
    /// artist, so a row without a photo asks for one elsewhere. A test
    /// replaces this.
    @ObservationIgnored var artwork: @Sendable (String) async -> URL? = { await Similar.iTunesArtwork($0) }
    @ObservationIgnored private let lastFM: LastFM
    @ObservationIgnored private var shown = ""
    @ObservationIgnored private var artist = ""
    @ObservationIgnored private var filled = ""
    @ObservationIgnored private var task: Task<Void, Never>?

    init(lastFM: LastFM) {
        self.lastFM = lastFM
    }

    /// The tabs only exist with an account: without one the panel is only the lyrics.
    var available: Bool { !lastFM.user.isEmpty }

    /// The song the panel shows. A new song of the same artist keeps the tab;
    /// a new artist takes the panel back to the lyrics and drops the list.
    func show(_ track: Track?) {
        guard let track else { return }
        let folded = Fuzzy.fold(track.artist)
        guard folded != shown else { return }

        if tab == .similar { Log.similar.info("tab", metadata: ["to": "\(Tab.lyrics)", "reason": "artist", "artist": "\(track.artist)"]) }

        task?.cancel()
        task = nil
        shown = folded
        artist = track.artist
        tab = .lyrics
        artists = []
        filled = ""
        loading = false
    }

    func select(_ tab: Tab) {
        guard tab != self.tab else { return }
        guard tab != .similar || available else {
            return Log.similar.debug("select ignored", metadata: ["reason": "no account"])
        }

        Log.similar.info("tab", metadata: ["to": "\(tab)", "artist": "\(artist)"])
        self.tab = tab
        if tab == .similar { load() }
    }

    /// Ask the service again for the artist that shows.
    func reload() {
        guard tab == .similar else { return Log.similar.debug("reload ignored", metadata: ["reason": "not showing"]) }

        filled = ""
        load()
    }

    private func load() {
        guard !artist.isEmpty else { return Log.similar.debug("load ignored", metadata: ["reason": "no artist"]) }
        let folded = shown
        guard folded != filled else { return Log.similar.debug("load ignored", metadata: ["artist": "\(artist)", "reason": "cached"]) }

        task?.cancel()
        loading = true
        artists = []
        let asked = artist
        Log.similar.info("load", metadata: ["artist": "\(asked)"])

        task = Task { [weak self, lastFM] in
            let found = await lastFM.similar(asked, Similar.top)
            guard let self, !Task.isCancelled, shown == folded else {
                return Log.similar.debug("load dropped", metadata: ["artist": "\(asked)", "reason": Task.isCancelled ? "cancelled" : "superseded", "at": "list"])
            }

            artists = found.map { Entry(name: $0.name, url: $0.url, image: $0.image) }
            loading = false
            if !found.isEmpty { filled = folded }
            Log.similar.info("loaded", metadata: ["artist": "\(asked)", "got": "\(found.count)"])

            // The photo goes to the store of Apple and the counts to Last.fm.
            // Both are asked together, `lanes` artists at a time; every row
            // waits its own place times `space` before it asks Last.fm, so a
            // page never spends ten requests in the same second.
            let wanted = artists.indices.map { (index: $0, name: artists[$0].name) }
            Log.similar.debug("lane", metadata: ["lanes": "\(Similar.lanes)", "artists": "\(wanted.count)"])

            await withTaskGroup(of: Void.self) { group in
                var next = 0

                while next < wanted.count, next < Similar.lanes {
                    let row = wanted[next]
                    let place = next
                    group.addTask { await self.enrich(row.index, row.name, asked, folded, place) }
                    next += 1
                }

                while await group.next() != nil {
                    guard next < wanted.count else { continue }
                    let row = wanted[next]
                    let place = next
                    group.addTask { await self.enrich(row.index, row.name, asked, folded, place) }
                    next += 1
                }
            }

            Log.similar.debug("filled", metadata: ["artist": "\(asked)"])
        }
    }

    /// One row, in its own lane: the photo first, because the store answers
    /// without a rate, then the counts, after the row's own wait for Last.fm.
    /// A row that another answer already filled is never written twice.
    private func enrich(_ index: Int, _ name: String, _ asked: String, _ folded: String, _ place: Int) async {
        if artists.indices.contains(index), artists[index].image == nil, let picture = await artwork(name),
           !Task.isCancelled, shown == folded, artists.indices.contains(index), artists[index].image == nil {
            artists[index].image = picture
        }

        if place > 0 { try? await Task.sleep(for: space * Double(place)) }
        guard !Task.isCancelled, shown == folded, artists.indices.contains(index) else {
            return Log.similar.debug("load dropped", metadata: ["artist": "\(asked)", "reason": Task.isCancelled ? "cancelled" : "superseded", "at": "\(index)"])
        }

        guard let info = await lastFM.artistInfo(name) else { return }
        guard !Task.isCancelled, shown == folded, artists.indices.contains(index) else {
            return Log.similar.debug("load dropped", metadata: ["artist": "\(asked)", "reason": Task.isCancelled ? "cancelled" : "superseded", "at": "\(index)"])
        }

        artists[index].listeners = info.listeners
        artists[index].genre = info.tag
        if artists[index].image == nil { artists[index].image = info.image }
    }

    /// The page of one artist: the one the service answered, or the page of
    /// its name when the answer carried no page.
    nonisolated static func page(_ artist: Entry) -> URL? {
        artist.url ?? LastFM.artistPage(artist.name)
    }

    /// Opens the Last.fm page of an artist in the browser.
    func open(_ artist: Entry) {
        guard let page = Self.page(artist) else {
            return Log.similar.debug("open ignored", metadata: ["artist": "\(artist.name)", "reason": "no page"])
        }

        Log.similar.info("open artist", metadata: ["artist": "\(artist.name)", "url": "\(page.absoluteString)"])
        NSWorkspace.shared.open(page)
    }

    /// Puts the name of an artist on the pasteboard.
    func copyName(_ artist: Entry) {
        Log.similar.info("copy name", metadata: ["artist": "\(artist.name)"])
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(artist.name, forType: .string)
    }

    /// The photo of an artist: the cover of the latest release, from the
    /// iTunes Search API. The store answers the albums and singles of an
    /// artist with their dates, so the app keeps the newest that has a cover.
    /// The service matches loose names, so the app walks the answers in
    /// three steps: releases of the artist under the very name asked, then
    /// ones that start with it, then the first cover of the list. Last.fm
    /// stopped answering real photos years ago, and this needs no key. The
    /// address of the cover is asked bigger than it arrives, the trick the
    /// store itself uses.
    private nonisolated static func iTunesArtwork(_ artist: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "attribute", value: "artistTerm"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "200"),
        ]

        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("Overdrive", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            Log.similar.debug("artist artwork", metadata: ["artist": "\(artist)", "found": "false"])
            return nil
        }

        let answers = results.compactMap { result -> (name: String, date: String, art: String)? in
            guard let art = result["artworkUrl100"] as? String, !art.isEmpty, let name = result["artistName"] as? String else { return nil }
            return (name, result["releaseDate"] as? String ?? "", art)
        }
        let asked = Fuzzy.fold(artist)
        let exact = answers.filter { Fuzzy.fold($0.name) == asked }
        let near = answers.filter { Fuzzy.fold($0.name).hasPrefix(asked) }

        guard let chosen = Self.newest(exact) ?? Self.newest(near) ?? answers.first else {
            Log.similar.debug("artist artwork", metadata: ["artist": "\(artist)", "found": "false"])
            return nil
        }

        Log.similar.debug("artist artwork", metadata: ["artist": "\(artist)", "found": "true", "release": "\(chosen.date.prefix(10))", "name": "\(chosen.name)"])
        return URL(string: chosen.art.replacingOccurrences(of: "100x100bb", with: "300x300bb"))
    }

    /// The release with the newest date. The dates arrive as ISO strings, so
    /// the later text is the later release.
    private nonisolated static func newest(_ answers: [(name: String, date: String, art: String)]) -> (name: String, date: String, art: String)? {
        answers.max { $0.date < $1.date }
    }
}
