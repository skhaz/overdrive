import AppKit
import AudioToolbox
import AVFoundation
import CoreServices
import UniformTypeIdentifiers

nonisolated struct Track: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    let artist: String
    let album: String
    let number: Int
    let year: Int
    let duration: Double
    let albumID: String

    var id: URL { url }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
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

    private(set) var albums: [Album] = []
    private(set) var filtered: [Album] = []
    private(set) var tracks: [Track] = []
    private(set) var version = 0
    var scanning = false
    var query = "" { didSet { if query != oldValue { search() } } }

    var folders: [URL] = UserDefaults.standard.stringArray(forKey: Library.key)?.map { URL(filePath: $0) } ?? [] {
        didSet {
            UserDefaults.standard.set(folders.map(\.path), forKey: Library.key)
            watch()
            scan()
        }
    }

    var artists: [(name: String, albums: [Album])] {
        if grouped.version != version {
            grouped = (version, Dictionary(grouping: filtered, by: \.artist)
                .map { ($0.key, $0.value.sorted { $0.year < $1.year }) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }

        return grouped.artists
    }

    @ObservationIgnored private var index = Index()
    @ObservationIgnored private var everything: [Track] = []
    @ObservationIgnored private var grouped: (version: Int, artists: [(name: String, albums: [Album])]) = (-1, [])
    @ObservationIgnored private var bytes: [UInt8] = []
    @ObservationIgnored private var tokens: [Range<Int>] = []
    @ObservationIgnored private var best: [Int] = []
    @ObservationIgnored private var albumHits: [(score: Int32, item: Int32)] = []
    @ObservationIgnored private var trackHits: [(score: Int32, item: Int32)] = []
    @ObservationIgnored private var ranked: [(score: Int32, item: Int32)] = []
    @ObservationIgnored private var counts: [Int] = []
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var generation = 0

    init() {
        watch()
        scan()
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else { return }

        add(panel.urls)
    }

    func add(_ urls: [URL]) {
        let new = urls.filter { url in !folders.contains { url.path.hasPrefix($0.path + "/") || url == $0 } }
        guard !new.isEmpty else { return }

        folders = folders.filter { folder in !new.contains { folder.path.hasPrefix($0.path + "/") } } + new
    }

    func scan() {
        generation += 1
        let generation = generation
        let folders = folders
        let covers = Artwork.covers

        scanning = true

        Task {
            let result = await Library.load(folders, covers)
            guard generation == self.generation else { return }

            Artwork.covers = result.covers
            index = result.index
            everything = result.albums.flatMap(\.tracks)
            albums = result.albums
            search()
            scanning = false
        }
    }

    private func search() {
        defer { version += 1 }

        bytes.removeAll(keepingCapacity: true)
        tokens.removeAll(keepingCapacity: true)

        for word in query.split(whereSeparator: \.isWhitespace) {
            let start = bytes.count
            bytes.append(contentsOf: Fuzzy.fold(String(word)).utf8)
            tokens.append(start..<bytes.count)
        }

        guard !tokens.isEmpty else {
            filtered = albums
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

                            for token in tokens.indices {
                                let word = UnsafeBufferPointer(rebasing: pattern[tokens[token]])
                                let score = max(Fuzzy.score(word, title), Fuzzy.score(word, artist), Fuzzy.score(word, record))
                                best[token] = max(best[token], score)
                                total += score
                                all = all && score > 0
                            }

                            if all { trackHits.append((Int32(total), Int32(track))) }
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

        rank(trackHits, limit)
        tracks = []
        tracks.reserveCapacity(ranked.count)
        for hit in ranked { tracks.append(everything[Int(hit.item)]) }
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
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            MainActor.assumeIsolated {
                Unmanaged<Library>.fromOpaque(info!).takeUnretainedValue().scan()
            }
        }

        stream = FSEventStreamCreate(nil, callback, &context, folders.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
        FSEventStreamSetDispatchQueue(stream!, .main)
        FSEventStreamStart(stream!)
    }

    @concurrent
    private nonisolated static func load(_ folders: [URL], _ previous: [String: Data]) async -> (albums: [Album], index: Index, covers: [String: Data]) {
        let types = AVURLAsset.audiovisualContentTypes.filter { $0.conforms(to: .audio) }
        var urls: [(url: URL, mp4: Bool)] = []

        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, types.contains(where: type.conforms) else { continue }

                urls.append((url, type.conforms(to: .mpeg4Audio)))
            }
        }

        let files = urls

        nonisolated(unsafe) let tracks = UnsafeMutableBufferPointer<Track?>.allocate(capacity: files.count)
        defer { tracks.deinitialize().deallocate() }

        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            tracks.initializeElement(at: index, to: read(files[index].url, files[index].mp4))
        }

        var groups: [String: [Track]] = [:]

        for case let track? in tracks {
            groups[track.albumID, default: []].append(track)
        }

        let albums = groups.map { id, tracks in
            let numbers = Set(tracks.map(\.number))
            let ordered = numbers.count == tracks.count && !numbers.contains(0)
                ? tracks.sorted { $0.number < $1.number }
                : tracks.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
            let artist = tracks.allSatisfy { $0.artist == tracks[0].artist } ? tracks[0].artist : "Various Artists"

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
        index.spans.reserveCapacity(files.count)
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

        return (albums, index, covers(albums, previous))
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
            tags.number = Int(tag(kAFInfoDictionary_TrackNumber).prefix { $0.isNumber }) ?? 0
        }

        let directory = url.deletingLastPathComponent()
        let album = tags.album.isEmpty ? directory.lastPathComponent : tags.album

        return Track(
            url: url,
            title: tags.title.isEmpty ? url.deletingPathExtension().lastPathComponent : tags.title,
            artist: tags.artist.isEmpty ? "Unknown Artist" : tags.artist,
            album: album,
            number: tags.number,
            year: Int(tags.year.prefix(4)) ?? 0,
            duration: tags.duration,
            albumID: "\(directory.path)\n\(album)"
        )
    }
}

enum Artwork {
    static var covers: [String: Data] = [:]

    private static let cache = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 120
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
