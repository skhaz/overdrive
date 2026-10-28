import Foundation

/// The endless list. It draws songs the library holds, each one a random pick
/// of the most played tracks of a random artist of the library as Last.fm ranks
/// them, and it keeps the buffer full while the user plays: 20 songs at the
/// start, and 20 more every time the song that plays passes its half. Nothing
/// it does interrupts the song that plays, and it stops when the user stops.
@Observable
final class Infinity {
    /// The songs one fill adds, and the buffer it keeps ahead of the song that
    /// plays. A fill runs when the buffer is below `keep`, so one fill tops it up.
    nonisolated static let batch = 20
    nonisolated static let keep = 20

    /// The most artists one fill asks, so a library whose top five nobody has
    /// cannot spend the whole chart on a single refill.
    nonisolated static let asks = 60

    /// Whether a fill that found no artist left to ask starts the library over.
    /// Only a mode that already played something can cycle: an empty library
    /// stays empty, and no cycle runs on a mode that never began.
    nonisolated static func cycles(pool: Int, served: Int) -> Bool {
        pool == 0 && served > 0
    }

    /// What one fill is for: the first list of the mode, or a top-up of the one
    /// that plays.
    enum Stage: String {
        case start, halfway
    }

    /// Why a tick of the clock did not, or did, start a fill.
    enum Pause {
        case off, filling, full, now
    }

    /// The one rule of the buffer: a mode that is off spends nothing, a fill
    /// that is on its way is never doubled, and a full list needs no request.
    nonisolated static func pause(on: Bool, flight: Bool, ahead: Int, kept: Int) -> Pause {
        guard on else { return .off }
        guard !flight else { return .filling }
        guard Player.needs(ahead: ahead, kept: kept) else { return .full }

        return .now
    }

    /// Whether the answer of one fill still belongs to the mode: a fill that was
    /// replaced by a newer one, or that outlived a toggle off and on, lands on
    /// nothing. The mode may be on again and still not want the old songs.
    nonisolated static func holds(_ run: Int, current: Int, on: Bool) -> Bool {
        on && run == current
    }

    private(set) var on = false

    @ObservationIgnored private let library: Library
    @ObservationIgnored private let lastFM: LastFM
    @ObservationIgnored private let player: Player
    @ObservationIgnored private let discovery: Discovery
    @ObservationIgnored private var served: Set<Track.ID> = []
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var flight: Task<Void, Never>?
    @ObservationIgnored private var run = 0

    init(library: Library, lastFM: LastFM, player: Player, discovery: Discovery) {
        self.library = library
        self.lastFM = lastFM
        self.player = player
        self.discovery = discovery
    }

    /// The menu item: the mode turns on with a fresh list of songs and off again
    /// with one click. It needs what every Last.fm picker needs.
    func toggle() {
        guard !on else { return off("toggled") }
        guard discovery.ready else {
            return Log.player.warning("infinity ignored", metadata: ["reason": "no last.fm"])
        }
        guard flight == nil else {
            return Log.player.debug("infinity ignored", metadata: ["reason": "already starting"])
        }

        on = true
        starting = true
        served = []
        run += 1
        Log.player.info("infinity", metadata: ["state": "on", "batch": "\(Infinity.batch)", "keep": "\(Infinity.keep)", "run": "\(run)"])
        flight = Task { await self.fill(at: .start, self.run) }
    }

    /// The mode leaves, and the songs it already put in the list stay: the user
    /// keeps what they heard, nothing new comes.
    func off(_ reason: String) {
        flight?.cancel()
        flight = nil
        starting = false
        run += 1

        guard on else { return }

        on = false
        served = []
        Log.player.info("infinity", metadata: ["state": "off", "reason": "\(reason)"])
    }

    /// A list replaced the player, or it stopped, for a reason that is not the
    /// start of this very mode.
    func stopped(_ reason: String) {
        guard !starting else {
            return Log.player.debug("infinity kept", metadata: ["reason": "its own start", "cause": "\(reason)"])
        }

        off(reason)
    }

    /// The song that plays passed its half. Top the buffer up when it is low,
    /// and spend nothing on a request when it is not.
    func passed() {
        switch Infinity.pause(on: on, flight: flight != nil, ahead: player.ahead, kept: Infinity.keep) {
        case .off:
            return
        case .filling:
            return Log.player.debug("infinity waiting", metadata: ["reason": "a fill is in flight"])
        case .full:
            return Log.player.debug("infinity full", metadata: ["ahead": "\(player.ahead)", "keep": "\(Infinity.keep)"])
        case .now:
            run += 1
            flight = Task { await self.fill(at: .halfway, self.run) }
        }
    }

    private func fill(at stage: Stage, _ run: Int) async {
        defer {
            // only the fill that is still the current one clears its own state,
            // so a replaced fill never drops the handle of the one after it
            if run == self.run {
                flight = nil
                starting = false
            }
        }

        let songs = await draw()
        guard Infinity.holds(run, current: self.run, on: on) else {
            return Log.player.debug("infinity dropped", metadata: ["at": "\(stage.rawValue)", "run": "\(run)", "current": "\(self.run)", "songs": "\(songs.count)"])
        }

        guard !songs.isEmpty else {
            Log.player.warning("infinity empty", metadata: ["at": "\(stage.rawValue)", "served": "\(served.count)"])
            return off("nothing to draw")
        }

        if stage == .start {
            player.random(songs)
        } else {
            player.append(songs)
        }

        served.formUnion(songs.map(\.id))
        Log.player.info("infinity filled", metadata: ["at": "\(stage.rawValue)", "songs": "\(songs.count)", "served": "\(served.count)", "ahead": "\(player.ahead)"])
    }

    /// The next batch of songs. An artist whose candidates the mode already
    /// played is out of the pool before a request goes, so every song here is
    /// new. When the library has nothing new left, the cycle starts again.
    private func draw() async -> [Track] {
        var pool = library.pool(excluding: served)

        if Infinity.cycles(pool: pool.count, served: served.count) {
            Log.player.info("infinity cycle", metadata: ["served": "\(served.count)", "reason": "library empty"])
            served = []
            pool = library.pool(excluding: served)
        }

        guard !pool.isEmpty else { return [] }

        let wanted = Discovery.drawn(pool, min(Infinity.asks, pool.count), using: { Int.random(in: 0..<$0) })
        let fm = lastFM
        let songs = await Discovery.collect(Infinity.batch, wanted) { await fm.topTracks($0, Discovery.tracks) }

        Log.player.info("infinity drew", metadata: ["artists": "\(wanted.count)", "songs": "\(songs.count)", "pool": "\(pool.count)"])
        return songs
    }
}
