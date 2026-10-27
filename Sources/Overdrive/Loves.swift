import Foundation

@Observable
final class Loves {
    nonisolated struct Entry: Codable, Equatable, Sendable {
        let artist: String
        let title: String
        let love: Bool
    }

    nonisolated struct Ledger: Codable, Equatable {
        var remote: [String] = []
        var pending: [Entry] = []
    }

    nonisolated static let file = URL.applicationSupportDirectory.appending(path: "Overdrive/Loves.plist")
    nonisolated static let gap = Duration.milliseconds(300)
    private nonisolated static let joined = "\u{1F}"

    nonisolated static func key(_ artist: String, _ title: String) -> String {
        Fuzzy.fold(artist) + joined + Fuzzy.fold(title)
    }

    nonisolated static func key(_ track: Track) -> String {
        key(track.artist, track.title)
    }

    nonisolated static func key(_ entry: Entry) -> String {
        key(entry.artist, entry.title)
    }

    /// The queue after one more wish for the same song. What the user did last wins:
    /// the same wish twice is one wish, and the opposite wish cancels itself. A wish
    /// that is on its way to the server cannot be cancelled, only replaced, so the
    /// new one goes up after it and the server ends where the user wants.
    nonisolated static func queued(_ entries: [Entry], _ entry: Entry, _ flight: String?) -> [Entry] {
        let key = Self.key(entry)
        guard let held = entries.lastIndex(where: { Self.key($0) == key }) else { return entries + [entry] }
        guard entries[held].love != entry.love else { return entries }
        guard key != flight else {
            var kept = entries
            kept[held] = entry
            return kept
        }

        var kept = entries
        kept.remove(at: held)
        return kept
    }

    /// What one read of the remote list means for the app.
    /// `add` is what Last.fm has and the app does not know about; `gone` is what the
    /// app thought it had loved and Last.fm no longer lists. A key in `held` is in
    /// neither: it is a wish the user made that the server has not caught up with, so
    /// a read that is a little behind cannot undo it in either direction.
    nonisolated static func reconcile(_ loved: [LastFM.Loved], _ known: Set<String>, _ held: Set<String>) -> (fresh: Set<String>, add: [LastFM.Loved], gone: [String]) {
        let fresh = Set(loved.map { key($0.artist, $0.title) })
        let add = loved.filter { !known.contains(key($0.artist, $0.title)) && !held.contains(key($0.artist, $0.title)) }
        let gone = known.filter { !fresh.contains($0) && !held.contains($0) }.sorted()

        return (fresh, add, gone)
    }

    private(set) var syncing = false

    /// What Settings shows: the count Last.fm holds, plus what is still waiting.
    var summary: String {
        var text = "\(remote.count)"
        if !pending.isEmpty { text += " · \(pending.count) waiting" }

        return text
    }

    func syncNow() {
        Log.loves.info("sync asked", metadata: ["pending": "\(pending.count)", "remote": "\(remote.count)"])
        Task { await sync() }
    }

    var send: ((Entry) async -> LastFM.Outcome)?
    var snapshot: (() async -> [LastFM.Loved]?)?
    var found: ((LastFM.Loved) -> Track?)?

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let lastFM: LastFM
    @ObservationIgnored private let likes: Likes
    @ObservationIgnored private let file: URL
    private(set) var remote: Set<String> = []
    private(set) var pending: [Entry] = []
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var pulling = false
    @ObservationIgnored private var arrived = false
    @ObservationIgnored private var confirmed: Set<String> = []
    @ObservationIgnored private var flight: String?

    init(library: Library, lastFM: LastFM, likes: Likes, file: URL = Loves.file) {
        self.library = library
        self.lastFM = lastFM
        self.likes = likes
        self.file = file

        let saved = Persist.read(Ledger.self, from: file) ?? Ledger()
        remote = Set(saved.remote)
        pending = saved.pending

        likes.changed = { [weak self] tracks, love in self?.local(tracks, love) }
        lastFM.connected = { [weak self] in Task { await self?.sync() } }
        library.hourly = { [weak self] in Task { await self?.sync() } }
        Log.loves.info("load", metadata: ["file": "\(file.path)", "remote": "\(remote.count)", "pending": "\(pending.count)"])
    }

