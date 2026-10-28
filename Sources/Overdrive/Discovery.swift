import AppKit

@Observable
final class Discovery {
    enum Pool: String {
        case songs, unplayed, played, artists, bands
    }

    nonisolated static let window = 4
    nonisolated static let tracks = 5

    /// The milliseconds a network pick may run before the Up Next list shows its
    /// spinner. A faster answer never flickers one.
    nonisolated static let spinAfter: UInt64 = 200

    /// The two stages a discovery announces: the pick the user chose, and the
    /// songs that arrived. The screen opens on both, so a pick that spends
    /// requests is on screen while it works.
    nonisolated static let opening = "open"
    nonisolated static let done = "done"
    nonisolated static let pool = 5
    nonisolated static let least = 20
    nonisolated static let most = 200

    /// How many artists the chart is asked for, so the ones that play are drawn
    /// from a pool and not always the same names at the top of the list.
    nonisolated static func reach(_ count: Int) -> Int {
        min(max(count * pool, least), most)
    }

    /// One title of the internet that the library holds, with the number of
    /// titles of the chart that a song of yours matches.
    nonisolated struct Match {
        let track: Track
        let title: String
        let candidates: Int
    }

    /// The names of the library songs of one artist, folded once, so every
    /// title of the chart costs one dictionary read and a few comparisons.
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

        /// The song of the library that a title of the chart is, the closest
        /// name of the library when the spelling is not the same.
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

    /// The song of an artist that one name is, when the library holds it under
    /// another spelling: the fuzzy door of the loved sync, one name and one
    /// artist, so a scan never folds a name twice.
    nonisolated static func loved(_ title: String, _ songs: [Track]) -> Track? {
        Held(songs).one(title)
    }

