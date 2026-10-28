import AppKit

@Observable
final class Discovery {
    enum Pool: String {
        case songs, unplayed, played, artists, bands
    }

    nonisolated static let window = 4
    nonisolated static let tracks = 5
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

    /// The entries of a pool that hold a song the user has not denied. Every door
    /// of a picker reads this, so no path slips past the veto, and an artist whose
    /// every song is denied costs no request and never enters a list.
    static func allowed(_ pool: [(name: String, songs: [Track])], skipping skips: Skips) -> [(name: String, songs: [Track])] {
        guard !pool.isEmpty else { return pool }

        return pool.compactMap { entry in
            let held = skips.allowed(entry.songs)
            guard !held.isEmpty else { return nil }

            return (entry.name, held)
        }
    }

    /// `count` names of the pool, drawn at random and never repeated: the empty
    /// ones are out, and a name the service sent twice is one name.
    nonisolated static func draw(_ pool: [String], _ count: Int, using pick: (Int) -> Int) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        names.reserveCapacity(pool.count)

        for name in pool where !name.isEmpty {
            if seen.insert(name).inserted { names.append(name) }
        }

        return drawn(names, count, using: pick)
    }

    /// `count` items of the pool, drawn at random and never repeated. The draw
    /// is a partial shuffle, so every item of the pool can be one of them, and
    /// a pool smaller than the count gives all of it.
    nonisolated static func drawn<T>(_ pool: [T], _ count: Int, using pick: (Int) -> Int) -> [T] {
        guard count > 0, !pool.isEmpty else { return [] }

        var items = pool
        var drawn: [T] = []
        drawn.reserveCapacity(min(count, items.count))
        var remaining = items.count

        while remaining > 0, drawn.count < count {
            let index = min(max(pick(remaining), 0), remaining - 1)
            items.swapAt(index, remaining - 1)
            drawn.append(items[remaining - 1])
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

    /// Why a network pick added no song, in the words the list shows.
    enum Cause {
        case noChart, noBands, noSongs, noMatch, noArtists
    }

    nonisolated static func reason(_ cause: Cause, _ artists: Int) -> String {
        switch cause {
        case .noChart: "Last.fm sent no artist. Check the account and the connection."
        case .noBands: "No band has a play count yet."
        case .noSongs: "None of those \(artists) artists is in your library."
        case .noMatch: "The top \(tracks) of those artists matched no song of yours."
        case .noArtists: "No artist of your library is left to ask. Deny fewer songs, or turn the mode off and on."
        }
    }

    /// The task on its way and what its UI shows. One value for the pickers of
    /// this menu and for the `Infinity` mode, so there is one spinner, one dim,
    /// and one request budget between them.
    private(set) var work = Work()

    /// The songs one local picker draws: the library as the scan holds it, and
    /// without the songs the user denied. The unfiltered path is the common one,
    /// so an empty denylist costs nothing and the reservoir sample stays one pass.
    private func picked(_ pool: Pool, _ count: Int) -> [Track] {
        guard skips.count > 0 else {
            switch pool {
            case .songs: return library.random(count)
            case .unplayed: return library.unplayed(count)
            case .played: return library.topmost(count)
            default: return []
            }
        }

        let store = library.plays
        let songs = skips.allowed(library.tracks).filter { track in
            switch pool {
            case .songs: true
            case .unplayed: !store.played(Plays.key(track))
            default: store.played(Plays.key(track))
            }
        }

        return Player.picked(songs, count)
    }

    /// The list every network task fills, and the screen that shows it.
    func open(_ stage: String) {
        NotificationCenter.default.post(name: .discovery, object: stage)
    }

    /// A task the user asked for: it retires the one before it and opens Up Next
    /// at once, so the user sees the work instead of waiting in the dark.
    func begin() -> Int {
        let mine = work.begin()
        open(Work.opening)

        return mine
    }

    /// A background top-up. Refused while a task is in flight: the click of the
    /// user wins the spinner and the requests, and a fill never steals either.
    func claim() -> Int? {
        work.claim()
    }

    /// The list may show its spinner for this task, and only while it is current.
    func spin(_ mine: Int) {
        guard work.spin(mine) else { return }

        Log.player.debug("task waiting", metadata: ["ms": "\(Work.after)"])
    }

    /// The task is over. A newer one took over, and its state stays.
    @discardableResult
    func finish(_ mine: Int, _ note: String?) -> Bool {
        work.end(mine, note)
    }

    /// The mode left, and nothing of it is on screen any more.
    func reset() {
        work.reset()
    }

    func dismissNote() {
        guard work.note != nil else { return }

        work.dismiss()
        Log.player.info("discovery note", metadata: ["reason": "dismissed"])
    }

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let lastFM: LastFM
    @ObservationIgnored private let player: Player
    @ObservationIgnored private let skips: Skips
    @ObservationIgnored private var job: Task<Void, Never>?

    init(library: Library, lastFM: LastFM, player: Player, skips: Skips) {
        self.library = library
        self.lastFM = lastFM
        self.player = player
        self.skips = skips
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
        let mine = begin()

        Log.player.info("discovery", metadata: ["pool": "\(pool.rawValue)", "songs": "\(count)"])

        switch pool {
        case .songs:
            start(picked(.songs, count), mine, pool, count, nil)
        case .unplayed:
            start(picked(.unplayed, count), mine, pool, count, nil)
        case .played:
            start(picked(.played, count), mine, pool, count, nil)
        case .artists, .bands:
            job = Task {
                let watch = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(Work.after))
                    self?.spin(mine)
                }
                defer { watch.cancel() }

                let found = await self.walk(pool, count)
                self.start(found.tracks, mine, pool, count, found.note)
            }
        }
    }

    /// The one door every pool goes through, and the one place the veto of the
    /// user is applied: no picker of this menu, local or from the internet, can
    /// put a denied song in the list. A song the user denied stays in the
    /// library and plays whenever they choose it; it only never comes out of a
    /// discovery.
    private func start(_ picked: [Track], _ mine: Int, _ pool: Pool, _ count: Int, _ why: String?) {
        let tracks = skips.allowed(picked)

        if tracks.count < picked.count {
            Log.player.info("discovery denied", metadata: ["pool": "\(pool.rawValue)", "asked": "\(count)", "dropped": "\(picked.count - tracks.count)"])
        }

        guard finish(mine, tracks.isEmpty ? why : nil) else {
            return Log.player.debug("discovery superseded", metadata: ["pool": "\(pool.rawValue)", "songs": "\(count)"])
        }
        job = nil

        guard !tracks.isEmpty else {
            return Log.player.warning("discovery empty", metadata: ["pool": "\(pool.rawValue)", "asked": "\(count)", "note": "\(why ?? "")"])
        }

        player.random(tracks)
        open(Work.done)
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
            wanted = Discovery.allowed(drawn.map { (name: $0, songs: library.songs(by: $0)) }, skipping: skips)
            Log.player.info("artists drawn", metadata: ["asked": "\(count)", "chart": "\(chart.count)", "drawn": "\(drawn.count)", "held": "\(wanted.count)", "denied": "\(skips.count)"])
        default:
            wanted = Discovery.allowed(library.topBands(count), skipping: skips)
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
