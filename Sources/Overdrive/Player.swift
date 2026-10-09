import AppKit
import AVFoundation
import MediaPlayer

@Observable
final class Player {
    enum Repeat: Int {
        case off, all, one
    }

    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var playing = false
    private(set) var position = 0.0
    private(set) var artwork: NSImage?

    var shuffle = false { didSet { reorder() } }
    var repeatMode = Repeat.off { didSet { requeue() } }
    var volume = UserDefaults.standard.object(forKey: "volume") as? Float ?? 1 {
        didSet {
            player.volume = volume
            UserDefaults.standard.set(volume, forKey: "volume")
        }
    }

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var duration: Double { current?.duration ?? 0 }

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private let lastFM: LastFM
    @ObservationIgnored private var order: [Track] = []
    @ObservationIgnored private var played = 0.0
    @ObservationIgnored private var started = Date.now
    @ObservationIgnored private var scrobbled = false
    @ObservationIgnored private var seeks = 0
    @ObservationIgnored private var status: NSKeyValueObservation?
    @ObservationIgnored private var item: AVPlayerItem?
    @ObservationIgnored private var upcoming: AVPlayerItem?

    init(lastFM: LastFM) {
        self.lastFM = lastFM
        player.volume = volume
        player.actionAtItemEnd = .advance

        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }

        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated { self?.finished(item) }
        }

        let center = MPRemoteCommandCenter.shared()
        Player.handle(center.playCommand) { [weak self] _ in self?.resume() }
        Player.handle(center.pauseCommand) { [weak self] _ in self?.pause() }
        Player.handle(center.togglePlayPauseCommand) { [weak self] _ in self?.toggle() }
        Player.handle(center.nextTrackCommand) { [weak self] _ in self?.next() }
        Player.handle(center.previousTrackCommand) { [weak self] _ in self?.previous() }
        Player.handle(center.changePlaybackPositionCommand) { [weak self] in self?.seek($0) }
    }

    private nonisolated static func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable (Double) -> Void) {
        command.addTarget { event in
            let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in action(time) }
            return .success
        }
    }

    private nonisolated static func observe(_ item: AVPlayerItem, _ failed: @escaping @MainActor @Sendable () -> Void) -> NSKeyValueObservation {
        item.observe(\.status) { item, _ in
            guard item.status == .failed else { return }

            Task { @MainActor in failed() }
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

    func toggle() {
        playing ? pause() : resume()
    }

    func resume() {
        guard current != nil else { return }

        player.play()
        playing = true
        update()
    }

    func pause() {
        player.pause()
        playing = false
        update()
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

    private func load() {
        player.removeAllItems()
        item = enqueue(index)
        upcoming = following(index).map(enqueue)

        player.play()
        playing = true
        begin()
    }

    private func enqueue(_ index: Int) -> AVPlayerItem {
        let item = AVPlayerItem(url: queue[index].url)
        player.insert(item, after: nil)
        return item
    }

    private func finished(_ ended: AVPlayerItem?) {
        guard let ended, ended === item else { return }
        guard let next = following(index) else { return stop() }

        index = next
        guard let upcoming else { return load() }

        item = upcoming
        self.upcoming = following(index).map(enqueue)

        begin()
    }

    private func begin() {
        guard let track = current, let item else { return }

        played = 0
        position = 0
        scrobbled = false
        started = .now
        artwork = Artwork.image(track)

        status = Player.observe(item) { [weak self] in self?.next() }

        lastFM.nowPlaying(track)
        update()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, seeks == 0 else { return }

        let delta = seconds - position
        position = seconds

        guard playing, delta > 0, delta < 2, let track = current else { return }

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

        upcoming = following(index).map(enqueue)
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
