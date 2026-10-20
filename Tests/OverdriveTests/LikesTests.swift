import Foundation
import Observation
import Testing
@testable import Overdrive

private final class Counter: @unchecked Sendable {
    var value = 0
}

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
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "Likes.plist")
        let first = track("/Music/a.flac")
        let second = track("/Music/b.flac")
        let likes = Likes(file: file)
        #expect(likes.paths.isEmpty)

        likes.add([first, first, second])
        #expect(likes.paths == [first.url.path, second.url.path])
        #expect(likes.contains(first))
        #expect(likes.contains(second))

        Persist.flush()
        let reloaded = Likes(file: file)
        #expect(reloaded.paths == [first.url.path, second.url.path])

        reloaded.remove([first])
        #expect(reloaded.paths == [second.url.path])
        #expect(!reloaded.contains(first))

        Persist.flush()
        let again = Likes(file: file)
        #expect(again.paths == [second.url.path])
        #expect(again.contains(second))
    }

    @Test @MainActor func toggle() {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

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
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "Likes.plist")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = track("/Music/a.flac")
        let encoder = PropertyListEncoder()
        let data = try encoder.encode([first.url.path, first.url.path])
        try data.write(to: file)

        let likes = Likes(file: file)
        #expect(likes.paths == [first.url.path])
    }

    @Test @MainActor func startsEmptyWithoutFile() {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let likes = Likes(file: directory.appending(path: "Likes.plist"))
        #expect(likes.paths.isEmpty)
        #expect(!likes.contains(track("/Music/a.flac")))
    }

    @Test @MainActor func removesOnlySelected() {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let first = track("/Music/a.flac")
        let second = track("/Music/b.flac")
        let third = track("/Music/c.flac")
        let likes = Likes(file: directory.appending(path: "Likes.plist"))
        likes.add([first, second, third])
        likes.remove([second, track("/Music/missing.flac")])

        #expect(likes.paths == [first.url.path, third.url.path])
        #expect(!likes.contains(second))
    }

    @Test @MainActor func reloadsChangesFromDisk() throws {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "Likes.plist")
        let first = track("/Music/a.flac")
        let second = track("/Music/b.flac")
        let likes = Likes(file: file)
        likes.add([first])

        Persist.flush()
        try PropertyListEncoder().encode([second.url.path]).write(to: file)
        likes.load()

        #expect(likes.paths == [second.url.path])
        #expect(!likes.contains(first))
        #expect(likes.contains(second))
    }

    @Test @MainActor func likesEveryMissingTrackFromMixedSelection() {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let first = track("/Music/a.flac")
        let second = track("/Music/b.flac")
        let likes = Likes(file: directory.appending(path: "Likes.plist"))
        likes.add([first])
        likes.toggle([first, second])

        #expect(likes.paths == [first.url.path, second.url.path])
    }

    @Test @MainActor func recoversFromInvalidFile() throws {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "Likes.plist")
        try Data("not a plist".utf8).write(to: file)

        let first = track("/Music/a.flac")
        let likes = Likes(file: file)
        #expect(likes.paths.isEmpty)

        likes.add([first])
        Persist.flush()
        #expect(Likes(file: file).paths == [first.url.path])
    }

    @Test @MainActor func notifiesObserversWhenLikedChanges() {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let likes = Likes(file: directory.appending(path: "Likes.plist"))
        let first = track("/Music/a.flac")
        let counter = Counter()

        withObservationTracking {
            _ = likes.contains(first)
        } onChange: {
            counter.value += 1
        }

        likes.add([first])
        #expect(counter.value > 0)
    }
}
