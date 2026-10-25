import AppKit
import AudioToolbox
import AVFoundation
import CryptoKit
import Logging
import CoreServices
import UniformTypeIdentifiers

nonisolated struct Track: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    let artist: String
    let album: String
    let number: Int
    let disc: Int
    let albumArtist: String
    let year: Int
    let duration: Double
    let albumID: String

    var id: URL { url }

    func at(_ url: URL) -> Track {
        Track(url: url, title: title, artist: artist, album: album, number: number, disc: disc, albumArtist: albumArtist, year: year, duration: duration, albumID: albumID)
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

nonisolated final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []

    var items: [String] { lock.withLock { list } }

    func add(_ url: URL, _ error: any Error) {
        lock.withLock { list.append("\(url.path): \(error.localizedDescription)") }
    }
}

nonisolated struct Row: Identifiable, Sendable {
    let id: Int
    let track: Track
}

nonisolated struct Album: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let year: Int
    let tracks: [Track]

    var directory: URL { tracks[0].url.deletingLastPathComponent() }
}

nonisolated struct Index: Sendable {
    var bytes: [UInt8] = []
    var spans: [(start: Int32, title: Int32, artist: Int32, end: Int32)] = []
    var albums: [Int32] = [0]
}

nonisolated enum Fuzzy {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func score(_ pattern: UnsafeBufferPointer<UInt8>, _ text: UnsafeBufferPointer<UInt8>) -> Int {
        var best = 0

        for start in text.indices where text[start] == pattern[0] {
            var matched = 0
            var score = 0
            var last = start - 2

            for index in start..<text.count where text[index] == pattern[matched] {
                score += 1
                if index == last + 1 { score += 4 }
                if index == 0 || isalnum(Int32(text[index - 1])) == 0 { score += 6 }
                last = index
                matched += 1
                if matched == pattern.count { break }
            }

            guard matched == pattern.count else { break }

            best = max(best, score)
        }

        return pattern.count > 1 && best < pattern.count + 4 ? 0 : best
    }
}

@Observable
final class Library {
    private static let key = "folders"
    static let quiet = Duration.milliseconds(1500)
    static let period = Duration.seconds(600)

    private(set) var albums: [Album] = []
    private(set) var filtered: [Album] = []
    private(set) var tracks: [Track] = []
    private(set) var version = 0
    private(set) var scans = 0
    private(set) var members = 0
    @ObservationIgnored private var hits: Set<URL> = []
    @ObservationIgnored private var songMatches: Set<URL> = []
    var scanning = false
    var query = Player.saved?.query ?? "" { didSet { if query != oldValue { search() } } }

    var folders: [URL] {
        didSet {
            Log.library.info("folders", metadata: ["old": Log.list(oldValue.map(\.path)), "new": Log.list(folders.map(\.path))])
            if persistent { UserDefaults.standard.set(folders.map { StoredPath.encode($0.path) }, forKey: Library.key) }
            loudness.folders = folders
            watch()
            scan()
        }
    }

    nonisolated static func chronological(_ albums: [Album]) -> [Album] {
        albums.sorted {
            guard $0.year == $1.year else { return $1.year == 0 || $0.year != 0 && $0.year < $1.year }

            let artist = $0.artist.localizedStandardCompare($1.artist)
            guard artist == .orderedSame else { return artist == .orderedAscending }

            let title = $0.title.localizedStandardCompare($1.title)
            return title == .orderedSame ? $0.id < $1.id : title == .orderedAscending
        }
    }

