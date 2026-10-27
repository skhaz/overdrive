import AppKit

/// Discovery from Last.fm: your top artists, and for each one the top track that
/// your library actually holds. No cache: a click asks the internet once.
@Observable
final class Discovery {
    /// How many artists are asked at a time. Small on purpose: Last.fm answers 29
    /// when one IP spends its rate, and a discovery of 100 songs is 101 requests.
    nonisolated static let window = 4
    /// How many top tracks of one artist are read to find a song the library has.
    nonisolated static let tracks = 10

    /// The song of one artist that the library holds, from the highest-ranked title
    /// that matches a song name by at least `Similarity.threshold`. A tie goes to the
    /// song that comes first in the library, so the answer is stable.
    nonisolated static func owned(_ titles: [String], _ songs: [Track]) -> Track? {
        for title in titles {
            var best: (track: Track, ratio: Double)?

            for song in songs {
                let ratio = Similarity.ratio(title, song.title)
                guard ratio >= Similarity.threshold, ratio > (best?.ratio ?? 0) else { continue }

                best = (song, ratio)
            }

            if let best { return best.track }
        }

        return nil
    }

    /// Walks the artists in the given order and stops at the first `count` songs it
    /// can name, so a short list is never padded with songs you do not have.
    /// `wanted` is the library lookup, already done on the calling actor; `titles`
    /// is one request per artist, four at a time.
    nonisolated static func collect(_ count: Int, _ wanted: [(name: String, songs: [Track])],
                                    _ titles: @escaping @Sendable (String) async -> [String]) async -> [Track]
    {
        let names = wanted.filter { !$0.songs.isEmpty }
        var found: [Track] = []
        var seen: Set<Track.ID> = []
        var start = 0

        while start < names.count, found.count < count {
            let slice = Array(names[start..<min(start + window, names.count)])

            let picked = await withTaskGroup(of: (index: Int, track: Track?).self) { group in
                for (index, pair) in slice.enumerated() {
                    group.addTask {
                        let found = await titles(pair.name)
                        return (index, owned(found, pair.songs))
                    }
                }

                var byIndex: [Int: Track] = [:]
                for await (index, track) in group {
                    if let track { byIndex[index] = track }
                }

                return slice.indices.compactMap { byIndex[$0] }
            }

            for track in picked where found.count < count {
                if seen.insert(track.id).inserted { found.append(track) }
            }

            start += window
        }

        return found
    }

    private(set) var running = false

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let lastFM: LastFM
    @ObservationIgnored private let player: Player

    init(library: Library, lastFM: LastFM, player: Player) {
        self.library = library
        self.lastFM = lastFM
        self.player = player
    }

    /// The picker is offered only with an API key, a signed-in user, and songs.
    var ready: Bool {
        !LastFM.key.isEmpty && !lastFM.user.isEmpty && !library.albums.isEmpty
    }

    func topSongs(_ count: Int) {
        guard ready else {
            return Log.player.warning("discovery ignored", metadata: ["reason": "no last.fm", "songs": "\(count)"])
        }
        guard !running else {
            return Log.player.debug("discovery ignored", metadata: ["reason": "running", "songs": "\(count)"])
        }

        running = true
        Log.player.info("discovery", metadata: ["songs": "\(count)", "user": "\(lastFM.user)"])

        Task {
            let tracks = await collect(count)
            running = false
            guard !tracks.isEmpty else { return Log.player.warning("discovery empty", metadata: ["asked": "\(count)"]) }

            player.random(tracks)
            NotificationCenter.default.post(name: .discovery, object: nil)
        }
    }

    /// Walks your artists in your own order and stops at the first `count` songs it
    /// can name, so a short list is never padded with songs you do not have.
    private func collect(_ count: Int) async -> [Track] {
        let names = await lastFM.topArtists(count)
        guard !names.isEmpty else {
            Log.player.debug("discovery stopped", metadata: ["reason": "no artists"])
            return []
        }

        let songs = names.map { library.songs(by: $0) }
        let wanted = zip(names, songs).map { (name: $0.0, songs: $0.1) }
        let held = wanted.filter { !$0.songs.isEmpty }.count
        let fm = lastFM
        let found = await Discovery.collect(count, wanted) { await fm.topTracks($0, Discovery.tracks) }

        Log.player.info("discovery result", metadata: ["asked": "\(count)", "artists": "\(names.count)", "held": "\(held)", "found": "\(found.count)"])
        return found
    }
}
