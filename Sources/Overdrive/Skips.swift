import Foundation
import Logging

/// The songs the discovery never picks again. It is the user's own veto, so it
/// is kept with the rest of the collection, in `Skip.plist` at the root of the
/// first library folder, with the paths relative to that folder: a folder that
/// moves keeps its denials, and a drive that is not mounted loses nothing.
///
/// The list is a deny only for the pickers that ask the internet (`Discovery`
/// and `Infinity`): a song that is denied stays in the library, in every list,
/// and plays when the user chooses it.
@Observable
final class Skips {
    nonisolated static func file(in folder: URL?) -> URL {
        (folder ?? URL.homeDirectory.appending(path: "Music/Library", directoryHint: .isDirectory))
            .appending(path: "Skip.plist", directoryHint: .notDirectory)
    }

    private(set) var paths: [String] = []

    @ObservationIgnored private let location: () -> URL
    @ObservationIgnored private let folder: () -> URL?
    private var denied: Set<String> = []

    init(file: URL, folder: URL) {
        self.location = { file }
        self.folder = { folder }
        load()
    }

    init(file: @escaping () -> URL, folder: @escaping () -> URL?) {
        self.location = file
        self.folder = folder
        load()
    }

    private var folderPath: String { folder().map(Library.real) ?? "" }

    var count: Int { paths.count }

    func load() {
        let base = folderPath
        let stored = Persist.read([String].self, from: location()) ?? []
        var seen: Set<String> = []
        seen.reserveCapacity(stored.count)

        paths = stored.map { StoredPath.decode($0, relativeTo: base) }.filter { seen.insert($0).inserted }
        denied = seen
        Log.skips.info("load", metadata: ["file": "\(location().path)", "songs": "\(paths.count)"])
    }

    func contains(_ track: Track) -> Bool {
        denied.contains(track.url.path)
    }

    /// The veto is one-way by hand and reversible by hand: the same menu item
    /// that denies a song gives it back, so nothing is lost forever by a click.
    func toggle(_ tracks: [Track]) {
        tracks.allSatisfy(contains) ? remove(tracks) : add(tracks)
    }

    func add(_ tracks: [Track]) {
        Log.skips.info("add", metadata: metadata(tracks))
        var saved = false

        for track in tracks where denied.insert(track.url.path).inserted {
            paths.append(track.url.path)
            saved = true
        }

        guard saved else { return Log.skips.debug("add skipped", metadata: ["reason": "already denied", "songs": "\(tracks.count)"]) }

        save()
    }

    func remove(_ tracks: [Track]) {
        Log.skips.info("remove", metadata: metadata(tracks))
        let removed = Set(tracks.map(\.url.path))
        guard !removed.isEmpty, !denied.isDisjoint(with: removed) else {
            return Log.skips.debug("remove skipped", metadata: ["reason": "not denied", "songs": "\(tracks.count)"])
        }

        paths.removeAll { removed.contains($0) }
        denied.subtract(removed)
        save()
    }

    /// The songs of a pool that the user has not denied, so every door of a
    /// picker reads this and no path can slip past the veto.
    func allowed(_ tracks: [Track]) -> [Track] {
        guard !denied.isEmpty else { return tracks }

        return tracks.filter { !denied.contains($0.url.path) }
    }

    private func metadata(_ tracks: [Track]) -> Logging.Logger.Metadata {
        Log.paths(tracks.map(\.url.path))
    }

    private func save() {
        guard let folder = folder(), FileManager.default.fileExists(atPath: folder.path) else {
            return Log.skips.error("save skipped", metadata: ["reason": "folder missing", "folder": "\(folder()?.path ?? "")"])
        }

        let base = folderPath
        guard let data = Persist.encode(paths.map { StoredPath.encode($0, relativeTo: base) }, for: location()) else { return }

        Persist.write(data, to: location())
    }
}
