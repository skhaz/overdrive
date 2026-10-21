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

    @Test @MainActor func likesStoreHomeRelativePaths() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "Likes.plist")
        let path = StoredPath.home + "/Music/Library/Song.flac"
        let track = Track(url: URL(filePath: path), title: "Song", artist: "Artist", album: "Album", number: 1, disc: 1,
                          albumArtist: "Artist", year: 2020, duration: 100, albumID: "Album")
        let likes = Likes(file: file)
        likes.add([track])
        Persist.flush()

        let stored = try PropertyListDecoder().decode([String].self, from: Data(contentsOf: file))
        #expect(stored == ["~/Music/Library/Song.flac"])
        #expect(Likes(file: file).paths == [path])
    }
}
