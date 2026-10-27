import Foundation

@Observable
final class Plays {
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

    private(set) var revision = 0

    private(set) var root: URL?
    var flipped: ((Track) -> Void)?

    @ObservationIgnored private var counts: [String: Int] = [:]
    @ObservationIgnored private var pending: [String: Int] = [:]
    @ObservationIgnored private var target: URL?

    init(root: URL? = nil) {
        self.root = root
        load()
    }

    /// The count of a song, memory first: the disk is one sync behind by design.
    /// Reading the revision makes every screen that shows a count follow a new play.
    func count(_ track: Track) -> Int {
        let key = Self.key(track)
        _ = revision
        return (counts[key] ?? 0) + (pending[key] ?? 0)
    }

    func played(_ key: String) -> Bool {
        counts[key] != nil || (pending[key] ?? 0) > 0
    }

    var missing: Bool {
        target == nil
    }

    func bump(_ track: Track) {
        let key = Self.key(track)
        pending[key, default: 0] += 1
        revision += 1
        let value = counts[key, default: 0] + pending[key, default: 0]
        Log.plays.info("bump", metadata: ["key": "\(key)", "plays": "\(value)"])
        if value == 1 { flipped?(track) }
    }

    /// The file of a library folder, read again when the folders change.
    /// Counts that never reached the disk travel with the music, so a folder
    /// that moved while the app was closed keeps them.
    func rebind(_ folder: URL?) {
        let carried = flush() ? [:] : pending
        pending = [:]
        root = folder
        load()
        guard !carried.isEmpty else { return }

        pending = carried
        revision += 1
        Log.plays.info("counts carried", metadata: ["songs": "\(carried.count)", "folder": "\(folder?.path ?? "")"])
    }

    func load() {
        _ = flush()
        pending = [:]
        target = nil
        counts = [:]

        guard let root, FileManager.default.fileExists(atPath: root.path) else {
            revision += 1
            return Log.plays.info("load skipped", metadata: ["reason": "folder missing", "folder": "\(root?.path ?? "")"])
        }

        let file = Self.file(in: root)
        counts = Persist.read([String: Int].self, from: file) ?? [:]
        target = file
        revision += 1
        Log.plays.info("load", metadata: ["file": "\(file.path)", "songs": "\(counts.count)"])
    }

    /// One atomic write of every count. True when the disk has all of them.
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
}