    /// The song one artist adds to the list: of the top titles of the chart,
    /// every one that a song of yours matches is a candidate, in the order the
    /// service ranked them. A single candidate is taken at once, so a library
    /// that holds one of the top five spends no draw on it; only more than one
    /// candidate is drawn, which is the only case where a draw can change the
    /// answer. No candidate, no song, and the artist is skipped.
    nonisolated static func choose(_ titles: [String], _ songs: [Track], using draw: (Int) -> Int) -> Match? {
        guard !titles.isEmpty, !songs.isEmpty else { return nil }

        let held = Held(songs)
        var candidates: [(title: String, track: Track)] = []

        for title in titles {
            guard let track = held.one(title) else { continue }
            guard !candidates.contains(where: { $0.track.id == track.id }) else { continue }

            candidates.append((title, track))
        }

        guard let first = candidates.first else { return nil }
        guard candidates.count > 1 else {
            return Match(track: first.track, title: first.title, candidates: 1)
        }

        let index = min(max(draw(candidates.count), 0), candidates.count - 1)

        return Match(track: candidates[index].track, title: candidates[index].title, candidates: candidates.count)
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
                        let match = choose(found, pair.songs, using: draw)
                        Log.player.debug("artist drawn", metadata: ["artist": "\(pair.name)", "titles": "\(found.count)", "candidates": "\(match?.candidates ?? 0)", "found": "\(match?.title ?? "")"])
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

    /// What a discovery that spends requests leaves on screen: the menus are
    /// dimmed while it runs, the list spins after `Discovery.spinAfter`, and a
    /// pick that added nothing says why. One value, so a late answer of the pick
    /// before cannot write over the pick that replaced it.
    nonisolated struct Work {
        private(set) var running = false
        private(set) var spinning = false
        private(set) var note: String?
        private(set) var generation = 0

        /// A new pick retires the one before it and opens its screen at once.
        mutating func begin() -> Int {
            generation += 1
            running = true
            spinning = false
            note = nil

            return generation
        }

        /// The list may spin now, but only for the pick that is still current.
        mutating func spin(_ mine: Int) -> Bool {
            guard mine == generation, running else { return false }

            spinning = true
            return true
        }

        /// The pick is over: songs went in the list, or the note says why they
        /// did not. False when a newer pick took over, which keeps its state.
        mutating func end(_ mine: Int, _ note: String?) -> Bool {
            guard mine == generation else { return false }

            running = false
            spinning = false
            self.note = note

            return true
        }

        mutating func dismiss() {
            note = nil
        }
    }

    /// Why a network pick added no song, in the words the list shows.
    enum Cause {
        case noChart, noBands, noSongs, noMatch
    }

    nonisolated static func reason(_ cause: Cause, _ artists: Int) -> String {
        switch cause {
        case .noChart: "Last.fm sent no artist. Check the account and the connection."
        case .noBands: "No band has a play count yet."
        case .noSongs: "None of those \(artists) artists is in your library."
        case .noMatch: "The top \(tracks) of those artists matched no song of yours."
        }
    }

    /// The pick that is on its way, and what the Up Next list shows for it.
    private(set) var work = Work()

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let lastFM: LastFM
    @ObservationIgnored private let player: Player
    @ObservationIgnored private var job: Task<Void, Never>?

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

        job?.cancel()
        job = nil
        let mine = work.begin()

        Log.player.info("discovery", metadata: ["pool": "\(pool.rawValue)", "songs": "\(count)"])

        switch pool {
        case .songs:
            start(library.random(count), mine, pool, count, nil)
        case .unplayed:
            start(library.unplayed(count), mine, pool, count, nil)
        case .played:
            start(library.topmost(count), mine, pool, count, nil)
        case .artists, .bands:
            NotificationCenter.default.post(name: .discovery, object: Discovery.opening)
            job = Task {
                let watch = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(Discovery.spinAfter))
                    self?.waited(mine, pool)
                }
                defer { watch.cancel() }

                let found = await self.walk(pool, count)
                self.start(found.tracks, mine, pool, count, found.note)
            }
        }
    }

    /// The list may show its spinner: the pick is still the current one.
    private func waited(_ mine: Int, _ pool: Pool) {
        guard work.spin(mine) else { return }

        Log.player.debug("discovery waiting", metadata: ["pool": "\(pool.rawValue)", "ms": "\(Discovery.spinAfter)"])
    }

    func dismissNote() {
        guard work.note != nil else { return }

        work.dismiss()
        Log.player.info("discovery note", metadata: ["reason": "dismissed"])
    }

    private func start(_ tracks: [Track], _ mine: Int, _ pool: Pool, _ count: Int, _ why: String?) {
        guard work.end(mine, tracks.isEmpty ? why : nil) else {
            return Log.player.debug("discovery superseded", metadata: ["pool": "\(pool.rawValue)", "songs": "\(count)"])
        }
        job = nil

        guard !tracks.isEmpty else {
            return Log.player.warning("discovery empty", metadata: ["pool": "\(pool.rawValue)", "asked": "\(count)", "note": "\(why ?? "")"])
        }

        player.random(tracks)
        NotificationCenter.default.post(name: .discovery, object: Discovery.done)
    }

    private func walk(_ pool: Pool, _ count: Int) async -> (tracks: [Track], note: String?) {
        let wanted: [(name: String, songs: [Track])]

        switch pool {
        case .artists:
            let chart = await lastFM.topArtists(Discovery.reach(count))
            guard !chart.isEmpty else {
                Log.player.debug("discovery stopped", metadata: ["pool": "\(pool.rawValue)", "reason": "no artists"])
                return ([], Discovery.reason(.noChart, 0))
            }

            let drawn = Discovery.draw(chart, count, using: { Int.random(in: 0..<$0) })
            Log.player.info("artists drawn", metadata: ["asked": "\(count)", "chart": "\(chart.count)", "drawn": "\(drawn.count)"])
            wanted = drawn.map { (name: $0, songs: library.songs(by: $0)) }
        default:
            wanted = library.topBands(count)
            guard !wanted.isEmpty else {
                Log.player.debug("discovery stopped", metadata: ["pool": "\(pool.rawValue)", "reason": "no bands"])
                return ([], Discovery.reason(.noBands, 0))
            }
        }

        guard !Task.isCancelled else {
            Log.player.debug("discovery stopped", metadata: ["pool": "\(pool.rawValue)", "reason": "cancelled"])
            return ([], nil)
        }

        let held = wanted.filter { !$0.songs.isEmpty }.count
        guard held > 0 else {
            Log.player.debug("discovery stopped", metadata: ["pool": "\(pool.rawValue)", "reason": "no songs", "artists": "\(wanted.count)"])
            return ([], Discovery.reason(.noSongs, wanted.count))
        }

        let fm = lastFM
        let found = await Discovery.collect(count, wanted) { await fm.topTracks($0, Discovery.tracks) }

        Log.player.info("discovery result", metadata: ["pool": "\(pool.rawValue)", "asked": "\(count)", "artists": "\(wanted.count)", "held": "\(held)", "found": "\(found.count)"])
        guard found.isEmpty else { return (found, nil) }

        return ([], Discovery.reason(.noMatch, held))
    }
}
