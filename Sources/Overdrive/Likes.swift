import Foundation

@Observable
final class Likes {
    nonisolated static func file(in folder: URL?) -> URL {
        (folder ?? URL.homeDirectory.appending(path: "Music/Library", directoryHint: .isDirectory))
            .appending(path: "Likes.plist", directoryHint: .notDirectory)
    }

    private(set) var paths: [String] = []

    @ObservationIgnored private let file: () -> URL
    @ObservationIgnored private let folder: () -> URL?
    private var liked: Set<String> = []

    init(file: URL, folder: URL) {
        self.file = { file }
        self.folder = { folder }
        load()
    }

    init(file: URL, folderPath: String) {
        self.file = { file }
        self.folder = { URL(fileURLWithPath: folderPath) }
        load()
    }

    init(file: @escaping () -> URL, folder: @escaping () -> URL?) {
        self.file = file
        self.folder = folder
        load()
    }

    private var folderPath: String { folder().map(Library.real) ?? "" }

    func load() {
        let base = folderPath
        let stored = Persist.read([String].self, from: file()) ?? []
        var seen: Set<String> = []
        seen.reserveCapacity(stored.count)

        paths = stored.map { StoredPath.decode($0, relativeTo: base) }.filter { seen.insert($0).inserted }
        liked = seen
        Log.likes.info("load", metadata: ["file": "\(file().path)", "songs": "\(paths.count)"])
    }

    func contains(_ track: Track) -> Bool {
        liked.contains(track.url.path)
    }

    func toggle(_ tracks: [Track]) {
        if tracks.allSatisfy(contains) {
            remove(tracks)
        } else {
            add(tracks)
        }
    }

    func add(_ tracks: [Track]) {
        Log.likes.info("add", metadata: Log.paths(tracks.map(\.url.path)))
        var changed = false

        for track in tracks where liked.insert(track.url.path).inserted {
            paths.append(track.url.path)
            changed = true
        }

        if changed { save() }
    }

    func remove(_ tracks: [Track]) {
        Log.likes.info("remove", metadata: Log.paths(tracks.map(\.url.path)))
        let removed = Set(tracks.map(\.url.path))
        guard !removed.isEmpty, !liked.isDisjoint(with: removed) else { return }

        paths.removeAll { removed.contains($0) }
        liked.subtract(removed)
        save()
    }

    private func save() {
        guard let folder = folder(), FileManager.default.fileExists(atPath: folder.path) else {
            return Log.likes.error("save skipped", metadata: ["reason": "folder missing", "folder": "\(folder()?.path ?? "")"])
        }

        let base = folderPath
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(paths.map { StoredPath.encode($0, relativeTo: base) }) else { return }

        Persist.write(data, to: file())
    }
}
