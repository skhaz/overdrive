import AppKit

@Observable
final class Discovery {
    enum Pool: String {
        case songs, unplayed, played, artists, bands
    }

    nonisolated static let window = 4
    nonisolated static let tracks = 5
    nonisolated static let attempts = 10
    nonisolated static let pool = 5
    nonisolated static let least = 20
    nonisolated static let most = 200

    /// How many artists the chart is asked for, so the ones that play are drawn
    /// from a pool and not always the same names at the top of the list.
    nonisolated static func reach(_ count: Int) -> Int {
        min(max(count * pool, least), most)
    }

    /// One title of the internet that the library holds, with what it took to
    /// find it: the spelling that matched and how many titles were drawn.
    nonisolated struct Match {
        let track: Track
        let title: String
        let draws: Int
    }

    /// The names of the library songs, folded once, so many titles cost one
    /// dictionary read each and a few comparisons.
    nonisolated struct Held {
        private let exact: [String: Track]
        private let names: [(track: Track, letters: [Unicode.Scalar])]

        init(_ songs: [Track]) {
            var exact: [String: Track] = [:]
            var names: [(track: Track, letters: [Unicode.Scalar])] = []
            exact.reserveCapacity(songs.count)
            names.reserveCapacity(songs.count)

            for song in songs {
                let letters = Similarity.letters(song.title)
                guard !letters.isEmpty else { continue }

                let key = Similarity.normal(letters)
                if exact[key] == nil { exact[key] = song }
                names.append((song, letters))
            }

            self.exact = exact
            self.names = names
        }

        var isEmpty: Bool { names.isEmpty }

        func one(_ title: String) -> Track? {
            let letters = Similarity.letters(title)
            guard !letters.isEmpty else { return nil }
            if let held = exact[Similarity.normal(letters)] { return held }

            var best: (track: Track, ratio: Double)?

            for candidate in names {
                guard let ratio = Similarity.close(letters, candidate.letters) else { continue }
                guard ratio > (best?.ratio ?? 0) else { continue }

                best = (candidate.track, ratio)
            }

            return best?.track
        }
    }

    nonisolated static func owned(_ titles: [String], _ songs: [Track]) -> Track? {
        guard !titles.isEmpty, !songs.isEmpty else { return nil }

        let held = Held(songs)
        for title in titles {
            if let track = held.one(title) { return track }
        }

        return nil
    }

    /// A title drawn at random from the chart of one artist, over and over
    /// until one of them is a song the library holds. The draw is with
    /// replacement, and the artist is skipped after `attempts` misses.
    nonisolated static func choose(_ titles: [String], _ songs: [Track], attempts: Int,
                                   using draw: (Int) -> Int) -> Match?
    {
        guard !titles.isEmpty, !songs.isEmpty, attempts > 0 else { return nil }

        let held = Held(songs)
        guard !held.isEmpty else { return nil }

        for attempt in 1...attempts {
            let index = draw(titles.count)
            guard titles.indices.contains(index) else { continue }
            guard let track = held.one(titles[index]) else { continue }

            return Match(track: track, title: titles[index], draws: attempt)
        }

        return nil
    }

    /// `count` names of the pool, drawn at random and never repeated. The draw
    /// is a partial shuffle, so every name of the pool can be one of them.
    nonisolated static func draw(_ pool: [String], _ count: Int, using pick: (Int) -> Int) -> [String] {
        guard count > 0, !pool.isEmpty else { return [] }

        var names: [String] = []
        var seen: Set<String> = []
        names.reserveCapacity(min(count, pool.count))

        for name in pool where !name.isEmpty {
            if seen.insert(name).inserted { names.append(name) }
        }

        var drawn: [String] = []
        drawn.reserveCapacity(min(count, names.count))
        var remaining = names.count

        while remaining > 0, drawn.count < count {
            let index = min(max(pick(remaining), 0), remaining - 1)
            names.swapAt(index, remaining - 1)
            drawn.append(names[remaining - 1])
            remaining -= 1
        }

        return drawn
    }

