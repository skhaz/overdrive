import Foundation
import Testing
@testable import Overdrive

@Suite struct PlaylistsTests {
    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    @Test @MainActor func writesPlists() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let playlists = Playlists(directory: directory)
        let home = URL(filePath: StoredPath.home + "/Music/a.flac")
        let outside = URL(filePath: "/Volumes/Music/b.flac")
        #expect(playlists.create("Metal", [home, outside]) == "Metal")

        let file = directory.appending(path: "Metal.plist")
        let stored = try PropertyListDecoder().decode([String].self, from: Data(contentsOf: file))
        #expect(stored == ["~/Music/a.flac", "/Volumes/Music/b.flac"])

        let reloaded = Playlists(directory: directory)
        #expect(reloaded.paths["Metal"] == [home.path, outside.path])
    }

    @Test @MainActor func migratesTextPlaylists() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let legacy = directory.appending(path: "Old.playlist")
        let text = [StoredPath.home + "/Music/a.flac", "~/Music/b.flac", "/Volumes/Music/c.flac"].joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: legacy)

        let playlists = Playlists(directory: directory)
        #expect(playlists.paths["Old"] == [StoredPath.home + "/Music/a.flac", StoredPath.home + "/Music/b.flac", "/Volumes/Music/c.flac"])
        #expect(!FileManager.default.fileExists(atPath: legacy.path))

        let file = directory.appending(path: "Old.plist")
        let stored = try PropertyListDecoder().decode([String].self, from: Data(contentsOf: file))
        #expect(stored == ["~/Music/a.flac", "~/Music/b.flac", "/Volumes/Music/c.flac"])
    }

    @Test @MainActor func skipsBackups() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let playlists = Playlists(directory: directory)
        _ = playlists.create("Mix", [URL(filePath: StoredPath.home + "/Music/a.flac")])
        playlists.delete("Mix")

        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "Mix.backup.plist").path))
        #expect(Playlists(directory: directory).names.isEmpty)
    }
}
