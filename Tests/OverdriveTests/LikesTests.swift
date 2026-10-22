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
        let folder = directory.appending(path: "Music/Library")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = track(folder.appending(path: "a.flac").path)
        let second = track(folder.appending(path: "b.flac").path)
        let likes = Likes(file: file, folderPath: folder.path)
        #expect(likes.paths.isEmpty)

        likes.add([first, first, second])
        #expect(likes.paths == [first.url.path, second.url.path])
        #expect(likes.contains(first))
        #expect(likes.contains(second))

        Persist.flush()
        let reloaded = Likes(file: file, folderPath: folder.path)
        #expect(reloaded.paths == [first.url.path, second.url.path])

        reloaded.remove([first])
        #expect(reloaded.paths == [second.url.path])
        #expect(!reloaded.contains(first))

        Persist.flush()
        let again = Likes(file: file, folderPath: folder.path)
        #expect(again.paths == [second.url.path])
        #expect(again.contains(second))
    }

    @Test @MainActor func toggle() {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let folder = directory.appending(path: "Music/Library")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let likes = Likes(file: directory.appending(path: "Likes.plist"), folderPath: folder.path)
        let first = track(folder.appending(path: "a.flac").path)
        let second = track(folder.appending(path: "b.flac").path)

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

    @Test @MainActor func followsTheLibraryFolder() throws {
        let first = temporary()
        let second = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }

        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        var folder: URL? = first
        let likes = Likes(file: { Likes.file(in: folder) }, folder: { folder })
        likes.add([track(StoredPath.home + "/Music/a.flac")])
        Persist.flush()
        #expect(FileManager.default.fileExists(atPath: Likes.file(in: first).path))

        folder = second
        likes.add([track(StoredPath.home + "/Music/b.flac")])
        Persist.flush()

        let firstStored = try PropertyListDecoder().decode([String].self, from: Data(contentsOf: Likes.file(in: first)))
        let secondStored = try PropertyListDecoder().decode([String].self, from: Data(contentsOf: Likes.file(in: second)))
        #expect(firstStored == ["~/Music/a.flac"])
        #expect(secondStored == ["~/Music/a.flac", "~/Music/b.flac"])
    }

    @Test @MainActor func storesHomeRelativePaths() throws {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "Likes.plist")
        let folder = directory.appending(path: "Music/Library")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let likes = Likes(file: file, folderPath: folder.path)
        likes.add([track(StoredPath.home + "/Music/a.flac"), track("/Volumes/Music/b.flac")])
        likes.remove([track(StoredPath.home + "/Music/a.flac")])
        likes.add([track(StoredPath.home + "/Music/c.flac")])

        Persist.flush()
        let stored = try PropertyListDecoder().decode([String].self, from: Data(contentsOf: file))
        #expect(stored == ["/Volumes/Music/b.flac", "~/Music/c.flac"])
    }

    @Test @MainActor func deduplicates() throws {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "Likes.plist")
        let folder = directory.appending(path: "Music/Library")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = track(folder.appending(path: "a.flac").path)
        let encoder = PropertyListEncoder()
        let data = try encoder.encode([first.url.path, first.url.path])
        try data.write(to: file)

        let likes = Likes(file: file, folderPath: folder.path)
        #expect(likes.paths == [first.url.path])
    }

    @Test @MainActor func startsEmptyWithoutFile() {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let folder = directory.appending(path: "Music/Library")
        let likes = Likes(file: directory.appending(path: "Likes.plist"), folderPath: folder.path)
        #expect(likes.paths.isEmpty)
        #expect(!likes.contains(track(folder.appending(path: "a.flac").path)))
    }

    @Test @MainActor func removesOnlySelected() {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let folder = directory.appending(path: "Music/Library")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = track(folder.appending(path: "a.flac").path)
        let second = track(folder.appending(path: "b.flac").path)
        let third = track(folder.appending(path: "c.flac").path)
        let likes = Likes(file: directory.appending(path: "Likes.plist"), folderPath: folder.path)
        likes.add([first, second, third])
        likes.remove([second, track(folder.appending(path: "missing.flac").path)])

        #expect(likes.paths == [first.url.path, third.url.path])
        #expect(!likes.contains(second))
    }

    @Test @MainActor func reloadsChangesFromDisk() throws {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let folder = directory.appending(path: "Music/Library")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = directory.appending(path: "Likes.plist")
        let first = track(folder.appending(path: "a.flac").path)
        let second = track(folder.appending(path: "b.flac").path)
        let likes = Likes(file: file, folderPath: folder.path)
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

        let folder = directory.appending(path: "Music/Library")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = track(folder.appending(path: "a.flac").path)
        let second = track(folder.appending(path: "b.flac").path)
        let likes = Likes(file: directory.appending(path: "Likes.plist"), folderPath: folder.path)
        likes.add([first])
        likes.toggle([first, second])

        #expect(likes.paths == [first.url.path, second.url.path])
    }

    @Test @MainActor func recoversFromInvalidFile() throws {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let folder = directory.appending(path: "Music/Library")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = directory.appending(path: "Likes.plist")
        try Data("not a plist".utf8).write(to: file)

        let first = track(folder.appending(path: "a.flac").path)
        let likes = Likes(file: file, folderPath: folder.path)
        #expect(likes.paths.isEmpty)

        likes.add([first])
        Persist.flush()
        #expect(Likes(file: file, folderPath: folder.path).paths == [first.url.path])
    }

    @Test @MainActor func notifiesObserversWhenLikedChanges() {
        let directory = temporary()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let folder = directory.appending(path: "Music/Library")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let likes = Likes(file: directory.appending(path: "Likes.plist"), folder: folder)
        let first = track(folder.appending(path: "a.flac").path)
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
