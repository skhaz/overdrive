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
        let folderPath = folder.resolvingSymlinksInPath().path
        let path = folder.appending(path: "Artist/Album/Song.flac").path
        let resolvedPath = URL(filePath: path).resolvingSymlinksInPath().path
        let track = Track(url: URL(filePath: path).resolvingSymlinksInPath(), title: "Song", artist: "Artist", album: "Album", number: 1, disc: 1,
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

        let folderPath1 = folder1.resolvingSymlinksInPath().path
        let folderPath2 = folder2.resolvingSymlinksInPath().path
        let path1 = folder1.appending(path: "Artist/Album/Song.flac").path
        let track1 = Track(url: URL(filePath: path1).resolvingSymlinksInPath(), title: "Song", artist: "Artist", album: "Album", number: 1, disc: 1,
                           albumArtist: "Artist", year: 2020, duration: 100, albumID: "Album")

        let likes = Likes(file: file, folderPath: folderPath1)
        likes.add([track1])
        Persist.flush()

        let path2 = folder2.appending(path: "Artist/Album/Song.flac").path
        let resolvedPath2 = URL(filePath: path2).resolvingSymlinksInPath().path
        let track2 = Track(url: URL(filePath: path2).resolvingSymlinksInPath(), title: "Song", artist: "Artist", album: "Album", number: 1, disc: 1,
                           albumArtist: "Artist", year: 2020, duration: 100, albumID: "Album")

        let likes2 = Likes(file: file, folderPath: folderPath2)
        #expect(likes2.contains(track2))
    }
}
