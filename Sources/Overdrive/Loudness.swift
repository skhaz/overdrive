import AVFoundation
import Foundation

final class Loudness {
    nonisolated struct Entry: Codable, Sendable {
        let size: Int
        let modified: Double
        let lufs: Double
        let peak: Float
        let seconds: Double
    }

    nonisolated struct File: Sendable {
        let url: URL
        let size: Int
        let modified: Double
    }

    private nonisolated struct Biquad {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    nonisolated static let name = "Loudness.plist"
    private nonisolated static let target = -14.0
    private nonisolated static let ceiling: Float = 4
    private nonisolated static let workers = 2

    private var entries: [String: Entry] = [:]
    private var roots: [(folder: URL, real: String)] = []
    var albums: [String: [String]] = [:]
    private var worker: Task<Void, Never>?

    var folders: [URL] = [] {
        didSet { if folders != oldValue { load() } }
    }

    init(folders: [URL] = []) {
        self.folders = folders
        load()
    }

    private func load() {
        roots = folders.map { folder in (folder, folder.path.withCString { path in realpath(path, nil).map { defer { free($0) }; return String(cString: $0) } } ?? folder.path) }
        entries = [:]

        for root in roots {
            guard let stored = try? PropertyListDecoder().decode([String: Entry].self, from: Data(contentsOf: root.folder.appending(path: Self.name))) else { continue }

            entries.reserveCapacity(entries.count + stored.count)
            for (key, entry) in stored {
                entries[root.real + "/" + key] = entry
            }
        }
    }

    func gain(_ track: Track, album: Bool) -> Float? {
        if album, let paths = albums[track.albumID] {
            let values = paths.compactMap { entries[$0] }
            if values.count == paths.count { return Loudness.gain(values) }
        }

        return entries[track.url.path].map { Loudness.gain([$0]) }
    }

    func measure(_ track: Track, album: Bool) async {
        if entries[track.url.path] == nil, let file = Loudness.file(track.url), let entry = await Loudness.measure(file) {
            entries[track.url.path] = entry
            save()
        }

        guard album, let paths = albums[track.albumID] else { return }

        let missing = paths.filter { entries[$0] == nil }
        guard !missing.isEmpty else { return }

        Task(priority: .utility) {
            var measured = false

            for path in missing where entries[path] == nil {
                guard let file = Loudness.file(URL(filePath: path)), let entry = await Loudness.measure(file) else { continue }
                entries[path] = entry
                measured = true
            }

            if measured { save() }
        }
    }

    func update(_ albums: [Album]) {
        self.albums = Dictionary(albums.map { ($0.id, $0.tracks.map(\.url.path)) }) { first, _ in first }

        worker?.cancel()
        let urls = albums.flatMap(\.tracks).map(\.url)
        let known = entries

        worker = Task(priority: .background) {
            let (valid, missing) = await Loudness.stale(urls, known)
            guard !Task.isCancelled else { return }

            let count = entries.count
            entries = entries.filter { valid.contains($0.key) || known[$0.key] == nil }
            if entries.count != count { save() }

            var measured = 0

            await withTaskGroup(of: (String, Entry?).self) { group in
                var files = missing.makeIterator()
                var running = 0

                while true {
                    while running < Loudness.workers, let file = files.next() {
                        await Loudness.idle()
                        group.addTask { (file.url.path, await Loudness.measure(file)) }
                        running += 1
                    }

                    guard let (path, entry) = await group.next() else { break }
                    guard !Task.isCancelled else { return group.cancelAll() }

                    running -= 1

                    if let entry {
                        entries[path] = entry
                        measured += 1
                        if measured.isMultiple(of: 100) { save() }
                    }
                }
            }

            if measured > 0 { save() }
        }
    }

    private func save() {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        var stored = Array(repeating: [String: Entry](), count: roots.count)

        for (path, entry) in entries {
            var best: Int?
            for index in roots.indices where path.hasPrefix(roots[index].real + "/") && roots[index].real.count > best.map({ roots[$0].real.count }) ?? -1 {
                best = index
            }
            guard let best else { continue }

            stored[best][String(path.dropFirst(roots[best].real.count + 1))] = entry
        }

        for index in roots.indices where !stored[index].isEmpty {
            guard let data = try? encoder.encode(stored[index]) else { continue }

            Persist.write(data, to: roots[index].folder.appending(path: Self.name))
        }
    }

    private nonisolated static func idle() async {
        while ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            guard (try? await Task.sleep(for: .seconds(30))) != nil else { return }
        }
    }

