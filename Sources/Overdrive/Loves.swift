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
        var dropped: [String] = []
        var wishes: [String: Bool] = [:]
    }

    /// The spelling of a song on the account. It is not in the ledger: a read names
    /// the list again before any unlove needs a name.
    nonisolated struct Names: Equatable, Sendable {
        let artist: String
        let title: String
    }

    nonisolated static let file = URL.applicationSupportDirectory.appending(path: "Overdrive/Loves.plist")
    nonisolated static let gap = Duration.milliseconds(300)
    /// How often a wish the server did not take is offered again. The path monitor
    /// sends at once on a reconnect; this is the fallback for a network that comes
    /// back without an event, so a like is never held until the next read.
    nonisolated static let retry = Duration.seconds(60)
    /// The read that runs on its own, minute by minute: a love or an unlove made on
    /// the website is in the app in a minute, without a click.
    nonisolated static let period = Duration.seconds(60)
    /// How many times an unlove the server ignored is sent again with the name the
    /// server keeps before the app gives up on it.
    nonisolated static let tries = 3
    /// The songs of one fast read. Last.fm lists the loved tracks newest first, so a
    /// page that reaches a song the cache already holds carries every song above it,
    /// and the count the server reports says whether anything below changed.
    nonisolated static let window = 200
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

    /// The songs a whole read says the server dropped. A key in `held` is not one of
    /// them: it is a wish the server has not caught up with, so a read that is a
    /// little behind cannot undo it.
    nonisolated static func dropped(_ fresh: Set<String>, _ known: Set<String>, _ held: Set<String>) -> [String] {
        known.filter { !fresh.contains($0) && !held.contains($0) }.sorted()
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
        Task { await sync(full: true) }
    }

    var send: ((Entry) async -> LastFM.Outcome)?
    /// The account's answer for one page. A test stands in for the whole endpoint
    /// here, so it can count the requests the sync spends.
    var read: ((_ page: Int, _ limit: Int) async -> LastFM.Page?)?
    var found: ((String, String) -> Track?)?

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let lastFM: LastFM
    @ObservationIgnored private let likes: Likes
    @ObservationIgnored private let file: URL
    private(set) var remote: Set<String> = []
    private(set) var pending: [Entry] = []
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var pulling = false
    @ObservationIgnored private var arrived = false
    /// The writes the app made that the read has not confirmed, by key. The direction
    /// matters and it outlives a read: a love the server has not caught up with is not
    /// unliked locally, and an unlove the server has not caught up with is not liked
    /// again. A wish clears when the server agrees with it.
    @ObservationIgnored private var wishes: [String: Bool] = [:]
    @ObservationIgnored private var rejected: Set<String> = []
    /// The mirror keys that no liked song answers yet, so a scan costs the songs still
    /// waiting and not the whole mirror. Built once per launch from the ledger.
    @ObservationIgnored private var unresolved: Set<String> = []
    @ObservationIgnored private var primed = false
    @ObservationIgnored private var repair = true
    @ObservationIgnored private var flight: String?
    @ObservationIgnored private var names: [String: Names] = [:]
    @ObservationIgnored private var tries: [String: Int] = [:]

    init(library: Library, lastFM: LastFM, likes: Likes, file: URL = Loves.file, retry: Duration = Loves.retry, period: Duration = Loves.period) {
        self.library = library
        self.lastFM = lastFM
        self.likes = likes
        self.file = file

        let saved = Persist.read(Ledger.self, from: file) ?? Ledger()
        remote = Set(saved.remote)
        pending = saved.pending
        rejected = Set(saved.dropped)
        wishes = saved.wishes

        likes.changed = { [weak self] tracks, love in self?.local(tracks, love) }
        lastFM.connected = { [weak self] in Task { await self?.sync() } }
        Log.loves.info("load", metadata: ["file": "\(file.path)", "remote": "\(remote.count)", "pending": "\(pending.count)", "wishes": "\(wishes.count)"])

        Task { [weak self] in
            while true {
                guard let self else { return }
                if !self.pending.isEmpty, !self.syncing, !self.lastFM.session.isEmpty { await self.drain() }

                do { try await Task.sleep(for: retry) } catch { return }
            }
        }

        Task { [weak self] in
            while true {
                do { try await Task.sleep(for: period) } catch { return }
                guard let self else { return }

                Log.loves.info("tick", metadata: ["pending": "\(self.pending.count)", "remote": "\(self.remote.count)"])
                await self.lastFM.flush()
                await self.sync()
            }
        }
    }

    /// The first sync of a launch, after the library is there. Later scans do not ask
    /// again: the hourly tick and a reconnect own the rest.
    func arrive() async {
        guard !arrived else { return Log.loves.debug("arrive ignored", metadata: ["reason": "already synced"]) }
        arrived = true

        Log.loves.info("arrive", metadata: ["pending": "\(pending.count)", "remote": "\(remote.count)"])
        await sync()
    }

    /// A scan brought songs in: a loved song the library could not hold before may be
    /// reachable now. Local work only, no request.
    func apply() {
        guard !remote.isEmpty || !wishes.isEmpty else { return Log.loves.debug("apply skipped", metadata: ["reason": "no mirror"]) }

        settle([])
    }

    /// One sync at a time: push what the user did, then read the truth back. The read
    /// is one request unless the cache cannot explain what the server reports.
    func sync(full: Bool = false) async {
        guard !syncing else { return Log.loves.debug("sync skipped", metadata: ["reason": "running"]) }
        guard !lastFM.user.isEmpty else {
            return Log.loves.debug("sync skipped", metadata: ["reason": "no last.fm", "pending": "\(pending.count)"])
        }
        guard !library.albums.isEmpty else { return Log.loves.debug("sync skipped", metadata: ["reason": "no library"]) }

        syncing = true
        defer { syncing = false }

        await drain()

        let read = await pull(full: full)
        if read == .whole || (read != .none && repair) {
            repair = false
            push()
        }

        // The read can queue a wish of its own: an unlove the server ignored, and
        // the songs the account loves that the library cannot hold.
        await drain()
    }

    private func local(_ tracks: [Track], _ love: Bool) {
        guard !tracks.isEmpty else { return }

        var next = pending
        for track in tracks {
            // The account keeps its own spelling of a song, and an unlove must say
            // that one: a name it never held answers success and keeps the song.
            let name = love ? nil : Loves.account(track, names)
            next = Loves.queued(next, Entry(artist: name?.artist ?? track.artist, title: name?.title ?? track.title, love: love), flight)
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
                rejected.remove(key)
                wishes[key] = entry.love
            } else if entry.love {
                wishes.removeValue(forKey: key)
                rejected.insert(key)
            } else {
                // An unlove that answers "no such track" means it is not loved
                // upstream, which is where the user wanted it. It says nothing about
                // the name, so it must not keep a future love from going up; the
                // wish stays as an unlove until a read confirms the absence.
                wishes[key] = false
            }

            if let at = pending.firstIndex(of: entry) { pending.remove(at: at) }
            save()
            Log.loves.log(level: outcome == .sent ? .info : .warning, "sent", metadata: ["action": "\(outcome)", "artist": "\(entry.artist)", "title": "\(entry.title)", "left": "\(pending.count)"])

            guard !pending.isEmpty else { return }

            try? await Task.sleep(for: Loves.gap)
        }
    }

    /// What one read of the account did. `none` is an answer that did not come, so
    /// nothing in it can be trusted.
    private enum Read {
        case none, fast, whole
    }

    private func pull(full: Bool) async -> Read {
        guard !pulling else {
            Log.loves.debug("pull skipped", metadata: ["reason": "running"])
            return .none
        }

        pulling = true
        defer { pulling = false }

        guard !full, !remote.isEmpty else { return await every() }

        return await newest()
    }

    /// The fast read: the newest songs, one request while the cache is current. The
    /// count the server reports is the check: a cache that matches it holds every
    /// loved song, and anything else is read in full, because only the whole list says
    /// which song the server dropped.
    private func newest() async -> Read {
        guard let first = await fetch(1, Loves.window) else {
            Log.loves.warning("pull stopped", metadata: ["reason": "no answer", "remote": "\(remote.count)"])
            return .none
        }

        let keys = Set(first.tracks.map { Self.key($0.artist, $0.title) })
        let added = keys.subtracting(remote)
        let reached = added.count < keys.count
        let matches = first.total == remote.count + added.count

        guard reached, matches else {
            Log.loves.info("pull wide", metadata: ["reason": reached ? "count" : "new", "total": "\(first.total)", "remote": "\(remote.count)", "page": "\(keys.count)", "added": "\(added.count)"])
            return await every()
        }

        absorb(Loves.named(first.tracks), whole: false)
        return .fast
    }

    /// The whole list, page by page. The only read that can drop a key.
    private func every() async -> Read {
        var loved: [LastFM.Loved] = []
        var number = 1

        while true {
            guard let answer = await fetch(number, LastFM.wide) else {
                Log.loves.warning("pull stopped", metadata: ["reason": "no answer", "page": "\(number)", "remote": "\(remote.count)"])
                return .none
            }
            guard answer.pages <= LastFM.pages else {
                Log.loves.warning("pull stopped", metadata: ["reason": "too many pages", "pages": "\(answer.pages)", "cap": "\(LastFM.pages)", "remote": "\(remote.count)"])
                return .none
            }

            loved += answer.tracks
            guard number < answer.pages else { break }

            number += 1
        }

        absorb(Loves.named(loved), whole: true)
        return .whole
    }

    /// The account's spelling of every loved song, by key.
    nonisolated static func named(_ tracks: [LastFM.Loved]) -> [String: Names] {
        var named: [String: Names] = [:]

        for track in tracks {
            named[Self.key(track.artist, track.title)] = Names(artist: track.artist, title: track.title)
        }
        return named
    }

    private func fetch(_ page: Int, _ limit: Int) async -> LastFM.Page? {
        if let read { return await read(page, limit) }

        return await lastFM.loved(page: page, limit: limit)
    }

    /// What one read means for the cache. `whole` is the entire list: only it can drop
    /// a key the server let go. A page from the top only adds, because it never sees
    /// the old songs.
    private func absorb(_ found: [String: Names], whole: Bool) {
        let keys = Set(found.keys)
        let known = remote
        let was = known.count

        for (key, wish) in wishes where wish == keys.contains(key) { wishes.removeValue(forKey: key) }

        // An unlove the account still holds was not taken: the name the app sent is
        // not the name the account keeps. Send the one it keeps, a few times only.
        var stuck = 0
        for (key, wish) in wishes where !wish && keys.contains(key) {
            guard let name = found[key], (tries[key] ?? 0) < Loves.tries else { continue }

            tries[key, default: 0] += 1
            stuck += 1
            pending = Loves.queued(pending, Entry(artist: name.artist, title: name.title, love: false), flight)
        }

        let held = Set(pending.map(Self.key)).union(wishes.keys)
        let gone = whole ? Loves.dropped(keys, known, held) : []
        let fresh = keys.subtracting(known).subtracting(held)

        if whole {
            remote = keys
            names = found
            tries = tries.filter { keys.contains($0.key) }
        } else {
            remote.formUnion(keys)
            names.merge(found) { _, new in new }
        }
        if primed { unresolved.formUnion(fresh) }
        save()

        // The fuzzy walk runs once per key, on the read that brings it in, and only
        // for a key whose exact name the library does not hold. A scan never pays it.
        let matched = fresh.compactMap { key -> (key: String, track: Track)? in
            guard self.hold(key) == nil, let track = self.loose(key) else { return nil }

            return (key, track)
        }

        settle(gone, matched)
        if whole {
            Log.loves.info("pull", metadata: ["remote": "\(remote.count)", "known": "\(was)", "new": "\(fresh.count)", "gone": "\(gone.count)", "loose": "\(matched.count)", "wishes": "\(wishes.count)", "stuck": "\(stuck)"])
        } else {
            Log.loves.info("pull fast", metadata: ["remote": "\(remote.count)", "known": "\(was)", "new": "\(fresh.count)", "gone": "\(gone.count)", "loose": "\(matched.count)", "wishes": "\(wishes.count)", "stuck": "\(stuck)"])
        }
        prune()
    }

    /// The strict half of the mirror: a song the account loves that the library
    /// cannot hold is unloved on the account, so both lists always hold the same
    /// songs. It runs only on a settled library whose every folder is readable, so a
    /// drive that is not mounted never takes the loves of its folder with it.
    private func prune() {
        guard Loves.whole(settled: library.settled, folders: library.folders), !library.albums.isEmpty else {
            return Log.loves.debug("prune skipped", metadata: ["reason": "library not whole", "albums": "\(library.albums.count)"])
        }

        let held = Set(pending.map(Self.key)).union(wishes.keys)
        let extra = unresolved.intersection(remote).subtracting(held)
        guard !extra.isEmpty else { return }

        var entries: [Entry] = []
        var liked: [Track] = []
        for key in extra.sorted() {
            unresolved.remove(key)
            if let track = loose(key) {
                if !likes.contains(track) { liked.append(track) }
                continue
            }
            guard let name = names[key] ?? Loves.parts(key).map({ Names(artist: $0.artist, title: $0.title) }) else { continue }

            entries.append(Entry(artist: name.artist, title: name.title, love: false))
            wishes[key] = false
        }

        if !liked.isEmpty { likes.add(liked, notify: false) }
        guard !entries.isEmpty else { return }

        for entry in entries {
            pending = Loves.queued(pending, entry, flight)
        }
        save()
        Log.loves.info("prune", metadata: ["songs": "\(entries.count)", "liked": "\(liked.count)", "remote": "\(remote.count)", "unresolved": "\(unresolved.count)"])
    }

    /// A key split back into its two folded names, for a key the read never named.
    nonisolated static func parts(_ key: String) -> (artist: String, title: String)? {
        let parts = key.components(separatedBy: joined)
        guard parts.count == 2 else { return nil }

        return (parts[0], parts[1])
    }

    /// Whether the library can be trusted to hold every song it had: the last scan
    /// reached its end and every folder is there to read.
    nonisolated static func whole(settled: Bool, folders: [URL], readable: (URL) -> Bool = { FileManager.default.isReadableFile(atPath: $0.path) }) -> Bool {
        settled && !folders.isEmpty && folders.allSatisfy(readable)
    }

    /// The other half of the push: a song liked in the app that the server does not
    /// hold goes up. It runs after `settle`, so an unlove the read just applied has
    /// already left `Likes` and cannot come back as a wish. A wish of ours that is
    /// still outstanding never goes up twice: the server will confirm it, or the
    /// user will touch the song again. It runs on the first sync of a launch, so a
    /// like that predates the account is not left behind.
    private func push() {
        let held = Set(pending.map(Self.key)).union(wishes.keys)
        var raised: [Track] = []

        for path in likes.paths {
            guard let track = library.track(path) else { continue }

            let key = Self.key(track)
            guard !remote.contains(key), !held.contains(key), !rejected.contains(key) else { continue }
            guard Loves.account(track, names) == nil else { continue }

            raised.append(track)
        }

        guard !raised.isEmpty else { return Log.loves.debug("push skipped", metadata: ["reason": "nothing local", "likes": "\(likes.paths.count)"]) }

        local(raised, true)
        Log.loves.info("push", metadata: ["songs": "\(raised.count)", "likes": "\(likes.paths.count)", "remote": "\(remote.count)"])
    }

    /// The name the account knows a song by, when it holds the song under another
    /// spelling than the file: the exact folded title first, then the closest name
    /// of the same artist. A like already on the account under that name is not
    /// pushed again, and an unlove goes up with it.
    nonisolated static func account(_ track: Track, _ names: [String: Names]) -> Names? {
        let artist = Fuzzy.fold(track.artist)
        let title = Fuzzy.fold(track.title)
        let letters = Similarity.letters(track.title)
        var best: (name: Names, ratio: Double)?

        for name in names.values where Fuzzy.fold(name.artist) == artist {
            if Fuzzy.fold(name.title) == title { return name }
            guard let ratio = Similarity.close(letters, Similarity.letters(name.title)) else { continue }
            guard ratio > (best?.ratio ?? 0) else { continue }

            best = (name, ratio)
        }
        return best?.name
    }

    /// The name of a key matched by similarity, for the case where Last.fm spells a
    /// song a little differently than the file does.
    private func loose(_ key: String) -> Track? {
        let parts = key.components(separatedBy: Self.joined)
        guard parts.count == 2 else { return nil }

        return library.loved(folded: parts[0], folded: parts[1])
    }

    /// The keys the local list follows: what the server holds, with our outstanding
    /// wishes applied on top. A love we wrote and the server has not caught up with
    /// is in; an unlove the server has not caught up with is out. The mirror itself
    /// stays the server alone, so `gone` is only ever a server-side movement.
    var mirror: Set<String> {
        var pool = remote
        for (key, wish) in wishes {
            if wish {
                pool.insert(key)
            } else {
                pool.remove(key)
            }
        }
        return pool
    }

    /// The local half of the sync: every loved key the mirror holds becomes a liked
    /// song, and the keys the server dropped stop being liked. No request.
    /// It walks the keys that still have no liked song, so a scan costs what the
    /// library cannot hold and not the whole mirror.
    /// A loved song the library does not have is left on the server list, so a folder
    /// added later brings it down with no read of its own.
    /// `resolved` are the keys a read just matched by name, not by exact title; they
    /// arrive here because the fuzzy walk is work for the moment a key shows up, not
    /// work to repeat on every scan.
    private func settle(_ dropped: [String], _ resolved: [(key: String, track: Track)] = []) {
        if !primed {
            primed = true
            unresolved = mirror
        }

        let held = Set(pending.map(Self.key)).union(wishes.keys)
        var added: [Track] = []
        var gone: [Track] = []
        var seen: Set<Track.ID> = []
        var settled: Set<String> = []

        for key in unresolved where !held.contains(key) {
            guard let track = hold(key) else { continue }

            settled.insert(key)
            guard !likes.contains(track), seen.insert(track.id).inserted else { continue }

            added.append(track)
        }

        // A song matched by name carries the key that matched it: the server spells
        // it differently, so the key of the song itself is not on the mirror.
        for pair in resolved {
            settled.insert(pair.key)
            guard !likes.contains(pair.track), seen.insert(pair.track.id).inserted else { continue }

            added.append(pair.track)
        }

        // A drop resolves the same way a like did: a song matched by name leaves
        // under the server's spelling, not the file's.
        for key in dropped {
            guard let track = hold(key) ?? loose(key), likes.contains(track) else { continue }

            gone.append(track)
        }

        unresolved.subtract(settled)
        likes.add(added, notify: false)
        likes.remove(gone, notify: false)
        Log.loves.info("apply", metadata: ["remote": "\(remote.count)", "unresolved": "\(unresolved.count)", "liked": "\(added.count)", "unliked": "\(gone.count)", "held": "\(held.count)"])
    }

    /// The exact name of a key. Both parts are already folded, so this is two
    /// dictionary reads and no work per character.
    private func hold(_ key: String) -> Track? {
        let parts = key.components(separatedBy: Self.joined)
        guard parts.count == 2 else { return nil }

        return found.map { $0(parts[0], parts[1]) } ?? library.hold(folded: parts[0], folded: parts[1])
    }

    private func save() {
        guard let data = Persist.encode(Ledger(remote: remote.sorted(), pending: pending, dropped: rejected.sorted(), wishes: wishes), for: file) else { return }

        if !Persist.write(data, to: file) {
            Log.loves.error("save failed", metadata: ["file": "\(file.path)", "remote": "\(remote.count)", "pending": "\(pending.count)"])
        }
    }
}