    private static func savedFolders() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(filePath: StoredPath.decode($0)) }
    }

    var artists: [(name: String, albums: [Album])] {
        if grouped.version != version {
            grouped = (version, Dictionary(grouping: filtered, by: \.artist)
                .map { ($0.key, $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }

        return grouped.artists
    }

    @ObservationIgnored private var index = Index()
    @ObservationIgnored private var everything: [Track] = []
    @ObservationIgnored private var byYear: [Album] = []
    @ObservationIgnored private var lookup: [String: Track] = [:]
    @ObservationIgnored private var byID: [String: Album] = [:]
    @ObservationIgnored private var byArtist: [String: [Album]] = [:]
    @ObservationIgnored private var readers: [Cache] = []
    @ObservationIgnored private var readerFolders: [URL] = []
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var reported: Set<[Int]> = []
    @ObservationIgnored private var shownFolders: [URL]?
    @ObservationIgnored private var last = ContinuousClock.now
    @ObservationIgnored private var syncing: Task<Void, Never>?
    @ObservationIgnored private var stamps: (folders: [URL], files: [[String: Cache.Stamp]])?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var grouped: (version: Int, artists: [(name: String, albums: [Album])]) = (-1, [])
    @ObservationIgnored private var bytes: [UInt8] = []
    @ObservationIgnored private var tokens: [Range<Int>] = []
    @ObservationIgnored private var best: [Int] = []
    @ObservationIgnored private var albumHits: [(score: Int32, item: Int32)] = []
    @ObservationIgnored private var trackHits: [(score: Int32, item: Int32)] = []
    @ObservationIgnored private var ranked: [(score: Int32, item: Int32)] = []
    @ObservationIgnored private var counts: [Int] = []
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let loudness: Loudness
    @ObservationIgnored private let persistent: Bool
    @ObservationIgnored var loaded: ((_ complete: Bool) -> Void)?

    init(loudness: Loudness, folders: [URL]? = nil) {
        self.loudness = loudness
        persistent = folders == nil
        self.folders = folders ?? Library.savedFolders()
        loudness.folders = self.folders
        watch()
        scan()
        if persistent { sync() }

        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.request("volume", [:]) }
            })
        }
    }

    isolated deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }

        guard let stream else { return }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return Log.library.info("choose cancelled") }

        add(panel.urls)
    }

    nonisolated static func real(_ url: URL) -> String {
        url.path.withCString { path in realpath(path, nil).map { defer { free($0) }; return String(cString: $0) } } ?? url.path
    }

    nonisolated static func inside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    func add(_ urls: [URL]) {
        let current = folders.map(Library.real)
        var picked: [(url: URL, real: String)] = []
        for url in urls {
            let real = Library.real(url)
            guard !current.contains(where: { Library.inside(real, $0) }), !picked.contains(where: { Library.inside(real, $0.real) }) else { continue }

            picked.removeAll { Library.inside($0.real, real) }
            picked.append((url, real))
        }
        Log.library.info("add folders", metadata: ["folders": Log.list(urls.map(\.path)), "new": Log.list(picked.map(\.url.path))])
        guard !picked.isEmpty else { return }

        folders = folders.filter { folder in !picked.contains { Library.inside(Library.real(folder), $0.real) } } + picked.map(\.url)
    }

    private func sync() {
        syncing = Task { [weak self] in
            while (try? await Task.sleep(for: Library.period)) != nil {
                guard let self else { return }

                let info = ProcessInfo.processInfo
                let busy = scanning || info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                guard !busy, ContinuousClock.now - last >= Library.period else {
                    Log.library.debug("sync skipped", metadata: ["scanning": "\(scanning)", "low power": "\(info.isLowPowerModeEnabled)", "thermal": "\(info.thermalState.rawValue)"])
                    continue
                }

                guard let stamps, stamps.folders == folders else {
                    scan("periodic")
                    continue
                }

                let folders = folders
                let change = await Library.changed(folders, stamps.files)
                guard let change else {
                    Log.library.debug("sync clean", metadata: ["files": "\(stamps.files.reduce(0) { $0 + $1.count })"])
                    last = .now
                    continue
                }

                Log.library.info("sync found a change", metadata: ["change": "\(change)"])
                scan("periodic")
            }
        }
    }

    private func remember(_ folders: [URL]) {
        let generation = generation
        Task {
            let files = await Library.stamps(folders)
            guard generation == self.generation, folders == self.folders else { return }

            stamps = files.map { (folders, $0) }
        }
    }

    @concurrent
    nonisolated static func stamps(_ folders: [URL]) async -> [[String: Cache.Stamp]]? {
        var result: [[String: Cache.Stamp]] = []
        for folder in folders {
            guard let cache = Cache(folder) else { return nil }

            result.append(cache.stamps())
        }
        return result
    }

    @concurrent
    nonisolated static func changed(_ folders: [URL], _ stamps: [[String: Cache.Stamp]]) async -> String? {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .contentModificationDateKey, .fileSizeKey]

        for (number, folder) in folders.enumerated() {
            guard let cache = Cache(folder), stamps.indices.contains(number) else { return "no cache for \(folder.path)" }

            let known = stamps[number]
            var seen = 0
            var failed = false
            guard let enumerator = FileManager.default.enumerator(at: URL(filePath: cache.root), includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in
                failed = true
                return true
            }) else { return "unreadable \(folder.path)" }

            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: keys), let type = values.contentType, types.contains(where: type.conforms) else { continue }

                let path = cache.relative(url)
                guard let stamp = known[path] else { return "new \(path)" }
                guard stamp.modified == values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0, stamp.size == values.fileSize ?? 0 else { return "modified \(path)" }

                seen += 1
            }

            if failed { return "walk error in \(folder.path)" }
            if seen != known.count { return "gone in \(folder.path)" }
        }

        return nil
    }

    func request(_ reason: String, _ metadata: Logging.Logger.Metadata) {
        var metadata = metadata
        metadata["reason"] = "\(reason)"
        Log.library.info("scan requested", metadata: metadata)
        pending?.cancel()
        pending = Task {
            guard (try? await Task.sleep(for: Library.quiet)) != nil else { return }

            scan(reason)
        }
    }

    func scan(_ reason: String = "direct") {
        pending?.cancel()
        pending = nil
        generation += 1
        let generation = generation
        let folders = folders
        let covers = Artwork.covers
        let first = folders != shownFolders
        last = .now
        var reopen = false
        for folder in folders {
            if !FileManager.default.fileExists(atPath: folder.appending(path: Cache.name).path) { reopen = true }
        }
        if reopen {
            Log.library.warning("cache missing", metadata: ["folders": Log.list(folders.map(\.path))])
            readers = []
            readerFolders = []
        }

        scanning = true
        Log.library.info("scan", metadata: ["generation": "\(generation)", "reason": "\(reason)", "first": "\(first)", "folders": Log.list(folders.map(\.path))])

        let previous = running
        running = Task {
            await previous?.value
            guard generation == self.generation else { return }

            var shown = false
            let result = await Library.load(folders, covers, cached: first) { snapshot in
                await MainActor.run {
                    guard generation == self.generation else { return false }

                    self.show(snapshot, folders)
                    if !shown {
                        shown = true
                        self.loaded?(false)
                    }
                    return true
                }
            }
            guard generation == self.generation else {
                shownFolders = nil
                return Log.library.info("scan replaced", metadata: ["generation": "\(generation)"])
            }

            scanning = false
            remember(folders)
            guard first || shown else {
                Log.library.info("scan unchanged", metadata: ["generation": "\(generation)", "reason": "\(reason)"])
                loaded?(true)
                return
            }

            Log.library.info("scan done", metadata: ["generation": "\(generation)", "albums": "\(result.albums.count)"])
            show(result, folders)
            loudness.update(result.albums)
            loaded?(true)
        }
    }

    func rebuild() {
        pending?.cancel()
        pending = nil
        generation += 1
        let generation = generation
        let folders = folders

        scanning = true
        Log.library.info("rebuild", metadata: ["generation": "\(generation)", "folders": Log.list(folders.map(\.path))])

        let previous = running
        running = Task {
            await previous?.value

            guard let result = await Library.rebuild(folders) else {
                Log.library.error("rebuild failed", metadata: ["generation": "\(generation)"])
                shownFolders = nil
                if generation == self.generation { scanning = false }
                return
            }
            guard generation == self.generation else {
                shownFolders = nil
                return Log.library.info("rebuild replaced", metadata: ["generation": "\(generation)"])
            }

            Log.library.info("rebuild done", metadata: ["generation": "\(generation)", "albums": "\(result.albums.count)"])
            remember(folders)
            show(result, folders)
            scanning = false
            loaded?(true)
            loudness.update(result.albums)
        }
    }

    private func show(_ snapshot: Snapshot, _ folders: [URL]) {
        Artwork.covers = snapshot.covers
        index = snapshot.index
        let tracks = snapshot.albums.flatMap(\.tracks)
        if !tracks.elementsEqual(everything, by: { $0.url == $1.url }) { members += 1 }
        everything = tracks
        lookup = Dictionary(everything.map { ($0.url.path, $0) }) { first, _ in first }
        if readerFolders != folders {
            readers = folders.compactMap { folder in
                Cache(folder) ?? { Log.library.warning("reader unavailable", metadata: ["folder": "\(folder.path)"]); return nil }()
            }
            readerFolders = folders
        }
        albums = snapshot.albums
        byYear = Library.chronological(snapshot.albums)
        byID = Dictionary(snapshot.albums.map { ($0.id, $0) }) { first, _ in first }
        byArtist = Dictionary(grouping: byYear, by: \.artist)
        shownFolders = folders
        scans += 1
        search()
    }

    func album(_ id: String) -> Album? {
        byID[id]
    }

    func albums(by artist: String) -> [Album] {
        byArtist[artist] ?? []
    }

    func track(_ path: String) -> Track? {
        lookup[path]
    }

    func matched(_ track: Track) -> Bool {
        !query.isEmpty && songMatches.contains(track.id)
    }

    func rows(_ paths: [String]) -> [Row] {
        _ = scans
        let hits = query.isEmpty ? nil : hits

        var missing: [String] = []
        let rows = paths.indices.compactMap { position -> Row? in
            guard let track = lookup[paths[position]] else {
                if missing.count < 20 { missing.append(paths[position]) }
                return nil
            }
            guard hits?.contains(track.id) ?? true else { return nil }

            return Row(id: position, track: track)
        }

        if !missing.isEmpty, !albums.isEmpty, reported.insert([scans, paths.count, missing.count]).inserted {
            Log.library.warning("rows missing", metadata: ["requested": "\(paths.count)", "paths": Log.list(missing)])
        }
        return rows
    }

    private func search() {
        defer {
            hits = query.isEmpty ? [] : Set(tracks.map(\.id))
            version += 1
        }

        filtered = query.isEmpty ? [] : byYear.filter { $0.artist == query }
        songMatches.removeAll(keepingCapacity: true)

        guard filtered.isEmpty else {
            tracks = filtered.flatMap(\.tracks)
            return
        }

        bytes.removeAll(keepingCapacity: true)
        tokens.removeAll(keepingCapacity: true)

        for word in query.split(whereSeparator: \.isWhitespace) {
            let start = bytes.count
            bytes.append(contentsOf: Fuzzy.fold(String(word)).utf8)
            tokens.append(start..<bytes.count)
        }

        guard !tokens.isEmpty else {
            filtered = byYear
            tracks = everything
            return
        }

        albumHits.removeAll(keepingCapacity: true)
        trackHits.removeAll(keepingCapacity: true)
        best.removeAll(keepingCapacity: true)
        best.append(contentsOf: repeatElement(0, count: tokens.count))

        bytes.withUnsafeBufferPointer { pattern in
            index.bytes.withUnsafeBufferPointer { keys in
                index.spans.withUnsafeBufferPointer { spans in
                    for album in 0..<(index.albums.count - 1) {
                        for token in best.indices { best[token] = 0 }

                        for track in Int(index.albums[album])..<Int(index.albums[album + 1]) {
                            let span = spans[track]
                            let title = UnsafeBufferPointer(rebasing: keys[Int(span.start)..<Int(span.title)])
                            let artist = UnsafeBufferPointer(rebasing: keys[Int(span.title)..<Int(span.artist)])
                            let record = UnsafeBufferPointer(rebasing: keys[Int(span.artist)..<Int(span.end)])
                            var total = 0
                            var all = true
                            var song = true
                            var titled = false

                            for token in tokens.indices {
                                let word = UnsafeBufferPointer(rebasing: pattern[tokens[token]])
                                let inTitle = Fuzzy.score(word, title)
                                let inArtist = Fuzzy.score(word, artist)
                                let score = max(inTitle, inArtist, Fuzzy.score(word, record))
                                best[token] = max(best[token], score)
                                total += score
                                all = all && score > 0
                                song = song && (inTitle > 0 || inArtist > 0)
                                titled = titled || inTitle > 0
                            }

                            if all {
                                trackHits.append((Int32(total), Int32(track)))
                                if song, titled { songMatches.insert(everything[track].id) }
                            }
                        }

                        if !best.contains(0) { albumHits.append((Int32(best.reduce(0, +)), Int32(album))) }
                    }
                }
            }
        }

        let limit = 11 * bytes.count + 1

        rank(albumHits, limit)
        filtered = []
        filtered.reserveCapacity(ranked.count)
        for hit in ranked { filtered.append(albums[Int(hit.item)]) }
        filtered = Library.chronological(filtered)

        rank(trackHits, limit)
        tracks = []
        tracks.reserveCapacity(ranked.count)
        for hit in ranked { tracks.append(everything[Int(hit.item)]) }

        let words = tokens.map { String(decoding: bytes[$0], as: UTF8.self) }
        let exact = readers.flatMap { $0.search(words) }
        guard !exact.isEmpty else { return }

        let order = Dictionary(exact.enumerated().map { ($1, $0) }) { first, _ in first }
        var first: [(rank: Int, track: Track)] = []
        var rest: [Track] = []
        rest.reserveCapacity(tracks.count)
        for track in tracks {
            if let rank = order[track.url.path] { first.append((rank, track)) } else { rest.append(track) }
        }
        first.sort { $0.rank < $1.rank }
        tracks = first.map(\.track) + rest
    }

    private func rank(_ hits: [(score: Int32, item: Int32)], _ limit: Int) {
        counts.removeAll(keepingCapacity: true)
        counts.append(contentsOf: repeatElement(0, count: limit + 1))

        for hit in hits { counts[limit - Int(hit.score)] += 1 }

        var position = 0

        for slot in counts.indices {
            let count = counts[slot]
            counts[slot] = position
            position += count
        }

        ranked.removeAll(keepingCapacity: true)
        ranked.append(contentsOf: hits)

        for hit in hits {
            let slot = limit - Int(hit.score)
            ranked[counts[slot]] = hit
            counts[slot] += 1
        }
    }

    private func watch() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }

        guard !folders.isEmpty else { return }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let paths = unsafeBitCast(paths, to: NSArray.self)
            let events = (0..<count).map { (path: paths[$0] as! String, flags: flags[$0]) }
            Log.library.trace("file events", metadata: ["count": "\(events.count)", "events": .dictionary(Dictionary(events.prefix(50).map { ($0.path, .string(String($0.flags, radix: 16))) }) { $1 })])
            guard Library.relevant(events) else { return }

            MainActor.assumeIsolated {
                Unmanaged<Library>.fromOpaque(info!).takeUnretainedValue().request("files", Log.paths(events.map(\.path)))
            }
        }

        guard let stream = FSEventStreamCreate(nil, callback, &context, folders.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)) else {
            return Log.library.error("watch failed", metadata: ["folders": Log.list(folders.map(\.path))])
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        let started = FSEventStreamStart(stream)
        Log.library.log(level: started ? .info : .error, "watch", metadata: ["folders": Log.list(folders.map(\.path)), "started": "\(started)"])
    }

    nonisolated static let lost = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)

    nonisolated static func relevant(_ events: [(path: String, flags: FSEventStreamEventFlags)]) -> Bool {
        events.contains { path, flags in
            if flags & lost != 0 {
                Log.library.warning("events lost", metadata: ["path": "\(path)", "flags": "\(String(flags, radix: 16))"])
                return true
            }

            if Cache.ignored(path) {
                let main = (path as NSString).lastPathComponent == Cache.name
                let gone = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
                return main && gone || !FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent + "/" + Cache.name)
            }

            if path.contains("/.") { return false }
            if playable.contains((path as NSString).pathExtension.lowercased()) { return true }

            let folder = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            let gone = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0
            return folder && gone
        }
    }

    typealias Snapshot = (albums: [Album], index: Index, covers: [String: Data])

    private nonisolated static let batch = 256
    nonisolated static let types = AVURLAsset.audiovisualContentTypes.filter { $0.conforms(to: .audio) }
    nonisolated static let playable = Set(types.flatMap { $0.tags[.filenameExtension] ?? [] }.map { $0.lowercased() })

    @concurrent
    nonisolated static func load(_ folders: [URL], _ previous: [String: Data], cached emit: Bool = true, progress: @Sendable (Snapshot) async -> Bool = { _ in true }) async -> Snapshot {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .contentModificationDateKey, .fileSizeKey]
        let caches = folders.map { Cache($0) }
        var stored = previous
        var saved: [Set<String>] = []
        var knowns: [[String: Cache.Entry]] = []

        for cache in caches {
            let covers = cache?.covers() ?? [:]
            saved.append(Set(covers.keys))
            stored.merge(covers) { current, _ in current }
            knowns.append(cache?.entries() ?? [:])
        }

        let cached = knowns.flatMap { $0.values.map(\.track) }
        Log.library.info("load", metadata: ["folders": Log.list(folders.map(\.path)), "cached": "\(cached.count)", "caches": Log.list(caches.map { $0 != nil })])
        if emit, !cached.isEmpty {
            let (albums, index) = assemble(cached)
            guard await progress((albums, index, stored)) else { return (albums, index, stored) }
        }

        var slots: [Track?] = []
        var pending: [(slot: Int, url: URL, mp4: Bool, folder: Int, path: String, modified: Double, size: Int, old: Cache.Entry?)] = []
        var removed: [[String]] = []

        for (number, folder) in folders.enumerated() {
            let cache = caches[number]
            var known = knowns[number]

            let root = cache.map { URL(filePath: $0.root) } ?? folder
            let failures = Failures()
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) { url, error in
                failures.add(url, error)
                return true
            }
            if enumerator == nil { failures.add(root, CocoaError(.fileReadUnknown)) }

            if let enumerator {
                while let url = enumerator.nextObject() as? URL {
                    guard let values = try? url.resourceValues(forKeys: keys), let type = values.contentType, types.contains(where: type.conforms) else { continue }

                    let path = cache?.relative(url) ?? url.path
                    let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
                    let size = values.fileSize ?? 0
                    let entry = known.removeValue(forKey: path)

                    if let entry, entry.modified == modified, entry.size == size {
                        slots.append(entry.track.at(url))
                    } else {
                        pending.append((slots.count, url, type.conforms(to: .mpeg4Audio), number, path, modified, size, entry))
                        slots.append(entry?.track.at(url))
                    }
                }
            }

            if failures.items.isEmpty {
                removed.append(Array(known.keys))
            } else {
                Log.library.error("folder unreadable", metadata: ["folder": "\(root.path)", "kept": "\(known.count)", "errors": Log.list(failures.items.prefix(20))])
                for entry in known.values { slots.append(entry.track) }
                removed.append([])
            }
        }

        Log.library.info("walk", metadata: ["files": "\(slots.count)", "read": "\(pending.count)", "removed": "\(removed.reduce(0) { $0 + $1.count })", "paths": Log.list(removed.lazy.flatMap(\.self).prefix(20))])
        if !pending.isEmpty || removed.contains(where: { !$0.isEmpty }) {
            for (number, cache) in caches.enumerated() where !removed[number].isEmpty {
                guard cache?.save([], removed: removed[number], covers: [:]) == false else { continue }

                Log.library.error("removal not saved", metadata: ["folder": "\(folders[number].path)", "kept": "\(removed[number].count)"])
                for path in removed[number] {
                    if let entry = knowns[number][path] { slots.append(entry.track) }
                }
            }

            let (albums, index) = assemble(slots.compactMap(\.self))
            guard await progress((albums, index, stored)) else { return (albums, index, stored) }
        }

        let work = pending

        for start in stride(from: 0, to: work.count, by: batch) {
            let part = work[start..<min(start + batch, work.count)]

            nonisolated(unsafe) let read = UnsafeMutableBufferPointer<(track: Track?, hash: Data?)>.allocate(capacity: part.count)
            defer { read.deinitialize().deallocate() }

            DispatchQueue.concurrentPerform(iterations: part.count) { offset in
                let item = part[part.startIndex + offset]

                guard let old = item.old, old.size == item.size else {
                    read.initializeElement(at: offset, to: (Library.read(item.url, item.mp4), nil))
                    return
                }

                let hash = Library.hash(item.url)
                read.initializeElement(at: offset, to: (hash != nil && hash == old.hash ? old.track.at(item.url) : Library.read(item.url, item.mp4), hash))
            }

            var changes = Array(repeating: [Cache.Change](), count: folders.count)
            var failed = Array(repeating: [String](), count: folders.count)

            for (offset, item) in part.enumerated() {
                slots[item.slot] = read[offset].track

                if let track = read[offset].track {
                    changes[item.folder].append(Cache.Change(path: item.path, modified: item.modified, size: item.size, hash: read[offset].hash, track: track))
                } else {
                    failed[item.folder].append(item.path)
                }
            }

            Log.library.info("batch", metadata: ["start": "\(start)", "end": "\(part.endIndex)", "total": "\(work.count)", "unreadable": "\(failed.reduce(0) { $0 + $1.count })", "paths": Log.list(failed.lazy.flatMap(\.self).prefix(20))])
            for (number, cache) in caches.enumerated() where !changes[number].isEmpty || !failed[number].isEmpty {
                guard cache?.save(changes[number], removed: failed[number], covers: [:]) == false else { continue }

                Log.library.error("batch not saved", metadata: ["folder": "\(folders[number].path)", "songs": "\(changes[number].count + failed[number].count)"])
                for item in part where item.folder == number {
                    slots[item.slot] = item.old?.track.at(item.url)
                }
            }

            if part.endIndex < work.count {
                let (albums, index) = assemble(slots.compactMap(\.self))
                guard await progress((albums, index, stored)) else { return (albums, index, stored) }
            }
        }

        let (albums, index) = assemble(slots.compactMap(\.self))
        let covers = covers(albums, stored)
        var fresh = Array(repeating: [String: Data](), count: folders.count)

        for album in albums {
            let url = album.tracks[0].url
            guard let number = caches.firstIndex(where: { $0.map { !$0.relative(url).hasPrefix("/") } ?? false }), !saved[number].contains(album.id), let cover = covers[album.id] else { continue }

            fresh[number][album.id] = cover
        }

        for (number, cache) in caches.enumerated() where !fresh[number].isEmpty {
            cache?.save([], removed: [], covers: fresh[number])
        }

        return (albums, index, covers)
    }

    @concurrent
    nonisolated static func rebuild(_ folders: [URL]) async -> Snapshot? {
        let keys: Set<URLResourceKey> = [.contentTypeKey, .contentModificationDateKey, .fileSizeKey]
        let caches = folders.map { Cache($0) }
        var files: [(url: URL, mp4: Bool, folder: Int, path: String, modified: Double, size: Int)] = []

        for (number, folder) in folders.enumerated() {
            let cache = caches[number]
            let root = cache.map { URL(filePath: $0.root) } ?? folder
            let failures = Failures()
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants]) { url, error in
                failures.add(url, error)
                return true
            }
            guard let enumerator, cache != nil else {
                Log.library.error("rebuild unreadable", metadata: ["folder": "\(root.path)", "cache": "\(cache != nil)"])
                return nil
            }

            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: keys), let type = values.contentType, types.contains(where: type.conforms) else { continue }

                files.append((url, type.conforms(to: .mpeg4Audio), number, cache?.relative(url) ?? url.path, values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0, values.fileSize ?? 0))
            }

            guard failures.items.isEmpty else {
                Log.library.error("rebuild unreadable", metadata: ["folder": "\(root.path)", "errors": Log.list(failures.items.prefix(20))])
                return nil
            }
        }

        nonisolated(unsafe) let read = UnsafeMutableBufferPointer<Track?>.allocate(capacity: files.count)
        read.initialize(repeating: nil)
        defer { read.deinitialize().deallocate() }

        DispatchQueue.concurrentPerform(iterations: files.count) { offset in
            read[offset] = Library.read(files[offset].url, files[offset].mp4)
        }

        var changes = Array(repeating: [Cache.Change](), count: folders.count)
        var tracks: [Track] = []
        tracks.reserveCapacity(files.count)
        for (offset, file) in files.enumerated() {
            guard let track = read[offset] else { continue }

            tracks.append(track)
            changes[file.folder].append(Cache.Change(path: file.path, modified: file.modified, size: file.size, hash: nil, track: track))
        }

        let (albums, index) = assemble(tracks)
        let covers = covers(albums, [:])
        var stored = Array(repeating: [String: Data](), count: folders.count)
        for album in albums {
            let url = album.tracks[0].url
            guard let number = caches.firstIndex(where: { $0.map { !$0.relative(url).hasPrefix("/") } ?? false }), let cover = covers[album.id] else { continue }

            stored[number][album.id] = cover
        }

        Log.library.info("rebuild read", metadata: ["files": "\(files.count)", "songs": "\(tracks.count)", "albums": "\(albums.count)", "covers": "\(covers.count)"])
        for (number, cache) in caches.enumerated() {
            guard cache?.save(changes[number], removed: [], covers: stored[number], replacing: true) == true else { return nil }
        }

        return (albums, index, covers)
    }

    private nonisolated static func assemble(_ tracks: [Track]) -> (albums: [Album], index: Index) {
        var groups: [String: [Track]] = [:]

        for track in tracks {
            groups[track.albumID, default: []].append(track)
        }

        let albums = groups.map { id, tracks in
            let numbers = Set(tracks.map { $0.disc << 16 | $0.number })
            let ordered = numbers.count == tracks.count && !tracks.contains { $0.number == 0 }
                ? tracks.sorted { ($0.disc, $0.number) < ($1.disc, $1.number) }
                : tracks.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
            let shared = tracks.allSatisfy { $0.albumArtist == tracks[0].albumArtist } ? tracks[0].albumArtist : ""
            let artist = tracks.allSatisfy { $0.artist == tracks[0].artist } ? tracks[0].artist : shared.isEmpty ? "Various Artists" : shared

            return Album(id: id, title: tracks[0].album, artist: artist, year: tracks.map(\.year).max()!, tracks: ordered)
        }
        .sorted {
            let artist = $0.artist.localizedStandardCompare($1.artist)
            guard artist == .orderedSame else { return artist == .orderedAscending }
            guard $0.year == $1.year else { return $0.year < $1.year }

            let title = $0.title.localizedStandardCompare($1.title)
            return title == .orderedSame ? $0.id < $1.id : title == .orderedAscending
        }

        var index = Index()
        index.spans.reserveCapacity(tracks.count)
        index.albums.reserveCapacity(albums.count + 1)

        for album in albums {
            for track in album.tracks {
                let start = Int32(index.bytes.count)
                index.bytes.append(contentsOf: Fuzzy.fold(track.title).utf8)
                let title = Int32(index.bytes.count)
                index.bytes.append(contentsOf: Fuzzy.fold(track.artist).utf8)
                let artist = Int32(index.bytes.count)
                index.bytes.append(contentsOf: Fuzzy.fold(track.album).utf8)
                index.spans.append((start, title, artist, Int32(index.bytes.count)))
            }

            index.albums.append(Int32(index.spans.count))
        }

        return (albums, index)
    }

    nonisolated static func hash(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }

        return Data(SHA256.hash(data: data))
    }

    private nonisolated static func covers(_ albums: [Album], _ previous: [String: Data]) -> [String: Data] {
        var covers: [String: Data] = [:]
        var missing: [Album] = []

        for album in albums {
            if let cover = previous[album.id] {
                covers[album.id] = cover
            } else {
                missing.append(album)
            }
        }

        guard !missing.isEmpty else { return covers }

        for (album, cover) in zip(missing, Picture.generate(missing.map { $0.tracks[0].url })) {
            covers[album.id] = cover
        }

        return covers
    }

    private nonisolated static func read(_ url: URL, _ mp4: Bool) -> Track? {
        var tags = MP4.Tags()

        if mp4, let parsed = MP4.read(url) {
            tags = parsed
        } else {
            var file: AudioFileID?
            guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
            defer { AudioFileClose(file) }

            var info: Unmanaged<CFDictionary>?
            var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
            AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &info)
            let dictionary = info?.takeRetainedValue() as NSDictionary? ?? [:]

            func tag(_ key: String) -> String {
                dictionary[key] as? String ?? ""
            }

            size = UInt32(MemoryLayout<Double>.size)
            AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &tags.duration)

            tags.title = tag(kAFInfoDictionary_Title)
            tags.artist = tag(kAFInfoDictionary_Artist)
            tags.album = tag(kAFInfoDictionary_Album)
            tags.year = tag(kAFInfoDictionary_Year)
            if tags.year.isEmpty { tags.year = tag(kAFInfoDictionary_RecordedDate) }

            let id3 = ID3.read(url)
            tags.original = id3.original
            tags.albumArtist = id3.albumArtist
            tags.disc = id3.disc
            if tags.year.isEmpty { tags.year = id3.release }
            tags.number = Int(tag(kAFInfoDictionary_TrackNumber).prefix { $0.isNumber }) ?? 0
        }

        let directory = url.deletingLastPathComponent()
        let album = tags.album.isEmpty ? directory.lastPathComponent : tags.album
        let original = Int(tags.original.prefix(4)) ?? 0

        return Track(
            url: url,
            title: tags.title.isEmpty ? url.deletingPathExtension().lastPathComponent : tags.title,
            artist: tags.artist.isEmpty ? "Unknown Artist" : tags.artist,
            album: album,
            number: tags.number,
            disc: tags.disc,
            albumArtist: tags.albumArtist,
            year: original > 0 ? original : Int(tags.year.prefix(4)) ?? 0,
            duration: tags.duration,
            albumID: StoredPath.encode(directory.path) + "\n" + album
        )
    }
}

enum Artwork {
    static var covers: [String: Data] = [:]

    private static let cache = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500
        return cache
    }()

    static func image(_ track: Track) -> NSImage? {
        let key = track.albumID as NSString
        if let image = cache.object(forKey: key) { return image }

        guard let data = covers[track.albumID], let image = NSImage(data: data) else { return nil }

        cache.setObject(image, forKey: key)
        return image
    }
}
