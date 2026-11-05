import Foundation
import Testing
@testable import Overdrive

/// The Addicted list over a real `Library` on a real folder: the twenty most
/// played songs, best first, always current when read.
@MainActor
@Suite(.serialized)
struct AddictedTests {
    private let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")

    struct Built {
        let library: Library
        let root: URL
    }

    private func build(_ names: [String]) async throws -> Built {
        let root = FileManager.default.temporaryDirectory.appending(path: "OverdriveAddicted-\(UUID().uuidString)")
        let music = root.appending(path: "Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)

        for name in names {
            let target = music.appending(path: name)
            try FileManager.default.copyItem(at: fixtures.appending(path: "cbr.mp3"), to: target)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: target.path)
        }

        let library = Library(loudness: Loudness(), folders: [music])
        let end = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < end, !library.settled { try? await Task.sleep(for: .milliseconds(20)) }
        guard library.settled, library.tracks.count == names.count else {
            try? FileManager.default.removeItem(at: root)
            Issue.record("the library never settled with all its songs")
            throw CancellationError()
        }

        return Built(library: library, root: root)
    }

    private func song(_ library: Library, _ name: String) throws -> Track {
        guard let track = library.tracks.first(where: { $0.url.lastPathComponent == name }) else {
            Issue.record("\(name) never arrived")
            throw CancellationError()
        }

        return track
    }

    @Test func theListWalksTheCountsAndStaysCurrentOnRead() async throws {
        let built = try await build(["One.mp3", "Two.mp3", "Three.mp3"])
        defer { try? FileManager.default.removeItem(at: built.root) }
        let library = built.library

        #expect(library.addicted(Library.topPlayed).isEmpty, "a song with no play is on nobody's list")

        let one = try song(library, "One.mp3"), two = try song(library, "Two.mp3"), three = try song(library, "Three.mp3")
        library.plays.bump(one)
        for _ in 0..<2 { library.plays.bump(three) }
        for _ in 0..<3 { library.plays.bump(two) }

        #expect(library.addicted(Library.topPlayed) == [two.url.path, three.url.path, one.url.path], "best first, and it reads live: no scan, no wait")

        for _ in 0..<4 { library.plays.bump(one) }

        #expect(library.addicted(Library.topPlayed) == [one.url.path, two.url.path, three.url.path], "the list a new click shows is the order of this very moment")
    }

    @Test func theListCutsAtTwenty() async throws {
        let names = (0..<25).map { "Song\($0).mp3" }
        let built = try await build(names)
        defer { try? FileManager.default.removeItem(at: built.root) }
        let library = built.library

        // every song of its own number of plays: one, then two, up to twenty-five
        for name in names {
            let index = Int(name.dropFirst(4).dropLast(4))!
            for _ in 0...index { library.plays.bump(try song(library, name)) }
        }

        let paths = library.addicted(Library.topPlayed)
        #expect(paths.count == Library.topPlayed, "the list never grows past twenty")
        #expect(paths.first == library.tracks.first(where: { $0.url.lastPathComponent == "Song24.mp3" })?.url.path, "the most played leads")
        #expect(paths.last == library.tracks.first(where: { $0.url.lastPathComponent == "Song5.mp3" })?.url.path, "the twentieth is the twenty-first best")
        #expect(!paths.contains { $0.hasSuffix("Song4.mp3") }, "and the rest stays out")
    }

    @Test func aSongTheLibraryLostLeavesTheList() async throws {
        let built = try await build(["One.mp3", "Two.mp3"])
        defer { try? FileManager.default.removeItem(at: built.root) }
        let library = built.library

        let one = try song(library, "One.mp3"), two = try song(library, "Two.mp3")
        library.plays.bump(one)
        for _ in 0..<2 { library.plays.bump(two) }

        try FileManager.default.removeItem(at: two.url)
        library.scan("test")
        let end = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < end, library.scanning { try? await Task.sleep(for: .milliseconds(20)) }

        #expect(library.addicted(Library.topPlayed) == [one.url.path], "the gone song took no place: its key sits at the head of the order")
    }
}
