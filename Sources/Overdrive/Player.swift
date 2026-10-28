import AppKit
import AVFoundation
import MediaPlayer
import Synchronization

@Observable
final class Player {
    enum Repeat: Int {
        case off, all, one
    }

    enum Remote {
        case play, pause, toggle, next, previous
    }

    nonisolated struct Session: Codable {
        let queue: [String]
        let order: [String]
        let index: Int
        let position: Double
        let shuffle: Bool
        let repeatMode: Int
        let playing: Bool?
        let played: Double?
        let started: Double?
        let scrobbled: Bool?
        let page: String?
        let path: [String]?
        let query: String?
        let added: [Int]?
        let lyrics: Bool?
    }

    private nonisolated static let session = URL.applicationSupportDirectory.appending(path: "Overdrive/Session.plist")
    static let saved = Persist.read(Session.self, from: session)

    private(set) var queue: [Track] = [] { didSet { revision += 1 } }
    private(set) var revision = 0
    private(set) var index = 0
    private(set) var added: [Bool] = []
    var lyrics = Player.saved?.lyrics ?? true { didSet { if lyrics != oldValue { save() } } }
    private(set) var playing = false
    private(set) var position = 0.0
    private(set) var artwork: NSImage?

    var shuffle = false { didSet { if shuffle != oldValue { Log.player.info("shuffle", metadata: ["on": "\(shuffle)"]); reorder() } } }
    var repeatMode = Repeat.off {
        didSet {
            if repeatMode != oldValue { Log.player.info("repeat", metadata: ["mode": "\(repeatMode)"]); save() }
            requeue()
        }
    }
    var normalize = UserDefaults.standard.object(forKey: "normalize") as? Bool ?? true {
        didSet {
            Log.player.info("normalize", metadata: ["on": "\(normalize)"])
            UserDefaults.standard.set(normalize, forKey: "normalize")
            if let item, let track = current { Task { await adjust(item, track) } }
            requeue()
        }
    }
    var showsSpectrum = Spectrum.enabled(UserDefaults.standard.object(forKey: "spectrum")) {
        didSet {
            guard showsSpectrum != oldValue else { return }

            Log.player.info("spectrum", metadata: ["on": "\(showsSpectrum)"])
            UserDefaults.standard.set(showsSpectrum, forKey: "spectrum")
            spectrum.listening = false
            spectrum.clear()
            if let item, let track = current { Task { await adjust(item, track) } }
            requeue()
        }
    }
    var volume = UserDefaults.standard.object(forKey: "volume") as? Float ?? 1 {
        didSet {
            player.volume = volume
            volumeLog?.cancel()
            volumeLog = Task { [volume] in
                guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }

                Log.player.info("volume", metadata: ["value": "\(volume)"])
            }
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    var isMuted = UserDefaults.standard.object(forKey: "isMuted") as? Bool ?? false {
        didSet {
            if isMuted != oldValue { Log.player.info("muted", metadata: ["on": "\(isMuted)"]) }
            UserDefaults.standard.set(isMuted, forKey: "isMuted")
            if isMuted {
                player.volume = 0
            } else {
                player.volume = volume
            }
        }
    }

    func toggleMute() {
        Log.player.info("mute", metadata: ["on": "\(!isMuted)"])
        if isMuted {
            isMuted = false
            player.volume = volume
        } else {
            isMuted = true
            player.volume = 0
        }
    }

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var duration: Double { current?.duration ?? 0 }

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored let spectrum = Spectrum()
    @ObservationIgnored private let lastFM: LastFM
    @ObservationIgnored private let loudness: Loudness
    @ObservationIgnored private let plays: Plays
    @ObservationIgnored private var order: [Track] = []
    @ObservationIgnored private var played = 0.0
    @ObservationIgnored private var started = Date.now
    @ObservationIgnored private var scrobbled = false
    @ObservationIgnored private var counted = false
    @ObservationIgnored private var announced = false
    @ObservationIgnored private var restored = false
    @ObservationIgnored var view = (page: Player.saved?.page ?? "", path: Player.saved?.path ?? [], query: Player.saved?.query ?? "")
    @ObservationIgnored var intercept: ((Remote) -> Void)?
    @ObservationIgnored var resumed: (() -> Void)?
    @ObservationIgnored private var seeks = 0
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var status: NSKeyValueObservation?
    @ObservationIgnored private var item: AVPlayerItem?
    @ObservationIgnored private var upcoming: AVPlayerItem?
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var origin: [Int] = []
    @ObservationIgnored private var control: NSKeyValueObservation?
    @ObservationIgnored private var output: Output?
    @ObservationIgnored private var volumeLog: Task<Void, Never>?
    @ObservationIgnored private var announcedState = ""
    nonisolated static let delay = Duration.seconds(1)
    nonisolated static let threshold = 0.8

    /// A play counts when the song really played this much of itself: the time
    /// between ticks, so a seek spends nothing.
    nonisolated static func counts(_ played: Double, _ duration: Double) -> Bool {
        duration > 0 && played >= duration * Player.threshold
    }

    init(lastFM: LastFM, loudness: Loudness, plays: Plays) {
        self.lastFM = lastFM
        self.loudness = loudness
        self.plays = plays
        spectrum.listening = showsSpectrum
        player.volume = volume
        player.actionAtItemEnd = .advance

        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.write() }
        }

        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.finished(item) }
        }

        NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey].map { "\($0)" } ?? "unknown"
            MainActor.assumeIsolated {
                guard let self, let item, item === self.item else { return }

                Log.player.error("play to end failed", metadata: ["path": "\(self.current?.url.path ?? "")", "error": "\(error)"])
                self.failed(ObjectIdentifier(item))
            }
        }

        NotificationCenter.default.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                Log.player.warning("stalled", metadata: ["path": "\(self.current?.url.path ?? "")", "position": "\(self.position)"])
            }
        }

        NotificationCenter.default.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: nil, queue: .main) { notification in
            let event = (notification.object as? AVPlayerItem)?.errorLog()?.events.last
            Log.player.warning("item error log", metadata: ["domain": "\(event?.errorDomain ?? "")", "code": "\(event?.errorStatusCode ?? 0)", "comment": "\(event?.errorComment ?? "")"])
        }

        let last = Mutex("")
        control = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            let status = player.timeControlStatus == .playing ? "playing" : player.timeControlStatus == .paused ? "paused" : "waiting"
            let reason = player.reasonForWaitingToPlay?.rawValue ?? ""
            let changed = last.withLock { value in
                defer { value = status + reason }
                return value != status + reason
            }
            guard changed else { return }

            Log.player.info("time control", metadata: ["status": "\(status)", "reason": "\(reason)"])
        }
        output = Output()

        let center = MPRemoteCommandCenter.shared()
        Player.handle(center.playCommand) { [weak self] _ in self?.perform(.play) }
        Player.handle(center.pauseCommand) { [weak self] _ in self?.perform(.pause) }
        Player.handle(center.togglePlayPauseCommand) { [weak self] _ in self?.perform(.toggle) }
        Player.handle(center.nextTrackCommand) { [weak self] _ in self?.perform(.next) }
        Player.handle(center.previousTrackCommand) { [weak self] _ in self?.perform(.previous) }
        Player.handle(center.changePlaybackPositionCommand) { [weak self] in
            guard self?.intercept == nil else { return Log.player.debug("remote ignored", metadata: ["command": "seek", "reason": "video"]) }

            self?.seek($0)
        }
    }

    private nonisolated static func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable (Double) -> Void) {
        command.addTarget { event in
            let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in action(time) }
            return .success
        }
    }

    private nonisolated static func observe(_ item: AVPlayerItem, _ failed: @escaping @MainActor @Sendable (ObjectIdentifier) -> Void) -> NSKeyValueObservation {
        item.observe(\.status, options: [.initial]) { item, _ in
            guard item.status == .failed else { return }

            Log.player.error("item failed", metadata: ["error": "\(item.error.map { "\($0)" } ?? "none")", "events": Log.list(item.errorLog()?.events.map { "\($0.errorDomain) \($0.errorStatusCode) \($0.errorComment ?? "")" } ?? [])])

            let id = ObjectIdentifier(item)
            Task { @MainActor in failed(id) }
        }
    }

    private nonisolated static func artwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    func play(_ tracks: [Track], at start: Int = 0) {
        restored = true
        Log.player.info("play", metadata: ["songs": "\(tracks.count)", "start": "\(start)", "shuffle": "\(shuffle)", "path": "\(tracks.indices.contains(start) ? tracks[start].url.path : "")"])
        order = tracks
        queue = tracks
        added = Array(repeating: false, count: tracks.count)
        index = start

        origin = []
        if shuffle, tracks.indices.contains(start) {
            origin = Player.shuffled(tracks.count, keeping: start)
            queue = origin.map { tracks[$0] }
            index = 0
        }

        load()
    }

    func insert(_ tracks: [Track]) {
        Log.player.info("insert", metadata: Log.paths(tracks.map(\.url.path)))
        guard current != nil else { return play(tracks) }
        let track = queue[index]

        origin = []
        let tracks = tracks.filter { $0 != track }
        let inserted = Player.inserting(queue, added, at: index, tracks)
        queue = inserted.items
        added = inserted.marks
        index = inserted.index

        let set = Set(tracks)
        order.removeAll { set.contains($0) }
        if !shuffle {
            order = queue
        } else {
            order.append(contentsOf: tracks)
        }

        requeue()
        save()
    }

    nonisolated static func inserting<T: Hashable>(_ items: [T], _ marks: [Bool], at index: Int, _ new: [T]) -> (items: [T], marks: [Bool], index: Int) {
        let new = items.indices.contains(index) ? new.filter { $0 != items[index] } : new
        let set = Set(new)
        let kept = items.indices.filter { $0 == index || !set.contains(items[$0]) }
        var items = kept.map { items[$0] }
        var marks = kept.map { marks.indices.contains($0) && marks[$0] }
        let index = kept.firstIndex(of: index) ?? 0

        var position = index + 1
        while position < items.count, marks[position] { position += 1 }

        items.insert(contentsOf: new, at: position)
        marks.insert(contentsOf: repeatElement(true, count: new.count), at: position)
        return (items, marks, index)
    }

    func random(_ tracks: [Track]) {
        Log.player.info("random", metadata: ["songs": "\(tracks.count)", "up next": "\(queue.count)"])
        guard !tracks.isEmpty else { return Log.player.debug("random ignored", metadata: ["reason": "no songs"]) }

        play(tracks)
    }

    func jump(to position: Int) {
        Log.player.info("jump", metadata: ["position": "\(position)", "count": "\(queue.count)"])
        guard queue.indices.contains(position) else { return }

        index = position
        load()
    }

    func move(_ positions: Set<Int>, to target: Int) {
        origin = []
        Log.player.info("move", metadata: ["count": "\(positions.count)", "positions": Log.list(positions.sorted().prefix(20)), "target": "\(target)"])
        let moved = Player.moved(queue.count, positions, to: target)
        guard moved != Array(queue.indices) else { return }

        queue = moved.map { queue[$0] }
        added = moved.map { added.indices.contains($0) && added[$0] }
        index = moved.firstIndex(of: index) ?? 0
        if !shuffle { order = queue }

        requeue()
        save()
    }

    func clear() {
        origin = []
        Log.player.info("clear", metadata: ["count": "\(queue.count)"])
        player.removeAllItems()
        item = nil
        upcoming = nil
        status = nil
        queue = []
        order = []
        added = []
        index = 0
        playing = false
        position = 0
        played = 0
        scrobbled = false
        artwork = nil
        update()
        save()
    }

    nonisolated static func clears(_ count: Int, _ positions: Set<Int>, from index: Int) -> Bool {
        count > 0 && (index..<count).allSatisfy(positions.contains)
    }

    func remove(_ positions: Set<Int>) {
        Log.player.info("remove", metadata: ["removed": "\(positions.count)", "positions": Log.list(positions.sorted().prefix(20)), "index": "\(index)", "count": "\(queue.count)"])
        if Player.clears(queue.count, positions, from: index) { return clear() }

        origin = []
        let (kept, current) = Player.removing(queue.count, positions, keeping: index)
        guard kept.count < queue.count else { return }

        let gone = Set(positions).subtracting(kept).filter(queue.indices.contains).map { queue[$0] }
        queue = kept.map { queue[$0] }
        added = kept.map { added.indices.contains($0) && added[$0] }
        index = current

        if shuffle {
            var left = Dictionary(gone.map { ($0, 1) }, uniquingKeysWith: +)
            order.removeAll { track in
                guard let count = left[track], count > 0 else { return false }

                left[track] = count - 1
                return true
            }
        } else {
            order = queue
        }

        requeue()
        save()
    }

    nonisolated static func moved(_ count: Int, _ positions: Set<Int>, to target: Int) -> [Int] {
        var order = Array(0..<count)
        let moved = positions.filter { order.indices.contains($0) }
        guard !moved.isEmpty else { return order }

        let target = min(max(target, 0), count)
        let destination = target - order[..<target].count { moved.contains($0) }
        let dragged = order.filter { moved.contains($0) }

        order.removeAll { moved.contains($0) }
        order.insert(contentsOf: dragged, at: destination)
        return order
    }

    nonisolated static func removing(_ count: Int, _ positions: Set<Int>, keeping index: Int) -> (kept: [Int], index: Int) {
        let kept = (0..<count).filter { $0 == index || !positions.contains($0) }
        return (kept, kept.firstIndex(of: index) ?? 0)
    }

    nonisolated static func located(_ saved: [String], index: Int, _ lookup: (String) -> Track?) -> (tracks: [Track], index: Int?, positions: [Int]) {
        var tracks: [Track] = []
        var positions: [Int] = []
        var current: Int?
        tracks.reserveCapacity(saved.count)
        for (position, stored) in saved.enumerated() {
            guard let track = lookup(StoredPath.decode(stored)) else { continue }

            if position == index { current = tracks.count }
            tracks.append(track)
            positions.append(position)
        }
        return (tracks, current, positions)
    }

    nonisolated static func shuffled(_ count: Int, keeping index: Int) -> [Int] {
        var rest = Array(0..<count)
        rest.remove(at: index)
        rest.shuffle()
        return [index] + rest
    }

    nonisolated static func picked<T>(_ items: some Sequence<T>, _ count: Int) -> [T] {
        guard count > 0 else { return [] }

        var pool: [T] = []
        var seen = 0
        for item in items {
            if pool.count < count {
                pool.append(item)
            } else {
                let pick = Int.random(in: 0...seen)
                if pick < count { pool[pick] = item }
            }
            seen += 1
        }

        pool.shuffle()
        return pool
    }

    nonisolated static func unshuffled<T: Equatable>(_ position: Int, origin: [Int], queue: [T], order: [T]) -> Int {
        guard queue.indices.contains(position) else { return 0 }

        if origin.indices.contains(position), order.indices.contains(origin[position]), order[origin[position]] == queue[position] { return origin[position] }

        let item = queue[position]
        let occurrence = queue[..<position].count { $0 == item }
        let matches = order.indices.filter { order[$0] == item }
        return matches.dropFirst(occurrence).first ?? matches.first ?? 0
    }

    nonisolated static func refreshed(_ tracks: [Track], _ lookup: (String) -> Track?) -> [Track]? {
        var changed = false
        let fresh = tracks.map { track in
            guard let current = lookup(track.url.path), !current.same(track) else { return track }

            changed = true
            return current
        }
        return changed ? fresh : nil
    }

    func refresh(_ lookup: (String) -> Track?) {
        let before = current
        if let fresh = Player.refreshed(queue, lookup) { queue = fresh }
        if let fresh = Player.refreshed(order, lookup) { order = fresh }
        guard let track = current, let before, !track.same(before) else { return }

        Log.player.info("tags refreshed", metadata: ["path": "\(track.url.path)"])
        artwork = Artwork.image(track)
        update()
    }

    nonisolated static func waits(found: Int, saved: Int, complete: Bool) -> Bool {
        found == 0 || !complete && found < saved
    }

    func restore(complete: Bool, _ lookup: (String) -> Track?) {
        guard !restored else { return }
        guard item == nil, let session = Player.saved else {
            restored = true
            return Log.player.info("restore without session")
        }

        let located = Player.located(session.queue, index: session.index, lookup)
        let tracks = located.tracks
        Log.player.info("restore", metadata: ["found": "\(tracks.count)", "saved": "\(session.queue.count)", "index": "\(session.index)", "position": "\(session.position)", "complete": "\(complete)"])
        guard !Player.waits(found: tracks.count, saved: session.queue.count, complete: complete) else { return }

        restored = true
        let found = located.index

        shuffle = session.shuffle
        repeatMode = Repeat(rawValue: session.repeatMode) ?? .off
        queue = tracks
        let marks = Set(session.added ?? [])
        added = located.positions.map(marks.contains)
        order = session.order.compactMap { lookup(StoredPath.decode($0)) }
        let reset = order.count != queue.count
        if reset { order = queue }
        index = found ?? 0
        if tracks.count != session.queue.count || found == nil || reset {
            var missing: [String] = []
            for stored in session.queue where missing.count < 20 {
                let path = StoredPath.decode(stored)
                if lookup(path) == nil { missing.append(path) }
            }
            Log.player.warning("restore partial", metadata: ["missing": "\(session.queue.count - tracks.count)", "paths": Log.list(missing), "current": "\(found != nil)", "order reset": "\(reset)"])
        }

        load(play: false)

        guard found != nil, let item, let track = current else { return }

        played = session.played ?? 0
        scrobbled = session.scrobbled ?? false
        counted = Player.counts(played, track.duration)
        if let started = session.started { self.started = Date(timeIntervalSince1970: started) }

        Task {
            if session.position > 0 {
                seeks += 1
                let finished = await player.seek(to: CMTime(seconds: session.position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                seeks -= 1
                Log.player.log(level: finished ? .debug : .warning, "seek done", metadata: ["seconds": "\(session.position)", "finished": "\(finished)", "restore": "true"])
                guard item === self.item else { return }

                position = session.position
                update()
                save()
            }

            await adjust(item, track)
        }
    }

    private func perform(_ command: Remote) {
        Log.player.info("remote", metadata: ["command": "\(command)", "intercepted": "\(intercept != nil)"])
        if let intercept { return intercept(command) }

        switch command {
        case .play: resume()
        case .pause: pause()
        case .toggle: toggle()
        case .next: next()
        case .previous: previous()
        }
    }

    func toggle() {
        playing ? pause() : resume()
    }

    func resume() {
        guard let track = current else { return Log.player.debug("resume ignored", metadata: ["reason": "no song"]) }

        Log.player.info("resume", metadata: ["path": "\(track.url.path)"])
        guard item != nil else { return load() }

        player.play()
        playing = true
        resumed?()

        if !announced {
            announced = true
            if played == 0 { started = .now }
            lastFM.nowPlaying(track)
        }

        update()
    }

    func pause() {
        Log.player.info("pause", metadata: ["position": "\(position)"])
        player.pause()
        playing = false
        update()
        save()
    }

    func next() {
        Log.player.info("next", metadata: ["index": "\(index)"])
        guard let next = following(index, manual: true) else { return stop() }

        index = next
        load()
    }

    func previous() {
        Log.player.info("previous", metadata: ["index": "\(index)", "position": "\(position)"])
        guard position < 3, index > 0 else { return seek(0) }

        index -= 1
        load()
    }

    func seek(_ seconds: Double) {
        Log.player.info("seek", metadata: ["seconds": "\(seconds)"])
        seeks += 1
        position = seconds
        update()

        Task {
            let finished = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            seeks -= 1
            Log.player.log(level: finished ? .debug : .warning, "seek done", metadata: ["seconds": "\(seconds)", "finished": "\(finished)"])
        }
    }

    private func stop() {
        Log.player.info("stop")
        player.removeAllItems()
        item = nil
        upcoming = nil
        playing = false
        position = 0
        index = 0
        played = 0
        scrobbled = false
        counted = false
        announced = false
        started = .now
        update()
        save()
    }

    private func following(_ index: Int, manual: Bool = false) -> Int? {
        if repeatMode == .one, !manual { return index }
        if index + 1 < queue.count { return index + 1 }
        return repeatMode == .off || queue.isEmpty ? nil : 0
    }

    private func load(play: Bool = true) {
        Log.player.info("load", metadata: ["index": "\(index)", "count": "\(queue.count)", "play": "\(play)", "path": "\(queue[index].url.path)"])
        player.removeAllItems()
        let item = enqueue(index, start: play)
        self.item = item
        upcoming = following(index).map { enqueue($0) }

        playing = play
        if play { resumed?() }
        begin()
    }

    private func enqueue(_ index: Int, start: Bool = false) -> AVPlayerItem {
        let track = queue[index]
        let item = AVPlayerItem(url: track.url)
        player.insert(item, after: nil)

        Task {
            await adjust(item, track, wait: !start || track.duration < 300)
            if start, item === self.item, playing { player.play() }
        }

        return item
    }

    private func adjust(_ item: AVPlayerItem, _ track: Track, wait: Bool = true) async {
        guard normalize || showsSpectrum else {
            item.audioMix = nil
            return Log.player.debug("no mix", metadata: ["path": "\(track.url.path)", "reason": "nothing to apply"])
        }
        guard normalize else { return await mix(item, track, gain: nil) }

        let album = !shuffle

        guard wait || loudness.gain(track, album: album) != nil else {
            Log.player.debug("gain deferred", metadata: ["path": "\(track.url.path)", "album": "\(album)"])
            Task { await loudness.measure(track, album: album) }
            return await mix(item, track, gain: nil)
        }

        await loudness.measure(track, album: album)
        guard normalize else { return Log.player.debug("no gain", metadata: ["path": "\(track.url.path)", "reason": "disabled"]) }
        guard let gain = loudness.gain(track, album: album) else {
            Log.player.debug("no gain", metadata: ["path": "\(track.url.path)", "reason": "not measured"])
            return await mix(item, track, gain: nil)
        }

        Log.player.debug("gain", metadata: ["path": "\(track.url.path)", "gain": "\(gain)", "album": "\(album)"])
        await mix(item, track, gain: gain)
    }

    private func mix(_ item: AVPlayerItem, _ track: Track, gain: Float?) async {
        let audio: AVAssetTrack
        do {
            guard let first = try await item.asset.loadTracks(withMediaType: .audio).first else {
                return Log.player.warning("no mix", metadata: ["path": "\(track.url.path)", "reason": "no audio track"])
            }
            audio = first
        } catch {
            return Log.player.warning("no mix", metadata: ["path": "\(track.url.path)", "reason": "tracks failed", "error": "\(error)"])
        }

        let parameters = AVMutableAudioMixInputParameters(track: audio)
        if let gain { parameters.setVolume(gain, at: .zero) }
        parameters.audioTapProcessor = showsSpectrum ? spectrum.tap() : nil
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }

    private func finished(_ ended: AVPlayerItem?) {
        guard let ended, ended === item else { return Log.player.trace("stale item event", metadata: ["kind": "end"]) }

        Log.player.info("finished", metadata: ["path": "\(current?.url.path ?? "")"])
        if let track = current, !counted {
            counted = true
            plays.bump(track)
        }
        guard let next = following(index) else { return stop() }

        index = next
        guard let upcoming else { return load() }

        item = upcoming
        self.upcoming = following(index).map { enqueue($0) }

        begin()
    }

    private func failed(_ id: ObjectIdentifier) {
        guard let item, ObjectIdentifier(item) == id else { return Log.player.trace("stale item event", metadata: ["kind": "failure"]) }

        failures += 1
        Log.player.error("failed", metadata: ["path": "\(current?.url.path ?? "")", "failures": "\(failures)"])
        guard failures < queue.count, let next = following(index, manual: true) else {
            Log.player.error("give up", metadata: ["failures": "\(failures)", "count": "\(queue.count)"])
            failures = 0
            return stop()
        }

        index = next
        load(play: playing)
    }

    private func begin() {
        guard let track = current, let item else { return Log.player.debug("begin ignored", metadata: ["song": "\(current != nil)", "item": "\(self.item != nil)"]) }

        Log.player.info("begin", metadata: ["path": "\(track.url.path)", "playing": "\(playing)", "upcoming": "\(upcoming != nil)"])
        played = 0
        position = 0
        scrobbled = false
        counted = false
        started = .now
        artwork = Artwork.image(track)

        status = Player.observe(item) { [weak self] in self?.failed($0) }

        announced = playing
        if playing { lastFM.nowPlaying(track) }
        update()
        save()
    }

    func save() {
        saving?.cancel()
        saving = Task {
            guard (try? await Task.sleep(for: Player.delay)) != nil else { return }

            write()
        }
    }

    func write() {
        saving?.cancel()
        saving = nil
        guard restored || Player.saved == nil else {
            return Log.player.info("write skipped", metadata: ["reason": "saved session not restored yet"])
        }
        let session = Session(queue: queue.map { StoredPath.encode($0.url.path) }, order: order.map { StoredPath.encode($0.url.path) }, index: index, position: position,
                              shuffle: shuffle, repeatMode: repeatMode.rawValue, playing: playing, played: played,
                              started: started.timeIntervalSince1970, scrobbled: scrobbled,
                              page: view.page, path: view.path, query: view.query, added: added.indices.filter { added[$0] }, lyrics: lyrics)
        guard let data = Persist.encode(session, for: Player.session) else { return }

        Persist.write(data, to: Player.session)
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, seeks == 0 else { return }

        let delta = seconds - position
        position = seconds

        if playing, delta >= 2 || delta < 0 { Log.player.debug("position jump", metadata: ["from": "\(seconds - delta)", "to": "\(seconds)"]) }
        guard playing, delta > 0, delta < 2, let track = current else { return }

        failures = 0
        played += delta

        if !counted, Player.counts(played, track.duration) {
            counted = true
            plays.bump(track)
            Log.player.info("counted", metadata: ["path": "\(track.url.path)", "played": "\(played)", "duration": "\(track.duration)"])
        }

        if !scrobbled, track.duration >= 30, played >= min(track.duration / 2, 240) {
            scrobbled = true
            Log.player.info("scrobble", metadata: ["path": "\(track.url.path)", "played": "\(played)"])
            lastFM.scrobble(track, at: started)
        }
    }

    private func reorder() {
        guard let track = current else { return }

        Log.player.info("reorder", metadata: ["shuffle": "\(shuffle)", "count": "\(queue.count)"])
        if shuffle {
            origin = queue == order ? Player.shuffled(queue.count, keeping: index) : []
            if origin.isEmpty {
                var rest = queue
                rest.remove(at: index)
                queue = [track] + rest.shuffled()
            } else {
                queue = origin.map { order[$0] }
            }
            index = 0
        } else {
            index = Player.unshuffled(index, origin: origin, queue: queue, order: order)
            queue = order
            origin = []
        }
        added = Array(repeating: false, count: queue.count)

        requeue()
        save()
    }

    private func requeue() {
        guard item != nil else { return }

        Log.player.debug("requeue", metadata: ["index": "\(index)", "upcoming": "\(following(index).map(String.init) ?? "none")"])
        if let upcoming {
            player.remove(upcoming)
        }

        upcoming = following(index).map { enqueue($0) }
    }

    private func update() {
        let center = MPNowPlayingInfoCenter.default()
        let state = current.map { "\($0.url.path)|\(playing)" } ?? ""
        if state != announcedState {
            announcedState = state
            Log.player.trace("now playing", metadata: ["path": "\(current?.url.path ?? "")", "state": "\(current == nil ? "stopped" : playing ? "playing" : "paused")"])
        }

        guard let track = current else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1 : 0,
        ]

        if let artwork {
            info[MPMediaItemPropertyArtwork] = Player.artwork(artwork)
        }

        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
    }
}