    private nonisolated static func gain(_ values: [Entry]) -> Float {
        var power = 0.0
        var seconds = 0.0
        var peak: Float = 0

        for value in values {
            power += pow(10, value.lufs / 10) * value.seconds
            seconds += value.seconds
            peak = max(peak, value.peak)
        }

        guard power > 0, seconds > 0 else { return 1 }

        let gain = min(Float(pow(10, (target - 10 * log10(power / seconds)) / 20)), ceiling)
        return peak > 0 ? min(gain, 1 / peak) : gain
    }

    private nonisolated static func file(_ url: URL) -> File? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }

        return File(url: url, size: size, modified: modified.timeIntervalSinceReferenceDate)
    }

    @concurrent
    private nonisolated static func stale(_ urls: [URL], _ entries: [String: Entry]) async -> (valid: Set<String>, missing: [File]) {
        var valid = Set<String>()
        var missing: [File] = []
        valid.reserveCapacity(urls.count)

        for url in urls {
            guard let file = file(url) else { continue }

            if let entry = entries[url.path], entry.size == file.size, entry.modified == file.modified {
                valid.insert(url.path)
            } else {
                missing.append(file)
            }
        }

        return (valid, missing)
    }

    private nonisolated static func filters(_ rate: Double) -> (Biquad, Biquad) {
        var k = tan(.pi * 1681.974450955533 / rate)
        var q = 0.7071752369554196
        let high = pow(10, 3.999843853973347 / 20)
        let band = pow(high, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (high + band * k / q + k * k) / a0, b1: 2 * (k * k - high) / a0, b2: (high - band * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)

        k = tan(.pi * 38.13547087602444 / rate)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        let pass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)

        return (shelf, pass)
    }

    @concurrent
    private nonisolated static func measure(_ file: File) async -> Entry? {
        guard let audio = try? AVAudioFile(forReading: file.url) else { return nil }

        let format = audio.processingFormat
        let channels = min(Int(format.channelCount), 2)
        let rate = format.sampleRate
        let step = Int(rate / 10)
        guard step > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536), let data = buffer.floatChannelData else { return nil }

        var chains = (0..<channels).map { _ in filters(rate) }
        var quarters: [Double] = []
        quarters.reserveCapacity(Int(audio.length) / step + 1)
        var sum = 0.0
        var filled = 0
        var frames = 0
        var peak: Float = 0

        while audio.framePosition < audio.length {
            if Task.isCancelled { return nil }

            do {
                try audio.read(into: buffer)
            } catch {
                if frames > 0 || (error as NSError).code == eofErr { break }
                return nil
            }

            let count = Int(buffer.frameLength)
            if count == 0 { break }
            frames += count

            var offset = 0
            while offset < count {
                let length = min(count - offset, step - filled)

                for channel in 0..<channels {
                    let samples = data[channel]
                    var chain = chains[channel]

                    for index in offset..<offset + length {
                        let sample = samples[index]
                        peak = max(peak, abs(sample))
                        let filtered = chain.1.run(chain.0.run(Double(sample)))
                        sum += filtered * filtered
                    }

                    chains[channel] = chain
                }

                offset += length
                filled += length

                if filled == step {
                    quarters.append(sum)
                    sum = 0
                    filled = 0
                }
            }
        }

        let seconds = Double(frames) / rate
        let lufs = { (power: Double) in -0.691 + 10 * log10(power) }
        let size = Double(step * 4)
        var total = 0.0
        var blocks: [Double] = []
        blocks.reserveCapacity(max(quarters.count - 3, 0))

        for index in quarters.indices.dropFirst(3) {
            let power = (quarters[index - 3] + quarters[index - 2] + quarters[index - 1] + quarters[index]) / size
            guard lufs(power) > -70 else { continue }

            blocks.append(power)
            total += power
        }

        guard !blocks.isEmpty else { return Entry(size: file.size, modified: file.modified, lufs: -70, peak: peak, seconds: seconds) }

        let threshold = lufs(total / Double(blocks.count)) - 10
        var gated = 0.0
        var count = 0

        for power in blocks where lufs(power) > threshold {
            gated += power
            count += 1
        }

        return Entry(size: file.size, modified: file.modified, lufs: lufs(gated / Double(count)), peak: peak, seconds: seconds)
    }
}
