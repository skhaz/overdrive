import Foundation
import Testing
@testable import Overdrive

@Suite struct StoredPathTests {
    @Test func encodesHomePaths() {
        let path = StoredPath.home + "/Music/Library/Song.flac"

        #expect(StoredPath.encode(path) == "~/Music/Library/Song.flac")
        #expect(StoredPath.decode("~/Music/Library/Song.flac") == path)
    }

    @Test func keepsPathsOutsideHome() {
        let path = "/Volumes/Music/Song.flac"

        #expect(StoredPath.encode(path) == path)
        #expect(StoredPath.decode(path) == path)
    }

    @Test func encodesHome() {
        #expect(StoredPath.encode(StoredPath.home) == "~")
        #expect(StoredPath.decode("~") == StoredPath.home)
    }

    @Test func encodesRelativeToFolder() {
        let folder = URL(filePath: "/Users/test/Music/Library").resolvingSymlinksInPath().path
        let path = "/Users/test/Music/Library/Artist/Album/Song.flac"

        #expect(StoredPath.encode(path, relativeTo: folder) == "Artist/Album/Song.flac")
        #expect(StoredPath.decode("Artist/Album/Song.flac", relativeTo: folder) == path)
    }

    @Test func encodesFolderRoot() {
        let folder = URL(filePath: "/Users/test/Music/Library").resolvingSymlinksInPath().path

        #expect(StoredPath.encode(folder, relativeTo: folder) == ".")
        #expect(StoredPath.decode(".", relativeTo: folder) == folder)
    }

    @Test @MainActor func likesStoreRelativeToFolder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "Likes.plist")
        let folder = directory.appending(path: "Music/Library")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderPath = Library.real(folder)
        let resolvedPath = folderPath + "/Artist/Album/Song.flac"
        let track = Track(url: URL(filePath: resolvedPath), title: "Song", artist: "Artist", album: "Album", number: 1, disc: 1,
                          albumArtist: "Artist", year: 2020, duration: 100, albumID: "Album")
        let likes = Likes(file: file, folderPath: folderPath)
        likes.add([track])
        Persist.flush()

        let stored = try PropertyListDecoder().decode([String].self, from: Data(contentsOf: file))
        #expect(stored == ["Artist/Album/Song.flac"])
        #expect(Likes(file: file, folderPath: folderPath).paths == [resolvedPath])
    }

    @Test @MainActor func likesSurviveFolderMove() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "Likes.plist")
        let folder1 = directory.appending(path: "Music/Library")
        let folder2 = directory.appending(path: "Documents/Music")

        try FileManager.default.createDirectory(at: folder1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)

        let folderPath1 = Library.real(folder1)
        let folderPath2 = Library.real(folder2)
        let track1 = Track(url: URL(filePath: folderPath1 + "/Artist/Album/Song.flac"), title: "Song", artist: "Artist", album: "Album", number: 1, disc: 1,
                           albumArtist: "Artist", year: 2020, duration: 100, albumID: "Album")

        let likes = Likes(file: file, folderPath: folderPath1)
        likes.add([track1])
        Persist.flush()

        let track2 = Track(url: URL(filePath: folderPath2 + "/Artist/Album/Song.flac"), title: "Song", artist: "Artist", album: "Album", number: 1, disc: 1,
                           albumArtist: "Artist", year: 2020, duration: 100, albumID: "Album")

        let likes2 = Likes(file: file, folderPath: folderPath2)
        #expect(likes2.contains(track2))
    }
}
