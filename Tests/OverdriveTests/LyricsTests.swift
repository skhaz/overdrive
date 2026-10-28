import AppKit
import CoreServices
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
        Lyrics(drafts: folder.appending(path: "Drafts.plist"))
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    @Test func readsTheSavedLyricsWithoutFetching() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("[00:01.00]Hello".utf8).write(to: folder.appending(path: "Song.lyrics"))

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
        try Data("[00:01.00]Hello".utf8).write(to: folder.appending(path: "Song.lyrics"))

        let lyrics = Lyrics(enabled: false)
        lyrics.show(track)

        #expect(lyrics.track == nil, "hidden lyrics must not read the disk or the internet")
        #expect(lyrics.text.isEmpty)
        #expect(lyrics.loading == false)
        #expect(!FileManager.default.fileExists(atPath: Lyrics.key(track).path), "hidden lyrics must not write a cache file")
    }

    @Test func hidingSavesThePendingEditAndStops() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("[00:01.00]Hello".utf8).write(to: folder.appending(path: "Song.lyrics"))

        let lyrics = lyrics(folder)
        lyrics.show(track)
        lyrics.floating = true
        lyrics.edit("[00:02.00]Changed")
        lyrics.enabled = false
        Persist.flush()

        #expect(read(folder.appending(path: "Song.lyrics")) == "[00:02.00]Changed")
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
        try Data("[00:01.00]Hello".utf8).write(to: folder.appending(path: "Song.lyrics"))

        let lyrics = lyrics(folder)
        lyrics.show(track)
        lyrics.edit("[00:02.00]Changed")

        try await Task.sleep(for: .seconds(1.5))
        Persist.flush()

        #expect(read(folder.appending(path: "Song.lyrics")) == "[00:02.00]Changed")
        #expect(read(Lyrics.key(track)) == "[00:02.00]Changed")
    }

    @Test func everyEditIsOnTheDiskAtOnce() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        let lyrics = lyrics(folder)
        lyrics.show(track)

        lyrics.edit("a")
        lyrics.wait()

        #expect(read(folder.appending(path: "Song.lyrics")) == "a", "a crash right after an edit must not lose it: there is no delay before the write")
        #expect(read(Lyrics.key(track)) == "a")
    }

    @Test func fastEditsEndWithTheLastText() async throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        let lyrics = lyrics(folder)
        lyrics.show(track)

        var text = ""
        for index in 0..<200 {
            text += "\(index % 10)"
            lyrics.edit(text)
        }
        lyrics.wait()
        try await Task.sleep(for: .milliseconds(200))

        #expect(read(folder.appending(path: "Song.lyrics")) == text)
        #expect(lyrics.saved == text, "a coalesced write must report the text it wrote")
        #expect(!lyrics.modified)
    }

    @Test func aFailedWriteKeepsADraftUntilTheSongCanBeWritten() async throws {
        let folder = try folder()
        let music = folder.appending(path: "Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let drafts = folder.appending(path: "Drafts.plist")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: music.path)
            Persist.flush()
            try? FileManager.default.removeItem(at: folder)
        }
        let track = track(music)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: music.path)

        let first = Lyrics(drafts: drafts)
        first.show(track)
        first.edit("kept")
        first.flush()

        #expect(read(music.appending(path: "Song.lyrics")) == nil)
        #expect(first.modified, "a failed write must not look saved")
        #expect(Persist.read([String: String].self, from: drafts)?[StoredPath.encode(track.url.path)] == "kept", "a failed write must keep the edit in a draft")

        let second = Lyrics(drafts: drafts)
        second.show(track)
        #expect(second.text == "kept", "the draft comes back on the next launch")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: music.path)
        second.flush()
        try await Task.sleep(for: .milliseconds(100))

        #expect(read(music.appending(path: "Song.lyrics")) == "kept")
        #expect(!FileManager.default.fileExists(atPath: drafts.path), "a draft leaves once the song file has it")
        #expect(!second.modified)
    }

    @Test func discardingPutsBackTheLyricTheFileHas() async throws {
        let folder = try folder()
        let music = folder.appending(path: "Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let drafts = folder.appending(path: "Drafts.plist")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: music.path)
            Persist.flush()
            try? FileManager.default.removeItem(at: folder)
        }
        let track = track(music)
        try Data("saved".utf8).write(to: music.appending(path: "Song.lyrics"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: music.path)

        let lyrics = Lyrics(drafts: drafts)
        lyrics.show(track)
        lyrics.edit("thrown away")
        lyrics.flush()

        #expect(lyrics.modified, "the write is not on the disk")
        #expect(Persist.read([String: String].self, from: drafts)?[StoredPath.encode(track.url.path)] == "thrown away")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: music.path)
        lyrics.discard()

        #expect(lyrics.text == "saved", "discard puts back the lyric the file has")
        #expect(!lyrics.modified)
        #expect(read(music.appending(path: "Song.lyrics")) == "saved")
        #expect(!FileManager.default.fileExists(atPath: drafts.path), "and the draft of the thrown edit leaves")
    }

    @Test func theSaveCommandAndThePromptAreWired() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive")
        let app = try String(contentsOf: root.appending(path: "Overdrive.swift"), encoding: .utf8)

        #expect(app.contains("Button(\"Save Lyrics\", systemImage: \"square.and.arrow.down\")"))
        #expect(app.contains(".keyboardShortcut(\"s\")"), "Command-S saves the lyrics at once")

        for name in ["Views.swift", "LyricsPanel.swift"] {
            let view = try String(contentsOf: root.appending(path: name), encoding: .utf8)
            #expect(view.contains("Button(\"Discard\", role: .destructive) { lyrics.discard(); editing = false }"), "\(name) asks before an edit is lost")
            #expect(view.contains("Button(\"Save\") { lyrics.flush(); editing = false }"))
        }
    }

    @Test func flushSavesAtOnce() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("old".utf8).write(to: folder.appending(path: "Song.lyrics"))

        let lyrics = lyrics(folder)
        lyrics.show(track)
        lyrics.edit("new")
        lyrics.flush()
        Persist.flush()

        #expect(read(folder.appending(path: "Song.lyrics")) == "new")
    }

    @Test func settleSavesBeforeTheAction() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("old".utf8).write(to: folder.appending(path: "Song.lyrics"))

        let lyrics = lyrics(folder)
        lyrics.show(track)
        lyrics.edit("new")

        lyrics.settle {
            Persist.flush()
            #expect(read(folder.appending(path: "Song.lyrics")) == "new")
        }
    }

    @Test func deletingAllTextRemovesTheLyrics() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("old".utf8).write(to: folder.appending(path: "Song.lyrics"))

        let lyrics = lyrics(folder)
        lyrics.show(track)
        lyrics.edit("")
        lyrics.flush()
        Persist.flush()

        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Song.lyrics").path))
        #expect(!FileManager.default.fileExists(atPath: Lyrics.key(track).path))
    }

    @Test func aCachedLyricIsRemoteAndAnEditSavesItNextToTheSong() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        let lyrics = lyrics(folder)
        try Data("downloaded".utf8).write(to: Lyrics.key(track))

        lyrics.show(track)

        #expect(lyrics.text == "downloaded")
        #expect(lyrics.remote)
        #expect(lyrics.loading == false)

        lyrics.edit("downloaded, kept")
        lyrics.flush()
        Persist.flush()

        #expect(read(folder.appending(path: "Song.lyrics")) == "downloaded, kept")
        #expect(lyrics.remote == false)
    }

    @Test func showSwitchesTracksAndKeepsThePendingSaveOnItsOwnSong() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let first = track(folder, "First")
        let second = track(folder, "Second")
        try Data("first-old".utf8).write(to: folder.appending(path: "First.lyrics"))
        try Data("second-old".utf8).write(to: folder.appending(path: "Second.lyrics"))

        let lyrics = lyrics(folder)
        lyrics.show(first)
        lyrics.edit("first-new")
        lyrics.show(second)

        #expect(read(folder.appending(path: "First.lyrics")) == "first-new")
        #expect(lyrics.text == "second-old")
        #expect(read(folder.appending(path: "Second.lyrics")) == "second-old")
    }

    @Test func theCacheLivesNextToTheSong() throws {
        let folder = try folder()
        let track = track(folder, "01 Song")

        #expect(Lyrics.key(track) == folder.appending(path: "01 Song.cache.lyrics"), "the cache has the name of the song and its own extension")
        #expect(!Library.relevant([(path: folder.appending(path: "01 Song.lyrics.tmp").path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed))]), "a lyrics write must never start a scan")
        #expect(!Library.relevant([(path: folder.appending(path: "01 Song.cache.lyrics").path, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved))]))
    }

    @Test func keptLyricsUseTheLyricsExtension() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("old format".utf8).write(to: folder.appending(path: "Song.lrc"))
        try Data("cached".utf8).write(to: Lyrics.key(track))

        let lyrics = lyrics(folder)
        lyrics.show(track)
        #expect(lyrics.text == "cached", "the app reads the .lyrics files, never an old .lrc")

        lyrics.save("kept", for: track)
        Persist.flush()
        #expect(read(folder.appending(path: "Song.lyrics")) == "kept", "lyrics the user keeps go to <song>.lyrics")
        #expect(read(folder.appending(path: "Song.lrc")) == "old format", "the app never touches an old .lrc")
    }

    @Test func theCacheIsValidForOneMonth() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Song.cache.lyrics")
        try Data("cached".utf8).write(to: file)
        let now = Date()

        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-29 * 86400)], ofItemAtPath: file.path)
        #expect(!Lyrics.isCacheStale(file, at: now))

        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 86400)], ofItemAtPath: file.path)
        #expect(Lyrics.isCacheStale(file, at: now))
    }

    @Test func aFreshCacheNeverAsksTheInternet() async throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        try Data("cached".utf8).write(to: Lyrics.key(track))

        let result = await Lyrics.lookup(track, fetch: { _ in Issue.record("no request for a fresh cache"); return .success("new") }, ovh: { _ in nil })
        #expect(try result.get() == "cached")
    }

    @Test func anExpiredCacheIsUpdatedOnlyByANewLyric() async throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        let file = Lyrics.key(track)
        let old = Date().addingTimeInterval(-40 * 86400)

        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let empty = await Lyrics.lookup(track, fetch: { _ in .success("") }, ovh: { _ in nil })
        Persist.flush()
        #expect(try empty.get() == "old", "an empty answer keeps the old lyric")
        #expect(read(file) == "old")

        let failed = await Lyrics.lookup(track, fetch: { _ in .failure(.offline) }, ovh: { _ in nil })
        Persist.flush()
        #expect(try failed.get() == "old", "a failed refresh keeps the old lyric")
        #expect(read(file) == "old")
        #expect(Lyrics.isCacheStale(file), "the old lyric stays expired, so the next show tries again")

        let fresh = await Lyrics.lookup(track, fetch: { _ in .success("new") }, ovh: { _ in nil })
        Persist.flush()
        #expect(try fresh.get() == "new")
        #expect(read(file) == "new", "a new lyric replaces the file")
        #expect(!Lyrics.isCacheStale(file), "the new lyric is valid for one more month")

        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let fallback = await Lyrics.lookup(track, fetch: { _ in .success("") }, ovh: { _ in "from ovh" })
        Persist.flush()
        #expect(try fallback.get() == "from ovh")
        #expect(read(file) == "from ovh")
    }

    @Test func aCancelledLookupStopsAtOnce() async throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        let track = track(folder)
        let file = Lyrics.key(track)
        try Data("old".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: file.path)

        let result = await Lyrics.lookup(track, fetch: { _ in .failure(.cancelled) }, ovh: { _ in Issue.record("a cancelled lookup must not try another site"); return "x" })
        Persist.flush()

        guard case .failure(.cancelled) = result else {
            Issue.record("expected cancelled, got \(result)")
            return
        }
        #expect(read(file) == "old")
    }

    @Test func aCancelledRequestIsNotAFailure() {
        #expect(Lyrics.cancelled(URLError(.cancelled)))
        #expect(Lyrics.cancelled(CancellationError()))
        #expect(!Lyrics.cancelled(URLError(.notConnectedToInternet)), "offline still retries")
    }
}

@MainActor
struct SyncedLyricsScrollTests {
    @Test func aNewSongOrARepeatScrollsToTheTop() {
        let text = LyricsTextView(usingTextLayoutManager: false)
        text.isVerticallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scroll.documentView = text
        let coordinator = SyncedLyrics.Coordinator()
        coordinator.text = text
        let lines = (0..<100).map { SyncedLine(time: Double($0 + 1), text: "Line \($0)") }

        coordinator.load(lines, current: 99)
        text.setFrameSize(NSSize(width: 200, height: 3000))
        coordinator.center(animated: false)
        #expect(scroll.contentView.bounds.origin.y > 0)

        coordinator.highlight(nil)
        coordinator.center(animated: false)
        #expect(scroll.contentView.bounds.origin.y == 0, "the lyrics stayed at the end when the song started again")
    }
}
