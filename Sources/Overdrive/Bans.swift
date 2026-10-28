import Foundation
import Logging

/// The songs no discovery may pick. It is the user's own ban, so it is kept with
/// the rest of the collection, in `Bans.plist` at the root of the first library
/// folder, with the paths relative to that folder: a folder that moves keeps its
/// bans, and a drive that is not mounted loses nothing.
///
/// The ban holds the pickers of the `Discovery` menu and the `Infinity` mode: a
/// banned song stays in the library, in every list, and plays when the user
/// chooses it.
@Observable
final class Bans {
    nonisolated static func file(in folder: URL?) -> URL {
        (folder ?? URL.homeDirectory.appending(path: "Music/Library", directoryHint: .isDirectory))
            .appending(path: "Bans.plist", directoryHint: .notDirectory)
    }

    private(set) var paths: [String] = []

    @ObservationIgnored private let location: () -> URL
    @ObservationIgnored private let folder: () -> URL?
    private var banned: Set<String> = []

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
        banned = seen
        Log.bans.info("load", metadata: ["file": "\(location().path)", "songs": "\(paths.count)"])
    }

    func contains(_ track: Track) -> Bool {
        banned.contains(track.url.path)
    }

    /// The words of the one item that bans and unbans, in the mouth of the menu
    /// and of the confirmation, so the two cannot drift apart.
    nonisolated static func label(_ count: Int, banned: Bool) -> String {
        (banned ? "Unban " : "Ban ") + (count == 1 ? "Song" : "Songs") + " in Discovery"
    }

    /// The ban is reversible by hand: the same menu item that bans a song gives
    /// it back, so nothing is lost forever by a click.
    func toggle(_ tracks: [Track]) {
        tracks.allSatisfy(contains) ? remove(tracks) : add(tracks)
    }

    func add(_ tracks: [Track]) {
        Log.bans.info("add", metadata: metadata(tracks))
        var saved = false

        for track in tracks where banned.insert(track.url.path).inserted {
            paths.append(track.url.path)
            saved = true
        }

        guard saved else { return Log.bans.debug("add skipped", metadata: ["reason": "already banned", "songs": "\(tracks.count)"]) }

        save()
    }

    func remove(_ tracks: [Track]) {
        Log.bans.info("remove", metadata: metadata(tracks))
        let removed = Set(tracks.map(\.url.path))
        guard !removed.isEmpty, !banned.isDisjoint(with: removed) else {
            return Log.bans.debug("remove skipped", metadata: ["reason": "not banned", "songs": "\(tracks.count)"])
        }

        paths.removeAll { removed.contains($0) }
        banned.subtract(removed)
        save()
    }

    /// The songs of a pool that the user has not banned, so every door of a
    /// picker reads this and no path can slip past the ban.
    func allowed(_ tracks: [Track]) -> [Track] {
        guard !banned.isEmpty else { return tracks }

        return tracks.filter { !banned.contains($0.url.path) }
    }

    private func metadata(_ tracks: [Track]) -> Logging.Logger.Metadata {
        Log.paths(tracks.map(\.url.path))
    }

    private func save() {
        guard let folder = folder(), FileManager.default.fileExists(atPath: folder.path) else {
            return Log.bans.error("save skipped", metadata: ["reason": "folder missing", "folder": "\(folder()?.path ?? "")"])
        }

        let base = folderPath
        guard let data = Persist.encode(paths.map { StoredPath.encode($0, relativeTo: base) }, for: location()) else { return }

        Persist.write(data, to: location())
    }
}