    /// The first sync of a launch, after the library is there. Later scans do not ask
    /// again: the hourly tick and a reconnect own the rest.
    func arrive() async {
        guard !arrived else { return Log.loves.debug("arrive ignored", metadata: ["reason": "already synced"]) }
        arrived = true

        Log.loves.info("arrive", metadata: ["pending": "\(pending.count)", "remote": "\(remote.count)"])
        await sync()
    }

    /// One sync at a time: push what the user did, then read the truth back.
    func sync() async {
        guard !syncing else { return Log.loves.debug("sync skipped", metadata: ["reason": "running"]) }
        guard !lastFM.user.isEmpty else {
            return Log.loves.debug("sync skipped", metadata: ["reason": "no last.fm", "pending": "\(pending.count)"])
        }
        guard !library.albums.isEmpty else { return Log.loves.debug("sync skipped", metadata: ["reason": "no library"]) }

        syncing = true
        defer { syncing = false }

        await drain()
        await pull()
    }

    private func local(_ tracks: [Track], _ love: Bool) {
        guard !tracks.isEmpty else { return }

        var next = pending
        for track in tracks {
            next = Loves.queued(next, Entry(artist: track.artist, title: track.title, love: love), flight)
        }

        guard next != pending else {
            return Log.loves.debug("queue kept", metadata: ["songs": "\(tracks.count)", "love": "\(love)", "pending": "\(pending.count)"])
        }

        pending = next
        save()
        Log.loves.info("queued", metadata: ["songs": "\(tracks.count)", "love": "\(love)", "pending": "\(pending.count)"])

        Task { await drain() }
    }

    private func drain() async {
        guard !draining else { return }

        draining = true
        defer { draining = false }

        while !pending.isEmpty {
            let entry = pending[0]
            let key = Self.key(entry)
            flight = key

            let outcome: LastFM.Outcome
            if let send {
                outcome = await send(entry)
            } else {
                outcome = await lastFM.love(entry.artist, entry.title, entry.love)
            }

            flight = nil

            guard outcome != .retry else {
                save()
                return Log.loves.info("queue held", metadata: ["pending": "\(pending.count)", "artist": "\(entry.artist)"])
            }

            if outcome == .sent {
                if entry.love {
                    remote.insert(key)
                } else {
                    remote.remove(key)
                }
                confirmed.insert(key)
            }

            if let at = pending.firstIndex(of: entry) { pending.remove(at: at) }
            save()
            Log.loves.log(level: outcome == .sent ? .info : .warning, "sent", metadata: ["action": "\(outcome)", "artist": "\(entry.artist)", "title": "\(entry.title)", "left": "\(pending.count)"])

            guard !pending.isEmpty else { return }

            try? await Task.sleep(for: Loves.gap)
        }
    }

    private func pull() async {
        guard !pulling else { return Log.loves.debug("pull skipped", metadata: ["reason": "running"]) }

        pulling = true
        defer { pulling = false }

        let loved: [LastFM.Loved]?
        if let snapshot {
            loved = await snapshot()
        } else {
            loved = await lastFM.loved()
        }

        guard let loved else {
            return Log.loves.warning("pull stopped", metadata: ["reason": "no answer", "remote": "\(remote.count)"])
        }

        let held = Set(pending.map(Self.key)).union(confirmed)
        let read = Loves.reconcile(loved, remote, held)
        let known = remote

        var added: [Track] = []
        var gone: [Track] = []

        for item in read.add {
            let track = found.map { $0(item) } ?? library.loved(item)
            if let track { added.append(track) }
        }

        for key in read.gone {
            let parts = key.components(separatedBy: Self.joined)
            guard parts.count == 2, let track = library.hold(parts[0], parts[1]) else { continue }

            gone.append(track)
        }

        likes.add(added, notify: false)
        likes.remove(gone, notify: false)
        remote = read.fresh
        confirmed = []
        save()

        Log.loves.info("pull", metadata: ["loved": "\(loved.count)", "remote": "\(read.fresh.count)", "known": "\(known.count)", "liked": "\(added.count)", "unliked": "\(gone.count)", "held": "\(held.count)"])
    }

    private func save() {
        guard let data = Persist.encode(Ledger(remote: remote.sorted(), pending: pending), for: file) else { return }

        if !Persist.write(data, to: file) {
            Log.loves.error("save failed", metadata: ["file": "\(file.path)", "remote": "\(remote.count)", "pending": "\(pending.count)"])
        }
    }
}
