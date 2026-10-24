import Foundation
import Testing
@testable import Overdrive

private let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")

private final class Box: @unchecked Sendable {
    var value: URL
    init(_ value: URL) { self.value = value }
}

@Suite(.serialized) struct DataSafetyTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "DataSafety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(filePath: url.path.withCString { String(cString: realpath($0, nil)) })
    }

    private func track(_ url: URL) -> Track {
        Track(url: url, title: url.lastPathComponent, artist: "A", album: "B", number: 1, disc: 1, albumArtist: "", year: 2000, duration: 100, albumID: "B")
    }

    @Test @MainActor func likesKeepAbsolutePathsAndSaveRelativeOnes() throws {
        let root = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: root) }

        let file = root.appending(path: "Likes.plist")
        let likes = Likes(file: file, folder: root)
        likes.add([track(root.appending(path: "a.mp3"))])
        likes.add([track(root.appending(path: "b.mp3"))])
        Persist.flush()

        #expect(likes.paths == [root.appending(path: "a.mp3").path, root.appending(path: "b.mp3").path], "the list in memory holds only absolute paths")
        #expect(Persist.read([String].self, from: file) == ["a.mp3", "b.mp3"], "the file holds paths relative to the music folder")
    }

    @Test @MainActor func likesAndPlaylistsFollowANewMusicFolder() throws {
        let first = try folder(), second = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }

        let current = Box(first)
        let likes = Likes(file: { Likes.file(in: current.value) }, folder: { current.value })
        let playlists = Playlists(directory: { Playlists.directory(in: current.value) }, folder: { current.value })
        likes.add([track(first.appending(path: "a.mp3"))])
        playlists.create("Mix", [first.appending(path: "a.mp3")])
        Persist.flush()

        current.value = second
        likes.load()
        playlists.load()
        #expect(likes.paths.isEmpty && playlists.names.isEmpty, "a new music folder has its own likes and playlists")

        likes.add([track(second.appending(path: "c.mp3"))])
        Persist.flush()
        #expect(Persist.read([String].self, from: Likes.file(in: second)) == ["c.mp3"], "paths are relative to the new folder, not the old one")
    }

    @Test @MainActor func playlistsKeepAbsolutePathsAndSaveRelativeOnes() throws {
        let root = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: root) }

        let playlists = Playlists(directory: Playlists.directory(in: root), folder: root)
        playlists.create("Mix", [root.appending(path: "a.mp3")])
        playlists.add([root.appending(path: "b.mp3"), root.appending(path: "a.mp3")], to: "Mix")
        Persist.flush()

        #expect(playlists.paths["Mix"] == [root.appending(path: "a.mp3").path, root.appending(path: "b.mp3").path])
        #expect(Persist.read([String].self, from: Playlists.directory(in: root).appending(path: "Mix.plist")) == ["a.mp3", "b.mp3"])
    }

    @Test func aBrokenFileIsReportedNotHidden() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }

        let records = logRecords
        let missing = root.appending(path: "missing.plist").path

        #expect(Persist.read([String].self, from: URL(filePath: missing)) == nil)
        #expect(!records.find("persist", "decode failed", "path", missing) && !records.find("persist", "read failed", "path", missing), "a missing file is normal")

        try Data("not a plist".utf8).write(to: root.appending(path: "broken.plist"))
        #expect(Persist.read([String].self, from: root.appending(path: "broken.plist")) == nil)
        #expect(records.find("persist", "decode failed", "path", root.appending(path: "broken.plist").path), "a broken data file must leave a trace before the app replaces it")
    }

    @Test func anUnreadableFolderKeepsItsSongs() async throws {
        let root = try folder()
        let locked = root.appending(path: "A")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appending(path: "cbr.mp3"), to: locked.appending(path: "one.mp3"))
        try FileManager.default.copyItem(at: fixtures.appending(path: "vbr.mp3"), to: root.appending(path: "two.mp3"))
        let first = await Library.load([root], [:])
        #expect(first.albums.flatMap(\.tracks).count == 2)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let second = await Library.load([root], [:])

        #expect(second.albums.flatMap(\.tracks).count == 2, "a folder that cannot be read must not look empty")
        #expect(Cache(root)!.entries().count == 2, "the cache keeps the songs it cannot see")
    }
}
