import Foundation

@Observable
final class Likes {
    nonisolated static func file(in folder: URL?) -> URL {
        (folder ?? URL.homeDirectory.appending(path: "Music/Library", directoryHint: .isDirectory))
            .appending(path: "Likes.plist", directoryHint: .notDirectory)
    }

    private var storedPaths: [String] = []

    var paths: [String] {
        storedPaths.map { StoredPath.decode($0, relativeTo: folderPath) }
    }

    @ObservationIgnored private let file: () -> URL
    @ObservationIgnored private let folder: () -> URL?
    private let folderPath: String
    private var liked: Set<String> = []

    init(file: URL, folder: URL) {
        self.file = { file }
        self.folder = { folder }
        self.folderPath = folder.path
        load()
    }

    init(file: URL, folderPath: String) {
        self.file = { file }
        self.folder = { URL(fileURLWithPath: folderPath) }
        self.folderPath = folderPath
        load()
    }

    init(file: @escaping () -> URL, folder: @escaping () -> URL?) {
        self.file = file
        self.folder = folder
        self.folderPath = folder()?.path ?? ""
        load()
    }

    func load() {
        let stored = (try? Data(contentsOf: file())).flatMap { try? PropertyListDecoder().decode([String].self, from: $0) } ?? []
        var seen: Set<String> = []
        seen.reserveCapacity(stored.count)

        storedPaths = stored.map { StoredPath.decode($0, relativeTo: folderPath) }.filter { seen.insert($0).inserted }
        liked = Set(storedPaths.map { StoredPath.decode($0, relativeTo: folderPath) })
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
        var changed = false

        for track in tracks where liked.insert(track.url.path).inserted {
            storedPaths.append(StoredPath.encode(track.url.path, relativeTo: folderPath))
            changed = true
        }

        if changed { save() }
    }

    func remove(_ tracks: [Track]) {
        let removed = Set(tracks.map(\.url.path))
        guard !removed.isEmpty, !liked.isDisjoint(with: removed) else { return }

        storedPaths.removeAll { removed.contains(StoredPath.decode($0, relativeTo: folderPath)) }
        liked.subtract(removed)
        save()
    }

    private func save() {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(storedPaths.map { StoredPath.encode($0, relativeTo: folderPath) }) else { return }

        Persist.write(data, to: file())
    }
}
