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
        ranks[slot].count += 1
        lift(&ranks, &slots, slot)
    }

    /// Move an entry up to where its count belongs: best first, and ties by
    /// the key, so the order while you play and the order after a read are
    /// one order, and a list that walks it never jumps between two songs of
    /// the same count.
    nonisolated static func lift(_ ranks: inout [Rank], _ slots: inout [String: Int], _ slot: Int) {
        var at = slot

        while at > 0, outranked(ranks[at - 1], by: ranks[at]) {
            ranks.swapAt(at, at - 1)
            slots[ranks[at].key] = at
            slots[ranks[at - 1].key] = at - 1
            at -= 1
        }
    }

    /// True when the entry ahead holds fewer plays, or the same plays under a
    /// later key.
    private nonisolated static func outranked(_ ahead: Rank, by mover: Rank) -> Bool {
        ahead.count < mover.count || (ahead.count == mover.count && ahead.key > mover.key)
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

    /// The best `limit` keys in the order of the counts: best first, ties by
    /// key. No draw: this is the list the user reads, so the same counts give
    /// the same order. A key `live` rejects is skipped where it sits, and the
    /// pending counts ride in, so a song that just finished ranks at once.
    func rank(_ limit: Int, _ live: (String) -> Bool) -> [String] {
        guard limit > 0 else { return [] }
        _ = revision

        var keys: [String] = []
        keys.reserveCapacity(limit)

        for entry in ranked where live(entry.key) {
            keys.append(entry.key)
            if keys.count == limit { break }
        }

        return keys
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
            Plays.lift(&ranked, &slots, ranked.count - 1)
            onPlay?(track)
            return
        }

        guard slots[key] != nil else { return }
        Plays.sift(&ranked, &slots, slots[key]!)
        onPlay?(track)
    }

    /// Removes the counts of the songs and writes the file at once. A failed
    /// write changes nothing. Returns the plays each removed key held.
    @discardableResult
    func reset(_ tracks: [Track]) -> [String: Int] {
        let keys = Set(tracks.lazy.map(Self.key)).filter { slots[$0] != nil }
        guard !keys.isEmpty else { return [:] }
        guard let url = target, let root, FileManager.default.fileExists(atPath: root.path) else {
            Log.plays.warning("reset skipped", metadata: ["reason": "folder missing", "songs": "\(keys.count)"])
            return [:]
        }

        var merged = Self.merged(counts, pending)
        var removed: [String: Int] = [:]
        for key in keys { removed[key] = merged.removeValue(forKey: key) }
        guard let data = Persist.encode(merged, for: url), Persist.write(data, to: url) else {
            Log.plays.error("reset failed", metadata: ["file": "\(url.path)", "songs": "\(keys.count)"])
            return [:]
        }

        counts = merged
        pending = [:]
        ranked.removeAll { keys.contains($0.key) }
        slots.removeAll(keepingCapacity: true)
        for (slot, entry) in ranked.enumerated() { slots[entry.key] = slot }
        revision += 1
        Log.plays.info("reset", metadata: ["file": "\(url.path)", "songs": "\(keys.count)", "plays": "\(removed.values.reduce(0, +))"])
        return removed
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

    /// The hourly save: one snapshot of every count, merged, encoded, and
    /// written on the `Persist` queue, so the main thread never waits. The
    /// plays stay in `pending` until a synchronous `flush`, so a failed write
    /// loses nothing and the next save writes them again.
    func save() {
        guard !pending.isEmpty else { return }
        guard let url = target, let root, FileManager.default.fileExists(atPath: root.path) else {
            Log.plays.debug("save skipped", metadata: ["pending": "\(pending.count)", "folder": "\(root?.path ?? "")"])
            return
        }

        let counts = counts
        let pending = pending
        Persist.later {
            let merged = Plays.merged(counts, pending)
            guard let data = Persist.encode(merged, for: url) else { return [] }
            return [(url, data)]
        }
        Log.plays.info("save", metadata: ["file": "\(url.path)", "pending": "\(pending.count)"])
    }

    private func order() {
        let totals = pending.isEmpty ? counts : Self.merged(counts, pending)
        ranked = totals.map { Rank(key: $0.key, count: $0.value) }.sorted {
            $0.count == $1.count ? $0.key < $1.key : $0.count > $1.count
        }
        slots = Dictionary(ranked.enumerated().map { ($0.element.key, $0.offset) }) { first, _ in first }
    }
}
