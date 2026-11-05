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
    /// The API gives the same default silhouette for every artist, so a row
    /// without a photo takes it from the artist's own page, and from the
    /// store of Apple only when the page has no photo. The picture is fetched
    /// at once, so the row shows it from the cache. A test replaces this.
    @ObservationIgnored var artwork: @Sendable (String) async -> URL? = { name in
        if let photo = await Similar.lastFMArtwork(name) {
            Similar.warm(photo)
            return photo
        }
        if let photo = await Similar.iTunesArtwork(name) {
            Similar.warm(photo)
            return photo
        }
        return nil
    }
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

            // The photo and the counts go to the services together, `lanes`
            // artists at a time. The photo goes to the same service as the
            // counts now, so every row waits its own place times `space`
            // before it asks anything, and a page never spends ten requests
            // in the same second.
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

    /// One row, in its own lane, after the row's own wait: the photo and the
    /// counts go out together and each lands when it arrives, so neither
    /// waits for the round trip of the other. A row that another answer
    /// already filled is never written twice.
    private func enrich(_ index: Int, _ name: String, _ asked: String, _ folded: String, _ place: Int) async {
        if place > 0 { try? await Task.sleep(for: space * Double(place)) }
        guard !Task.isCancelled, shown == folded, artists.indices.contains(index) else {
            return Log.similar.debug("load dropped", metadata: ["artist": "\(asked)", "reason": Task.isCancelled ? "cancelled" : "superseded", "at": "\(index)"])
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.takePhoto(index, name, asked, folded) }
            group.addTask { await self.takeCounts(index, name, asked, folded) }
        }
    }

    /// The photo of one row: not asked when the service already gave a real
    /// one, and never written over an answer that arrived first.
    private func takePhoto(_ index: Int, _ name: String, _ asked: String, _ folded: String) async {
        guard artists.indices.contains(index), artists[index].image == nil else { return }

        guard let picture = await artwork(name),
              !Task.isCancelled, shown == folded, artists.indices.contains(index), artists[index].image == nil else { return }
        artists[index].image = picture
    }

    /// The counts of one row, and the photo of the service when the search
    /// found none.
    private func takeCounts(_ index: Int, _ name: String, _ asked: String, _ folded: String) async {
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

    /// The photo of the artist from their own page on Last.fm. The API only
    /// answers one default silhouette, but the site keeps the photo the users
    /// gave the artist, and carries it in `og:image`; the app reads the page
    /// itself, as it reads the page of YouTube. The request looks like the
    /// browser it stands in for: a plain client gets a fingerprint challenge
    /// instead of the page. No `Range` is asked: the edge cuts the page
    /// before its own compression, and the answer comes broken half way.
    private nonisolated static func lastFMArtwork(_ artist: String) async -> URL? {
        guard let page = LastFM.artistPage(artist) else {
            Log.similar.debug("artist artwork", metadata: ["artist": "\(artist)", "from": "last.fm", "found": "false", "reason": "no page"])
            return nil
        }

        var request = URLRequest(url: page, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            Log.similar.debug("artist artwork", metadata: ["artist": "\(artist)", "from": "last.fm", "found": "false"])
            return nil
        }

        // The tag lives a few lines into the head, so the walk stops there and
        // cancels the rest: the half megabyte left is never read. One picture
        // never pays for the whole page.
        defer { bytes.task.cancel() }
        do {
            for try await line in bytes.lines {
                guard !Task.isCancelled else { return nil }
                if let picture = pagePhoto(line) {
                    Log.similar.debug("artist artwork", metadata: ["artist": "\(artist)", "from": "last.fm", "found": "true"])
                    return picture
                }
            }
        } catch {
            Log.similar.debug("artist artwork", metadata: ["artist": "\(artist)", "from": "last.fm", "found": "false", "error": "\(error.localizedDescription)"])
            return nil
        }

        Log.similar.debug("artist artwork", metadata: ["artist": "\(artist)", "from": "last.fm", "found": "false"])
        return nil
    }

    /// The hosts of the pictures keep them for years, so one fetch now puts
    /// the bytes in the cache of the session: the row takes the picture from
    /// there when it draws, instead of spending a second round trip.
    private nonisolated static func warm(_ photo: URL) {
        Task { _ = try? await URLSession.shared.data(from: photo) }
    }

    /// The photo of the artist in one line of the page: the line of `og:image`
    /// carries it in the big size (`ar0`), and the CDN cuts the same picture
    /// to the size the row draws (`174s`). A page with no photo carries the
    /// site logo, a challenge page carries nothing, and the other lines carry
    /// no `og:image` at all, so only the picture of an artist passes. The
    /// walk reads the line as it comes, with no regex over the whole page.
    nonisolated static func pagePhoto(_ line: String) -> URL? {
        guard line.contains(#"og:image""#), let value = line.range(of: #"content=""#),
              let end = line.range(of: #"""#, range: value.upperBound..<line.endIndex) else { return nil }
        return pagePicture(String(line[value.upperBound..<end.lowerBound]))
    }

    /// The address of the row in the size it draws, when the content of the
    /// tag is really the picture of an artist on the image host of the
    /// service: a big-size name (`ar0`, 32 hex digits) and nothing else.
    private nonisolated static func pagePicture(_ content: String) -> URL? {
        guard content.hasPrefix("https://lastfm-img"), content.hasSuffix(".jpg"), let mark = content.range(of: "/i/u/ar0/") else { return nil }
        let hash = content[mark.upperBound..<content.index(content.endIndex, offsetBy: -4)]
        guard hash.count == 32, hash.allSatisfy(\.isHexDigit) else { return nil }
        guard let photo = URL(string: "https://lastfm-img.freetls.fastly.net/i/u/174s/\(hash.lowercased()).jpg"), !LastFM.isDefault(photo) else { return nil }
        return photo
    }

    /// The photo of an artist from the iTunes Search API, the second choice
    /// when the page of the artist holds no photo: the cover of one of their
    /// songs. The store puts its popular songs first, so the app takes
    /// the first answer that is really the artist it asked for. It needs no
    /// key. The address of the cover is asked bigger than it arrives, the
    /// trick the store itself uses.
    private nonisolated static func iTunesArtwork(_ artist: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "attribute", value: "artistTerm"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25"),
        ]

        var request = URLRequest(url: components.url!, timeoutInterval: 10)
        request.setValue("Overdrive", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            Log.similar.debug("artist artwork", metadata: ["artist": "\(artist)", "from": "store", "found": "false"])
            return nil
        }

        let answers = results.compactMap { result -> (name: String, art: String)? in
            guard let art = result["artworkUrl100"] as? String, !art.isEmpty, let name = result["artistName"] as? String else { return nil }
            return (name, art)
        }

        guard let chosen = Self.cover(answers, artist) else {
            Log.similar.debug("artist artwork", metadata: ["artist": "\(artist)", "from": "store", "found": "false"])
            return nil
        }

        Log.similar.debug("artist artwork", metadata: ["artist": "\(artist)", "from": "store", "found": "true", "name": "\(chosen.name)"])
        return URL(string: chosen.art.replacingOccurrences(of: "100x100bb", with: "300x300bb"))
    }

    /// The cover of the artist among the answers, in the order the store
    /// ranks them: its popular songs come first. The store matches loose
    /// names, so the app takes the first answer that is the very name it
    /// asked (folded), then a name that starts with it, then a name close
    /// enough to it (`Similarity`). With none of these the artist has no
    /// cover: asked for Empire of Souls, the store puts Iron Maiden first
    /// (the song "Empire of the Clouds"), and without this walk a cover
    /// band or the top hit of a loose search stands for the artist.
    nonisolated static func cover(_ answers: [(name: String, art: String)], _ artist: String) -> (name: String, art: String)? {
        let asked = Fuzzy.fold(artist)
        if let exact = answers.first(where: { Fuzzy.fold($0.name) == asked }) { return exact }
        if let near = answers.first(where: { Fuzzy.fold($0.name).hasPrefix(asked) }) { return near }
        let mine = Similarity.letters(artist)
        return answers.first { Similarity.close(Similarity.letters($0.name), mine) != nil }
    }
}
