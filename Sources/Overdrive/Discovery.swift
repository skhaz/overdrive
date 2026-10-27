import AppKit

@Observable
final class Discovery {
    enum Pool: String {
        case songs, unplayed, played, artists, bands
    }

    nonisolated static let window = 4
    nonisolated static let tracks = 10

    nonisolated static func owned(_ titles: [String], _ songs: [Track]) -> Track? {
        guard !titles.isEmpty, !songs.isEmpty else { return nil }

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

        for title in titles {
            let letters = Similarity.letters(title)
            guard !letters.isEmpty else { continue }
            if let held = exact[Similarity.normal(letters)] { return held }

            var best: (track: Track, ratio: Double)?

            for candidate in names {
                guard let ratio = Similarity.close(letters, candidate.letters) else { continue }
                guard ratio > (best?.ratio ?? 0) else { continue }

                best = (candidate.track, ratio)
            }

            if let best { return best.track }
        }

        return nil
    }

    nonisolated static func collect(_ count: Int, _ wanted: [(name: String, songs: [Track])],
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
            wanted = (await lastFM.topArtists(count)).map { (name: $0, songs: library.songs(by: $0)) }
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
