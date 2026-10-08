import AppKit
import AudioToolbox
import AVFoundation
import CoreServices
import ImageIO
import UniformTypeIdentifiers

nonisolated struct Track: Identifiable, Hashable, Sendable {
    let url: URL
    let title: String
    let artist: String
    let album: String
    let number: Int
    let year: Int
    let duration: Double
    let keys: [[UInt8]]

    var id: URL { url }
    var albumID: String { url.deletingLastPathComponent().path + "\n" + album }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

nonisolated enum Fuzzy {
    static func fold(_ text: String) -> [UInt8] {
        Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).utf8)
    }

    static func score(_ pattern: [UInt8], _ text: [UInt8]) -> Int {
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

nonisolated struct Album: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let year: Int
    let tracks: [Track]

    var directory: URL { tracks[0].url.deletingLastPathComponent() }
}

@Observable
final class Library {
    private static let key = "folders"

    var albums: [Album] = [] { didSet { search() } }
    var scanning = false
    var query = "" { didSet { if query != oldValue { search() } } }

    private(set) var filtered: [Album] = []
    private(set) var tracks: [Track] = []
    private(set) var artists: [(name: String, albums: [Album])] = []
    private(set) var version = 0

    var folders: [URL] = UserDefaults.standard.stringArray(forKey: Library.key)?.map { URL(filePath: $0) } ?? [] {
        didSet {
            UserDefaults.standard.set(folders.map(\.path), forKey: Library.key)
            watch()
            scan()
        }
    }

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

        scanning = true

        Task {
            let albums = await Library.load(folders)
            guard generation == self.generation else { return }

            self.albums = albums
            scanning = false
        }
    }

    private func search() {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { Fuzzy.fold(String($0)) }

        if tokens.isEmpty {
            filtered = albums
            tracks = albums.flatMap(\.tracks)
        } else {
            var albumScores: [(score: Int, album: Album)] = []
            var trackScores: [(score: Int, track: Track)] = []
            var best = [Int](repeating: 0, count: tokens.count)

            for album in albums {
                best.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }

                for track in album.tracks {
                    var total = 0
                    var all = true

                    for (index, token) in tokens.enumerated() {
                        let score = track.keys.reduce(0) { max($0, Fuzzy.score(token, $1)) }
                        best[index] = max(best[index], score)
                        total += score
                        all = all && score > 0
                    }

                    if all { trackScores.append((total, track)) }
                }

                if !best.contains(0) { albumScores.append((best.reduce(0, +), album)) }
            }

            filtered = albumScores.enumerated().sorted { ($0.element.score, $1.offset) > ($1.element.score, $0.offset) }.map(\.element.album)
            tracks = trackScores.enumerated().sorted { ($0.element.score, $1.offset) > ($1.element.score, $0.offset) }.map(\.element.track)
        }

        artists = Dictionary(grouping: filtered, by: \.artist)
            .map { ($0.key, $0.value.sorted { $0.year < $1.year }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        version += 1
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
    private nonisolated static func load(_ folders: [URL]) async -> [Album] {
        let types = AVURLAsset.audiovisualContentTypes.filter { $0.conforms(to: .audio) }
        var urls: [URL] = []

        for folder in folders {
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentTypeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType, types.contains(where: type.conforms) else { continue }

                urls.append(url)
            }
        }

        let files = urls

        nonisolated(unsafe) let tracks = UnsafeMutableBufferPointer<Track?>.allocate(capacity: files.count)
        defer { tracks.deinitialize().deallocate() }

        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            tracks.initializeElement(at: index, to: read(files[index]))
        }

        var groups: [String: [Track]] = [:]

        for case let track? in tracks {
            groups[track.albumID, default: []].append(track)
        }

        return groups.map { id, tracks in
            let numbers = Set(tracks.map(\.number))
            let ordered = numbers.count == tracks.count && !numbers.contains(0)
                ? tracks.sorted { $0.number < $1.number }
                : tracks.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
            let artist = tracks.allSatisfy { $0.artist == tracks[0].artist } ? tracks[0].artist : "Various Artists"

            return Album(id: id, title: tracks[0].album, artist: artist, year: tracks.map(\.year).max()!, tracks: ordered)
        }
        .sorted {
            let order = $0.artist.localizedStandardCompare($1.artist)
            return order == .orderedSame ? $0.year < $1.year : order == .orderedAscending
        }
    }

    private nonisolated static func read(_ url: URL) -> Track? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }

        var info: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &size, &info)
        let tags = info?.takeRetainedValue() as? [String: Any] ?? [:]

        var duration = 0.0
        size = UInt32(MemoryLayout<Double>.size)
        AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration)

        func tag(_ key: String) -> String {
            (tags[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        let title = tag(kAFInfoDictionary_Title)
        let artist = tag(kAFInfoDictionary_Artist)
        let album = tag(kAFInfoDictionary_Album)
        let year = tag(kAFInfoDictionary_Year).isEmpty ? tag(kAFInfoDictionary_RecordedDate) : tag(kAFInfoDictionary_Year)

        let name = title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
        let performer = artist.isEmpty ? "Unknown Artist" : artist
        let record = album.isEmpty ? url.deletingLastPathComponent().lastPathComponent : album

        return Track(
            url: url,
            title: name,
            artist: performer,
            album: record,
            number: Int(tag(kAFInfoDictionary_TrackNumber).prefix { $0.isNumber }) ?? 0,
            year: Int(year.prefix(4)) ?? 0,
            duration: duration,
            keys: [Fuzzy.fold(name), Fuzzy.fold(performer), Fuzzy.fold(record)]
        )
    }
}

enum Artwork {
    private static let cache = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 256 << 20
        return cache
    }()

    private nonisolated static let names = ["cover", "folder", "front", "album"]

    static func cached(_ track: Track) -> NSImage? {
        cache.object(forKey: track.albumID as NSString)
    }

    static func image(_ track: Track) async -> NSImage? {
        if let image = cached(track) { return image }

        guard let cgImage = await load(track.url) else { return nil }

        let image = NSImage(cgImage: cgImage, size: .zero)
        cache.setObject(image, forKey: track.albumID as NSString, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    @concurrent
    private nonisolated static func load(_ url: URL) async -> CGImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ] as CFDictionary

        let metadata = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []

        if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
           let data = try? await item.load(.dataValue),
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
            return image
        }

        let files = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.contentTypeKey])) ?? []
        let images = files.filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true }
        let file = images.first { names.contains($0.deletingPathExtension().lastPathComponent.lowercased()) } ?? images.first

        return file.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) }
    }
}
