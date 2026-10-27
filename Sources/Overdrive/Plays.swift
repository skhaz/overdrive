import Foundation

@Observable
final class Plays {
    nonisolated struct Rank: Equatable {
        let key: String
        var count: Int
    }

    nonisolated static let name = "Plays.plist"
    private nonisolated static let joined = "\u{1F}"

    nonisolated static func file(in folder: URL?) -> URL {
        (folder ?? URL.homeDirectory.appending(path: "Music/Library", directoryHint: .isDirectory))
            .appending(path: name, directoryHint: .notDirectory)
    }

    nonisolated static func key(_ track: Track) -> String {
        track.url.lastPathComponent + joined + track.album + joined + track.artist
    }

    nonisolated static func merged(_ saved: [String: Int], _ added: [String: Int]) -> [String: Int] {
        saved.merging(added) { $0 + $1 }
    }

    nonisolated static func top(_ ranks: [Rank], _ count: Int, _ live: (String) -> Bool) -> [String] {
        guard count > 0 else { return [] }

        var keys: [String] = []
        var start = 0
        while start < ranks.count, keys.count < count {
            var end = start
            while end < ranks.count, ranks[end].count == ranks[start].count { end += 1 }

            let kept = (start..<end).map { ranks[$0].key }.filter(live)
            let left = count - keys.count
            if kept.count <= left {
                keys.append(contentsOf: kept)
            } else {
                keys.append(contentsOf: kept.shuffled().prefix(left))
            }
            start = end
        }

        return keys
    }

    nonisolated static func sift(_ ranks: inout [Rank], _ slots: inout [String: Int], _ slot: Int) {
        let count = ranks[slot].count + 1
        var at = slot
        while at > 0, ranks[at - 1].count < count {
            ranks.swapAt(at, at - 1)
            slots[ranks[at].key] = at
            slots[ranks[at - 1].key] = at - 1
            at -= 1
        }
        ranks[at].count = count
    }

    private(set) var revision = 0

    private(set) var root: URL?
    var onPlay: ((Track) -> Void)?

    @ObservationIgnored private var counts: [String: Int] = [:]
    @ObservationIgnored private var pending: [String: Int] = [:]
    @ObservationIgnored private var target: URL?
    @ObservationIgnored private var ranked: [Rank] = []
    @ObservationIgnored private var slots: [String: Int] = [:]

    init(root: URL? = nil) {
        self.root = root
        load()
    }

    func count(_ track: Track) -> Int {
        let key = Self.key(track)
        // Reading the revision is what makes every screen that shows a count follow a new play.
        _ = revision
        return (counts[key] ?? 0) + (pending[key] ?? 0)
    }

    func played(_ key: String) -> Bool {
        counts[key] != nil || (pending[key] ?? 0) > 0
    }

    var missing: Bool {
        target == nil
    }

    func top(_ count: Int, _ live: (String) -> Bool) -> [String] {
        Self.top(ranked, count, live)
    }

    func top(_ key: String) -> Int {
        (counts[key] ?? 0) + (pending[key] ?? 0)
    }

    func bump(_ track: Track) {
        let key = Self.key(track)
        pending[key, default: 0] += 1
        revision += 1
        let value = counts[key, default: 0] + pending[key, default: 0]
        Log.plays.info("bump", metadata: ["key": "\(key)", "plays": "\(value)"])
        guard value > 1 else {
            ranked.append(Rank(key: key, count: 1))
            slots[key] = ranked.count - 1
            onPlay?(track)
            return
        }

        guard slots[key] != nil else { return }
        Plays.sift(&ranked, &slots, slots[key]!)
        onPlay?(track)
    }

    func rebind(_ folder: URL?) {
        let carried = flush() ? [:] : pending
        pending = [:]
        root = folder
        load()
        guard !carried.isEmpty else { return }

        pending = carried
        order()
        revision += 1
        Log.plays.info("counts carried", metadata: ["songs": "\(carried.count)", "folder": "\(folder?.path ?? "")"])
    }

    func load() {
        _ = flush()
        pending = [:]
        target = nil
        counts = [:]
        ranked = []
        slots = [:]

        guard let root, FileManager.default.fileExists(atPath: root.path) else {
            revision += 1
            return Log.plays.info("load skipped", metadata: ["reason": "folder missing", "folder": "\(root?.path ?? "")"])
        }

        let file = Self.file(in: root)
        counts = Persist.read([String: Int].self, from: file) ?? [:]
        target = file
        order()
        revision += 1
        Log.plays.info("load", metadata: ["file": "\(file.path)", "songs": "\(counts.count)"])
    }

    @discardableResult
    func flush() -> Bool {
        guard !pending.isEmpty else { return true }
        guard let url = target, let root, FileManager.default.fileExists(atPath: root.path) else {
            Log.plays.debug("flush skipped", metadata: ["pending": "\(pending.count)", "folder": "\(root?.path ?? "")"])
            return false
        }

        let merged = Self.merged(counts, pending)
        guard let data = Persist.encode(merged, for: url) else { return false }
        guard Persist.write(data, to: url) else {
            Log.plays.error("save failed", metadata: ["file": "\(url.path)", "songs": "\(merged.count)"])
            return false
        }

        counts = merged
        pending = [:]
        Log.plays.info("saved", metadata: ["file": "\(url.path)", "songs": "\(counts.count)", "bytes": "\(data.count)"])
        return true
    }

    private func order() {
        let totals = pending.isEmpty ? counts : Self.merged(counts, pending)
        ranked = totals.map { Rank(key: $0.key, count: $0.value) }.sorted {
            $0.count == $1.count ? $0.key < $1.key : $0.count > $1.count
        }
        slots = Dictionary(ranked.enumerated().map { ($0.element.key, $0.offset) }) { first, _ in first }
    }
}
