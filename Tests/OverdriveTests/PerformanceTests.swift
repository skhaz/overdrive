import Foundation
import Testing
@testable import Overdrive

@MainActor
struct PerformanceTests {
    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }

    private func region(_ source: String, _ marker: String) -> String {
        guard let start = source.range(of: marker) else { return "" }

        let rest = source[start.upperBound...]
        return String(rest[..<(rest.range(of: "\nstruct ")?.lowerBound ?? rest.endIndex)])
    }

    private func track(_ title: String) -> Track {
        Track(url: URL(filePath: "/m/\(title).mp3"), title: title, artist: "A", album: "B", number: 1, disc: 1, albumArtist: "", year: 2000, duration: 1, albumID: "B")
    }

    @Test func aTokenBuildsTheRowsOnlyOnce() {
        let cache = Sorted<Track>()
        var builds = 0
        let make = { builds += 1; return [self.track("b"), self.track("a")] }

        #expect(cache.apply(Sort(.title), token: 1, make).map(\.title) == ["a", "b"])
        _ = cache.apply(Sort(.title), token: 1, make)
        #expect(builds == 1, "a redraw with the same token neither builds nor compares the rows")

        _ = cache.apply(Sort(.title), token: 2, make)
        _ = cache.apply(Sort(), token: 2, make)
        #expect(builds == 3)
    }

    @Test func aMemoComputesOnlyWhenItsTokenChanges() {
        let memo = Memo<String>()
        var runs = 0

        #expect(memo.value("a1") { runs += 1; return "x" } == "x")
        #expect(memo.value("a1") { runs += 1; return "y" } == "x")
        #expect(memo.value("a2") { runs += 1; return "z" } == "z")
        #expect(runs == 2)
    }

    @Test func onlyTheTimeBarRedrawsTwiceASecond() throws {
        let views = try source("Views.swift")

        #expect(!region(views, "struct Controls: View {").contains("player.position"), "the whole bottom bar must not redraw on every tick")
        #expect(region(views, "struct TimeBar: View {").contains("player.position"))
        #expect(try source("LyricsPanel.swift").contains("if !lyrics.floating {\n            Color.clear"), "a hidden floating panel does no work")
        #expect(try source("Lyrics.swift").contains("private(set) var hasLocalLyrics = false"), "the lyrics view must not read the disk on every redraw")
    }

    @Test func savesAndScansWaitForAQuietMoment() throws {
        let player = try source("Player.swift")
        let library = try source("Library.swift")

        #expect(player.contains("guard (try? await Task.sleep(for: Player.delay)) != nil else { return }\n\n            write()"), "a navigation or a search must not write the whole session at once")
        #expect(player.contains("MainActor.assumeIsolated { self?.write() }"), "quit writes the session at once")
        #expect(library.contains("guard (try? await Task.sleep(for: Library.quiet)) != nil else { return }"), "a copy of many files starts one scan, not one per event")
        #expect(library.contains("if readerFolders != folders {"), "the search connections open once per folder change, not once per scan step")
    }

    @Test func logsStayCheap() throws {
        let log = try source("Log.swift")

        #expect(log.contains("system = os.Logger(subsystem: \"org.delduca.Overdrive\", category: label)"), "one system logger per label")
        #expect(log.contains("queue.asyncAfter(deadline: .now() + Self.batch)"), "one fsync for a burst of records")
        #expect(try source("Views.swift").contains("\"destination\": \"\\(destination.key)\""), "a log must not dump a whole album")
    }

    @Test func thePeriodicSyncIsCheap() throws {
        let library = try source("Library.swift")
        let sync = region(library, "private func sync() {")

        #expect(Library.period == .seconds(600))
        #expect(sync.contains("scanning || info.isLowPowerModeEnabled || info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue"), "no sync while a scan runs, on low power, or when the Mac is hot")
        #expect(sync.contains("ContinuousClock.now - last >= Library.period"), "no sync right after another scan")
        #expect(library.contains("if persistent { sync() }"), "only the app syncs, never a test library")
        #expect(try source("Overdrive.swift").contains("Button(\"Sync Library\")"), "the menu syncs at once")
    }
}
