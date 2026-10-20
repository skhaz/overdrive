import Foundation

@Observable
final class Likes {
    nonisolated static let file = URL.homeDirectory.appending(path: "Music/Library/Likes.plist", directoryHint: .notDirectory)

    private(set) var paths: [String] = []

    @ObservationIgnored private let file: URL
    private var liked: Set<String> = []

    init(file: URL = Likes.file) {
        self.file = file
        load()
    }

    func load() {
        let stored = (try? Data(contentsOf: file)).flatMap { try? PropertyListDecoder().decode([String].self, from: $0) } ?? []
        var seen: Set<String> = []
        seen.reserveCapacity(stored.count)

        paths = stored.map(StoredPath.decode).filter { seen.insert($0).inserted }
        liked = seen

        if paths.map(StoredPath.encode) != stored { save() }
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
            paths.append(track.url.path)
            changed = true
        }

        if changed { save() }
    }

    func remove(_ tracks: [Track]) {
        let removed = Set(tracks.map(\.url.path))
        guard !removed.isEmpty, !liked.isDisjoint(with: removed) else { return }

        paths.removeAll { removed.contains($0) }
        liked.subtract(removed)
        save()
    }

    private func save() {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(paths.map(StoredPath.encode)) else { return }

        Persist.write(data, to: file)
    }
}
