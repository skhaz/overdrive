import AppKit
import AVFoundation
import MediaPlayer

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
    }

    private nonisolated static let session = URL.applicationSupportDirectory.appending(path: "Overdrive/Session.plist")
    static let saved = (try? Data(contentsOf: session)).flatMap { try? PropertyListDecoder().decode(Session.self, from: $0) }

    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var playing = false
    private(set) var position = 0.0
    private(set) var artwork: NSImage?

    var shuffle = false { didSet { if shuffle != oldValue { reorder() } } }
    var repeatMode = Repeat.off { didSet { requeue() } }
    var normalize = UserDefaults.standard.object(forKey: "normalize") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(normalize, forKey: "normalize")
            if let item, let track = current { Task { await adjust(item, track) } }
            requeue()
        }
    }
    var volume = UserDefaults.standard.object(forKey: "volume") as? Float ?? 1 {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }
    var isMuted = UserDefaults.standard.object(forKey: "isMuted") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(isMuted, forKey: "isMuted")
            if isMuted {
                player.volume = 0
            } else {
                player.volume = volume
            }
        }
    }

    func toggleMute() {
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
    @ObservationIgnored private let lastFM: LastFM
    @ObservationIgnored private let loudness: Loudness
    @ObservationIgnored private var order: [Track] = []
    @ObservationIgnored private var played = 0.0
    @ObservationIgnored private var started = Date.now
    @ObservationIgnored private var scrobbled = false
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

    init(lastFM: LastFM, loudness: Loudness) {
        self.lastFM = lastFM
        self.loudness = loudness
        player.volume = volume
        player.actionAtItemEnd = .advance

        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }

        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.finished(item) }
        }

        let center = MPRemoteCommandCenter.shared()
        Player.handle(center.playCommand) { [weak self] _ in self?.perform(.play) }
        Player.handle(center.pauseCommand) { [weak self] _ in self?.perform(.pause) }
        Player.handle(center.togglePlayPauseCommand) { [weak self] _ in self?.perform(.toggle) }
        Player.handle(center.nextTrackCommand) { [weak self] _ in self?.perform(.next) }
        Player.handle(center.previousTrackCommand) { [weak self] _ in self?.perform(.previous) }
        Player.handle(center.changePlaybackPositionCommand) { [weak self] in if self?.intercept == nil { self?.seek($0) } }
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

            let id = ObjectIdentifier(item)
            Task { @MainActor in failed(id) }
        }
    }

    private nonisolated static func artwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    func play(_ tracks: [Track], at start: Int = 0) {
        order = tracks
        queue = tracks
        index = start

        if shuffle {
            let first = queue.remove(at: start)
            queue.shuffle()
            queue.insert(first, at: 0)
            index = 0
        }

        load()
    }

    func insert(_ tracks: [Track], next: Bool) {
        guard let track = current, item != nil else { return play(tracks) }

        let tracks = tracks.filter { $0 != track }
        let added = Set(tracks)

        index -= queue[..<index].count { added.contains($0) }
        queue.removeAll { added.contains($0) }
        order.removeAll { added.contains($0) }

        if next {
            queue.insert(contentsOf: tracks, at: index + 1)
            order.insert(contentsOf: tracks, at: order.firstIndex(of: track)! + 1)
        } else {
            queue.append(contentsOf: tracks)
            order.append(contentsOf: tracks)
        }

        requeue()
    }

    func restore(_ lookup: (String) -> Track?) {
        guard !restored else { return }
        restored = true

        guard item == nil, let session = Player.saved else { return }

        let tracks = session.queue.compactMap { lookup(StoredPath.decode($0)) }
        guard !tracks.isEmpty else { return }

        let path = session.queue.indices.contains(session.index) ? StoredPath.decode(session.queue[session.index]) : nil
        let found = tracks.firstIndex { $0.url.path == path }

        shuffle = session.shuffle
        repeatMode = Repeat(rawValue: session.repeatMode) ?? .off
        queue = tracks
        order = session.order.compactMap { lookup(StoredPath.decode($0)) }
        if order.count != queue.count { order = queue }
        index = found ?? 0

        load(play: false)

        guard found != nil, let item, let track = current else { return }

        played = session.played ?? 0
        scrobbled = session.scrobbled ?? false
        if let started = session.started { self.started = Date(timeIntervalSince1970: started) }

        Task {
            if session.position > 0 {
                seeks += 1
                await player.seek(to: CMTime(seconds: session.position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                seeks -= 1
                guard item === self.item else { return }

                position = session.position
                update()
                save()
            }

            await adjust(item, track)
        }
    }

    private func perform(_ command: Remote) {
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
        guard let track = current else { return }
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
        player.pause()
        playing = false
        update()
        save()
    }

    func next() {
        guard let next = following(index, manual: true) else { return stop() }

        index = next
        load()
    }

    func previous() {
        guard position < 3, index > 0 else { return seek(0) }

        index -= 1
        load()
    }

    func seek(_ seconds: Double) {
        seeks += 1
        position = seconds
        update()

        Task {
            await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            seeks -= 1
        }
    }

    private func stop() {
        player.removeAllItems()
        item = nil
        upcoming = nil
        playing = false
        position = 0
        index = 0
        update()
    }

    private func following(_ index: Int, manual: Bool = false) -> Int? {
        if repeatMode == .one, !manual { return index }
        if index + 1 < queue.count { return index + 1 }
        return repeatMode == .off || queue.isEmpty ? nil : 0
    }

    private func load(play: Bool = true) {
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
        guard normalize else {
            item.audioMix = nil
            return
        }

        let album = !shuffle

        guard wait || loudness.gain(track, album: album) != nil else {
            Task { await loudness.measure(track, album: album) }
            return
        }

        await loudness.measure(track, album: album)
        guard normalize, let gain = loudness.gain(track, album: album),
              let audio = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }

        let parameters = AVMutableAudioMixInputParameters(track: audio)
        parameters.setVolume(gain, at: .zero)
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }

    private func finished(_ ended: AVPlayerItem?) {
        guard let ended, ended === item else { return }
        guard let next = following(index) else { return stop() }

        index = next
        guard let upcoming else { return load() }

        item = upcoming
        self.upcoming = following(index).map { enqueue($0) }

        begin()
    }

    private func failed(_ id: ObjectIdentifier) {
        guard let item, ObjectIdentifier(item) == id else { return }

        failures += 1
        guard failures < queue.count, let next = following(index, manual: true) else {
            failures = 0
            return stop()
        }

        index = next
        load(play: playing)
    }

    private func begin() {
        guard let track = current, let item else { return }

        played = 0
        position = 0
        scrobbled = false
        started = .now
        artwork = Artwork.image(track)

        status = Player.observe(item) { [weak self] in self?.failed($0) }

        announced = playing
        if playing { lastFM.nowPlaying(track) }
        update()
        save()
    }

    func save() {
        let session = Session(queue: queue.map { StoredPath.encode($0.url.path) }, order: order.map { StoredPath.encode($0.url.path) }, index: index, position: position,
                              shuffle: shuffle, repeatMode: repeatMode.rawValue, playing: playing, played: played,
                              started: started.timeIntervalSince1970, scrobbled: scrobbled,
                              page: view.page, path: view.path, query: view.query)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(session) else { return }

        Persist.write(data, to: Player.session)
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, seeks == 0 else { return }

        let delta = seconds - position
        position = seconds

        guard playing, delta > 0, delta < 2, let track = current else { return }

        failures = 0
        played += delta

        if !scrobbled, track.duration >= 30, played >= min(track.duration / 2, 240) {
            scrobbled = true
            lastFM.scrobble(track, at: started)
        }
    }

    private func reorder() {
        guard let track = current else { return }

        if shuffle {
            var rest = queue
            rest.remove(at: index)
            queue = [track] + rest.shuffled()
            index = 0
        } else {
            queue = order
            index = order.firstIndex(of: track) ?? 0
        }

        requeue()
    }

    private func requeue() {
        guard item != nil else { return }

        if let upcoming {
            player.remove(upcoming)
        }

        upcoming = following(index).map { enqueue($0) }
    }

    private func update() {
        let center = MPNowPlayingInfoCenter.default()

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
