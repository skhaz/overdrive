import Foundation
import Testing
@testable import Overdrive

@Suite struct LikesTests {
    private func track(_ path: String) -> Track {
        Track(url: URL(filePath: path), title: path, artist: "Artist", album: "Album", number: 1, disc: 1,
              albumArtist: "Artist", year: 2020, duration: 100, albumID: "Album")
    }

    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    @Test @MainActor func persists() {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "Likes.plist")
        let first = track("/Music/a.flac")
        let second = track("/Music/b.flac")
        let likes = Likes(file: file)
        #expect(likes.paths.isEmpty)

        likes.add([first, first, second])
        #expect(likes.paths == [first.url.path, second.url.path])
        #expect(likes.contains(first))
        #expect(likes.contains(second))

        let reloaded = Likes(file: file)
        #expect(reloaded.paths == [first.url.path, second.url.path])

        reloaded.remove([first])
        #expect(reloaded.paths == [second.url.path])
        #expect(!reloaded.contains(first))

        let again = Likes(file: file)
        #expect(again.paths == [second.url.path])
        #expect(again.contains(second))
    }

    @Test @MainActor func toggle() {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }

        let likes = Likes(file: directory.appending(path: "Likes.plist"))
        let first = track("/Music/a.flac")
        let second = track("/Music/b.flac")

        likes.toggle([first])
        #expect(likes.contains(first))

        likes.toggle([first])
        #expect(!likes.contains(first))

        likes.add([first, second])
        likes.toggle([first, second])
        #expect(!likes.contains(first))
        #expect(!likes.contains(second))

        likes.toggle([first, second])
        #expect(likes.contains(first))
        #expect(likes.contains(second))
    }

    @Test @MainActor func deduplicates() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "Likes.plist")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = track("/Music/a.flac")
        let encoder = PropertyListEncoder()
        let data = try encoder.encode([first.url.path, first.url.path])
        try data.write(to: file)

        let likes = Likes(file: file)
        #expect(likes.paths == [first.url.path])
    }
}
