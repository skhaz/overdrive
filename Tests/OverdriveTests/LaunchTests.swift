import Foundation
import Testing
@testable import Overdrive

private let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")

/// The launch: the library, the queue, and the loudness are whole before the
/// window draws, and an unchanged library is drawn once.
@MainActor
@Suite(.serialized)
struct LaunchTests {
    private final class Calls {
        var loaded: [Bool] = []
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OverdriveLaunch-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(filePath: url.path.withCString { String(cString: realpath($0, nil)) })
    }

    private func put(_ folder: URL, _ path: String) throws {
        let target = folder.appending(path: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appending(path: "cbr.mp3"), to: target)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: target.path)
    }

    private func paths(_ library: Library) -> Set<String> {
        Set(library.albums.flatMap(\.tracks).map(\.url.path))
    }

    private func settle(_ library: Library, sourceLocation: SourceLocation = #_sourceLocation) async {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(30)
        while clock.now < end {
            if library.settled, !library.scanning { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("the scan never ended", sourceLocation: sourceLocation)
    }

    /// A library that ran once, so its folder holds a cache.
    private func cached(_ folder: URL) async {
        let library = Library(loudness: Loudness(), folders: [folder])
        await settle(library)
    }

    @Test func theLibraryIsWholeWhenTheLaunchReturns() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Band/Album/01 - One.mp3")
        try put(folder, "Band/Album/02 - Two.mp3")
        await cached(folder)

        let calls = Calls()
        let library = Library(loudness: Loudness(), folders: [folder], launch: true)
        library.loaded = { calls.loaded.append($0) }
        #expect(library.albums.isEmpty, "nothing shows before the launch asks for it")

        library.open()
        #expect(paths(library) == [folder.path + "/Band/Album/01 - One.mp3", folder.path + "/Band/Album/02 - Two.mp3"], "the songs are there the moment open returns, before any frame")
        #expect(calls.loaded == [false], "the player restores before the window draws")
        #expect(library.scans == 1)

        await settle(library)
        #expect(library.scans == 1, "an unchanged library is drawn once: the scan that follows ends without a redraw")
        #expect(calls.loaded == [false, true], "the scan still ends, so the loved tracks and the rest run")
    }

    @Test func aSongAddedWhileTheAppWasClosedShowsOnTheLaunchScan() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Band/Album/01 - One.mp3")
        await cached(folder)
        try put(folder, "Band/Album/02 - Two.mp3")

        let library = Library(loudness: Loudness(), folders: [folder], launch: true)
        library.open()
        #expect(paths(library) == [folder.path + "/Band/Album/01 - One.mp3"], "the first frame shows what the cache holds")

        await settle(library)
        #expect(paths(library) == [folder.path + "/Band/Album/01 - One.mp3", folder.path + "/Band/Album/02 - Two.mp3"], "the walk brings the new song in")
        #expect(Set(Cache(folder)?.entries().values.map(\.track.url.path) ?? []) == paths(library), "and the cache holds it")
    }

    @Test func aLaunchWithoutACacheScansTheFolder() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Band/Album/01 - One.mp3")

        let calls = Calls()
        let library = Library(loudness: Loudness(), folders: [folder], launch: true)
        library.loaded = { calls.loaded.append($0) }
        library.open()
        #expect(library.albums.isEmpty, "a first launch has nothing cached to show")

        await settle(library)
        #expect(paths(library) == [folder.path + "/Band/Album/01 - One.mp3"])
        #expect(calls.loaded.last == true)
    }

    @Test func theLaunchLoudnessWaitsForItsReadBeforeTheFirstUse() throws {
        let folder = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }

        let file = folder.appending(path: Loudness.name)
        let entry = Loudness.Entry(size: 1, modified: 1, lufs: -14, peak: 0.5, seconds: 1)
        #expect(Persist.write(try #require(Persist.encode(["A.mp3": entry], for: file)), to: file))
        let track = Track(url: folder.appending(path: "A.mp3"), title: "A", artist: "Band", album: "Album", number: 1, disc: 1, albumArtist: "Band", year: 2000, duration: 1, albumID: "x")

        let loudness = Loudness()
        loudness.open([folder])
        #expect(loudness.gain(track, album: false) != nil, "the first gain waits for the read; it never sees an empty list")
    }

    @Test func theAppOpensTheLibraryBeforeTheWindow() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive")
        let app = try String(contentsOf: root.appending(path: "Overdrive.swift"), encoding: .utf8)
        let views = try String(contentsOf: root.appending(path: "Views.swift"), encoding: .utf8)

        #expect(app.contains("Library(loudness: loudness, launch: true)"), "the app reads the cache while it builds the rest")
        #expect(app.contains("        }\n        library.open()\n"), "the library opens inside `shared`, after `loaded` is set and before any window")
        #expect(views.contains(".onChange(of: library.scans, initial: true, refreshed)"), "the library is there before the window, so the saved screen must come back on the first draw, not on a later scan")
    }
}
