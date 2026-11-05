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

    /// The wait between the requests that add the genre and the listeners to
    /// the list. Last.fm answers 29 when one IP spends its rate.
    nonisolated static let gap: Duration = .milliseconds(300)

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

    @ObservationIgnored var gap = Similar.gap
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

            var filled = 0
            for index in artists.indices {
                try? await Task.sleep(for: gap)
                guard !Task.isCancelled, shown == folded else {
                    return Log.similar.debug("load dropped", metadata: ["artist": "\(asked)", "reason": Task.isCancelled ? "cancelled" : "superseded", "at": "\(index)"])
                }

                if let info = await lastFM.artistInfo(artists[index].name), !Task.isCancelled, shown == folded, artists.indices.contains(index) {
                    artists[index].listeners = info.listeners
                    artists[index].genre = info.tag
                    if artists[index].image == nil { artists[index].image = info.image }
                    filled += 1
                }
            }
            Log.similar.debug("filled", metadata: ["artist": "\(asked)", "of": "\(filled)"])
        }
    }
}
