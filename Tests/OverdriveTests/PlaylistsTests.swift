import Foundation
import Testing
@testable import Overdrive

@Suite struct PlaylistsTests {
    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    @Test @MainActor func followsTheLibraryFolder() throws {
        let first = temporary()
        let second = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        var folder: URL? = first
        let playlists = Playlists(directory: { Playlists.directory(in: folder) })
        _ = playlists.create("One", [URL(filePath: StoredPath.home + "/Music/a.flac")])
        Persist.flush()
        #expect(FileManager.default.fileExists(atPath: Playlists.directory(in: first).appending(path: "One.plist").path))

        folder = second
        _ = playlists.create("Two", [URL(filePath: StoredPath.home + "/Music/b.flac")])
        Persist.flush()
        #expect(FileManager.default.fileExists(atPath: Playlists.directory(in: second).appending(path: "Two.plist").path))
        #expect(!FileManager.default.fileExists(atPath: Playlists.directory(in: first).appending(path: "Two.plist").path))
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

    @Test @MainActor func rejectsBackupNames() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let playlists = Playlists(directory: directory)
        #expect(playlists.create("Mix.backup", [URL(filePath: StoredPath.home + "/Music/a.flac")]) == nil)
        #expect(playlists.names.isEmpty)
    }
}