    nonisolated static func collect(_ count: Int, _ wanted: [(name: String, songs: [Track])],
                                    attempts: Int = attempts,
                                    draw: @escaping @Sendable (Int) -> Int = { Int.random(in: 0..<$0) },
                                    _ titles: @escaping @Sendable (String) async -> [String]) async -> [Track]
    {
        let names = wanted.filter { !$0.songs.isEmpty }
        var found: [Track] = []
        var seen: Set<Track.ID> = []
        var start = 0

        while start < names.count, found.count < count {
            guard !Task.isCancelled else {
                Log.player.debug("discovery stopped", metadata: ["reason": "cancelled", "found": "\(found.count)"])
                return found
            }

            let slice = Array(names[start..<min(start + min(window, count - found.count), names.count)])

            let picked = await withTaskGroup(of: (index: Int, track: Track?).self) { group in
                for (index, pair) in slice.enumerated() {
                    group.addTask {
                        let found = await titles(pair.name)
                        let match = choose(found, pair.songs, attempts: attempts, using: draw)
                        Log.player.debug("artist drawn", metadata: ["artist": "\(pair.name)", "titles": "\(found.count)", "draws": "\(match?.draws ?? 0)", "found": "\(match?.title ?? "")"])
                        return (index, match?.track)
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

            start += slice.count
        }

        return found
    }

    private(set) var running = false

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let lastFM: LastFM
    @ObservationIgnored private let player: Player
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var work: Task<Void, Never>?

    init(library: Library, lastFM: LastFM, player: Player) {
        self.library = library
        self.lastFM = lastFM
        self.player = player
    }

    var ready: Bool {
        !LastFM.key.isEmpty && !lastFM.user.isEmpty && !library.albums.isEmpty
    }

    func pick(_ pool: Pool, _ count: Int) {
        if pool == .artists || pool == .bands, !ready {
            return Log.player.warning("discovery ignored", metadata: ["pool": "\(pool.rawValue)", "reason": "no last.fm", "songs": "\(count)"])
        }

        generation += 1
        let mine = generation
        work?.cancel()
        work = nil
        running = false

        Log.player.info("discovery", metadata: ["pool": "\(pool.rawValue)", "songs": "\(count)"])

        switch pool {
        case .songs:
            start(library.random(count), mine, pool, count)
        case .unplayed:
            start(library.unplayed(count), mine, pool, count)
        case .played:
            start(library.topmost(count), mine, pool, count)
        case .artists, .bands:
            running = true
            work = Task {
                let tracks = await self.walk(pool, count)
                guard mine == self.generation else {
                    return Log.player.debug("discovery superseded", metadata: ["pool": "\(pool.rawValue)", "songs": "\(count)"])
                }

                self.running = false
                self.work = nil
                self.start(tracks, mine, pool, count)
            }
        }
    }

    private func start(_ tracks: [Track], _ mine: Int, _ pool: Pool, _ count: Int) {
        guard mine == generation else {
            return Log.player.debug("discovery superseded", metadata: ["pool": "\(pool.rawValue)", "songs": "\(count)"])
        }
        guard !tracks.isEmpty else {
            return Log.player.warning("discovery empty", metadata: ["pool": "\(pool.rawValue)", "asked": "\(count)"])
        }

        player.random(tracks)
        NotificationCenter.default.post(name: .discovery, object: nil)
    }

    private func walk(_ pool: Pool, _ count: Int) async -> [Track] {
        let wanted: [(name: String, songs: [Track])]

        switch pool {
        case .artists:
            let chart = await lastFM.topArtists(Discovery.reach(count))
            let drawn = Discovery.draw(chart, count, using: { Int.random(in: 0..<$0) })
            Log.player.info("artists drawn", metadata: ["asked": "\(count)", "chart": "\(chart.count)", "drawn": "\(drawn.count)"])
            wanted = drawn.map { (name: $0, songs: library.songs(by: $0)) }
        default:
            wanted = library.topBands(count)
        }

        guard !wanted.isEmpty else {
            Log.player.debug("discovery stopped", metadata: ["pool": "\(pool.rawValue)", "reason": "no artists"])
            return []
        }
        guard !Task.isCancelled else {
            Log.player.debug("discovery stopped", metadata: ["pool": "\(pool.rawValue)", "reason": "cancelled"])
            return []
        }

        let held = wanted.filter { !$0.songs.isEmpty }.count
        let fm = lastFM
        let found = await Discovery.collect(count, wanted) { await fm.topTracks($0, Discovery.tracks) }

        Log.player.info("discovery result", metadata: ["pool": "\(pool.rawValue)", "asked": "\(count)", "artists": "\(wanted.count)", "held": "\(held)", "found": "\(found.count)"])
        return found
    }
}
