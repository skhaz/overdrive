import Foundation
import Testing
@testable import Overdrive

@MainActor
@Suite struct LyricsTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OverdriveLyrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func track(_ folder: URL, _ name: String = "Song") -> Track {
        Track(url: folder.appending(path: name + ".mp3"), title: "Title", artist: "Artist", album: "Album", number: 1, disc: 1,
              albumArtist: "Artist", year: 2020, duration: 100, albumID: "Album")
    }

    private func lyrics(_ folder: URL) -> Lyrics {
        Lyrics(cache: folder.appending(path: "cache"))
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    @Test func readsTheSavedLyricsWithoutFetching() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("[00:01.00]Hello".utf8).write(to: folder.appending(path: "Song.lrc"))

        let lyrics = lyrics(folder)
        lyrics.show(track)

        #expect(lyrics.text == "[00:01.00]Hello")
        #expect(lyrics.remote == false)
        #expect(lyrics.loading == false)
        #expect(lyrics.synced.count == 1)
    }

    @Test func hiddenLyricsDoNothing() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("[00:01.00]Hello".utf8).write(to: folder.appending(path: "Song.lrc"))

        let lyrics = Lyrics(cache: folder.appending(path: "cache"), enabled: false)
        lyrics.show(track)

        #expect(lyrics.track == nil, "hidden lyrics must not read the disk or the internet")
        #expect(lyrics.text.isEmpty)
        #expect(lyrics.loading == false)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "cache").path), "hidden lyrics must not create the cache folder")
    }

    @Test func hidingSavesThePendingEditAndStops() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("[00:01.00]Hello".utf8).write(to: folder.appending(path: "Song.lrc"))

        let lyrics = lyrics(folder)
        lyrics.show(track)
        lyrics.floating = true
        lyrics.edit("[00:02.00]Changed")
        lyrics.enabled = false
        Persist.flush()

        #expect(read(folder.appending(path: "Song.lrc")) == "[00:02.00]Changed")
        #expect(lyrics.track == nil)
        #expect(lyrics.text.isEmpty)
        #expect(lyrics.floating == false)

        lyrics.enabled = true
        lyrics.show(track)
        #expect(lyrics.text == "[00:02.00]Changed")
    }

    @Test func editAutoSavesNextToTheSong() async throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("[00:01.00]Hello".utf8).write(to: folder.appending(path: "Song.lrc"))

        let lyrics = lyrics(folder)
        lyrics.show(track)
        lyrics.edit("[00:02.00]Changed")

        try await Task.sleep(for: .seconds(1.5))
        Persist.flush()

        #expect(read(folder.appending(path: "Song.lrc")) == "[00:02.00]Changed")
        #expect(read(lyrics.key(track)) == "[00:02.00]Changed")
    }

    @Test func flushSavesAtOnce() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("old".utf8).write(to: folder.appending(path: "Song.lrc"))

        let lyrics = lyrics(folder)
        lyrics.show(track)
        lyrics.edit("new")
        lyrics.flush()
        Persist.flush()

        #expect(read(folder.appending(path: "Song.lrc")) == "new")
    }

    @Test func settleSavesBeforeTheAction() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("old".utf8).write(to: folder.appending(path: "Song.lrc"))

        let lyrics = lyrics(folder)
        lyrics.show(track)
        lyrics.edit("new")

        lyrics.settle {
            Persist.flush()
            #expect(read(folder.appending(path: "Song.lrc")) == "new")
        }
    }

    @Test func deletingAllTextRemovesTheLyrics() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("old".utf8).write(to: folder.appending(path: "Song.lrc"))

        let lyrics = lyrics(folder)
        lyrics.show(track)
        lyrics.edit("")
        lyrics.flush()
        Persist.flush()

        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Song.lrc").path))
        #expect(!FileManager.default.fileExists(atPath: lyrics.key(track).path))
    }

    @Test func aCachedLyricIsRemoteAndPersistSavesItNextToTheSong() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        let lyrics = lyrics(folder)
        try FileManager.default.createDirectory(at: lyrics.key(track).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("downloaded".utf8).write(to: lyrics.key(track))

        lyrics.show(track)

        #expect(lyrics.text == "downloaded")
        #expect(lyrics.remote)
        #expect(lyrics.loading == false)

        lyrics.persist()
        Persist.flush()

        #expect(read(folder.appending(path: "Song.lrc")) == "downloaded")
        #expect(lyrics.remote == false)
    }

    @Test func showSwitchesTracksAndKeepsThePendingSaveOnItsOwnSong() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let first = track(folder, "First")
        let second = track(folder, "Second")
        try Data("first-old".utf8).write(to: folder.appending(path: "First.lrc"))
        try Data("second-old".utf8).write(to: folder.appending(path: "Second.lrc"))

        let lyrics = lyrics(folder)
        lyrics.show(first)
        lyrics.edit("first-new")
        lyrics.show(second)

        #expect(read(folder.appending(path: "First.lrc")) == "first-new")
        #expect(lyrics.text == "second-old")
        #expect(read(folder.appending(path: "Second.lrc")) == "second-old")
    }
}
