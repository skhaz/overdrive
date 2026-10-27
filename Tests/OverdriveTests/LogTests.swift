import Foundation
import Testing
@testable import Overdrive

struct LogTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "LogTests-\(UUID().uuidString)")
    }

    private func names(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func record(_ message: String, _ seconds: Double) -> Data {
        Sink.record(Date(timeIntervalSince1970: seconds), .info, "app", message, [:], "Log.swift", 1)
    }

    @Test func eachHourHasItsOwnFileNamedInUTC() {
        #expect(Sink.name(0) == "1970-01-01T00.log")
        #expect(Sink.name(491_557) == "2026-01-28T13.log")
    }

    @Test func aRecordIsOneJSONLine() throws {
        let data = Sink.record(Date(timeIntervalSince1970: 7200.5), .error, "player", "item\nfailed", ["path": "/a b/c.mp3", "codes": .array(["1", "2"])], "Player.swift", 42)

        #expect(data.last == 0x0A)
        #expect(!data.dropLast().contains(0x0A), "a record never spans two lines")

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["time"] as? String == "1970-01-01T02:00:00.500Z")
        #expect(object["level"] as? String == "error")
        #expect(object["label"] as? String == "player")
        #expect(object["message"] as? String == "item\nfailed")
        #expect(object["source"] as? String == "Player.swift:42")

        let metadata = try #require(object["metadata"] as? [String: Any])
        #expect(metadata["path"] as? String == "/a b/c.mp3")
        #expect(metadata["codes"] as? [String] == ["1", "2"])
    }

    @Test func theSinkAppendsRecords() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sink = Sink(directory: directory)
        sink.write(record("one", 7200), at: Date(timeIntervalSince1970: 7200))
        sink.write(record("two", 7201), at: Date(timeIntervalSince1970: 7201))
        sink.flush()

        let lines = try String(contentsOf: directory.appending(path: "1970-01-01T02.log"), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.map { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["message"] as? String } == ["one", "two"])
    }

    @Test func aTornRecordIsDroppedSoEveryRecordIsWholeOrAbsent() throws {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var old = record("whole", 10)
        old.append(Data("{\"message\":\"to".utf8))
        try old.write(to: directory.appending(path: "1970-01-01T00.log"))

        let sink = Sink(directory: directory)
        sink.write(record("next", 20), at: Date(timeIntervalSince1970: 20))
        sink.flush()

        let lines = try String(contentsOf: directory.appending(path: "1970-01-01T00.log"), encoding: .utf8).split(separator: "\n")
        #expect(lines.map { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["message"] as? String } == ["whole", "next"], "a power loss must not leave half a record")
    }

    @Test func theFilesRotateEveryHourAndStayOneDay() {
        let directory = folder()
        defer { try? FileManager.default.removeItem(at: directory) }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: directory.appending(path: "1969-12-31T23.log").path, contents: Data())
        FileManager.default.createFile(atPath: directory.appending(path: "notes.txt").path, contents: Data())

        let sink = Sink(directory: directory)
        let day = Double(Sink.kept) * Sink.interval
        sink.write(record("one", day), at: Date(timeIntervalSince1970: day))
        sink.flush()
        #expect(names(directory) == ["1970-01-02T00.log", "notes.txt"], "a file older than one day is deleted at launch")

        sink.write(record("two", day + 3600), at: Date(timeIntervalSince1970: day + 3600))
        sink.flush()
        #expect(names(directory) == ["1970-01-02T00.log", "1970-01-02T01.log", "notes.txt"], "a new hour starts a new file and keeps the old one")

        sink.write(record("three", 2 * day), at: Date(timeIntervalSince1970: 2 * day))
        sink.flush()
        #expect(names(directory) == ["1970-01-02T01.log", "1970-01-03T00.log", "notes.txt"], "no file stays longer than one day")
    }

    @Test func testsNeverWriteTheRealLog() {
        #expect(Log.sink == nil, "only the app bundle writes to ~/Library/Logs/Overdrive")
    }

    @Test func noCodeLogsPlainText() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive")
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name.hasSuffix(".swift") && name != "Log.swift" {
            let source = try String(contentsOf: root.appending(path: name), encoding: .utf8)
            #expect(!source.contains("os_log("), "\(name): use Log")
            #expect(source.range(of: #"(?<![A-Za-z])print\("#, options: .regularExpression) == nil, "\(name): use Log")
            #expect(!source.contains("NSLog("), "\(name): use Log")
            #expect(!source.contains("Logger(subsystem"), "\(name): use Log")
            #expect(source.range(of: #"Log\.(info|debug|error|fault|write)\(""#, options: .regularExpression) == nil, "\(name): every log is structured: a fixed event and metadata")
        }
    }

    @Test func theAppStartsTheLogFirst() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appending(path: "Sources/Overdrive/Overdrive.swift"), encoding: .utf8)

        #expect(source.contains("private static let shared = {\n        Log.start()"), "the log must record the launch and catch crashes")
        #expect(source.contains("Log.flush()"), "quit must flush the log")
    }
}

let logRecords: Records = {
    let records = Records()
    Log.tap = { records.add($0) }
    return records
}()

final class Records: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String: Any]] = []

    func add(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.withLock { items.append(object) }
    }

    func find(_ label: String, _ message: String, _ key: String? = nil, _ value: String? = nil) -> Bool {
        lock.withLock {
            items.contains { item in
                guard item["label"] as? String == label, item["message"] as? String == message else { return false }
                guard let key else { return true }
                let field = (item["metadata"] as? [String: Any])?[key]
                return value.map { value in (field as? String)?.contains(value) == true || (field as? [String])?.contains { $0.contains(value) } == true } ?? (field != nil)
            }
        }
    }
}

@Suite(.serialized) struct LogCoverageTests {
    private let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")

    private func body(_ source: String, _ signature: String) -> String {
        guard let start = source.range(of: signature) else { return "" }
        let rest = source[start.upperBound...]
        return String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }

    @Test func everyDecisionLogs() throws {
        let events: [String: [String]] = [
            "Persist.swift": ["read failed", "decode failed", "write", "move", "remove"],
            "Cache.swift": ["query failed", "statement failed", "begin failed", "save failed", "open failed", "discard"],
            "Picture.swift": ["covers process failed", "covers"],
            "Library.swift": ["folder unreadable", "watch failed", "watch", "scan requested", "rows missing", "reader unavailable", "choose cancelled", "reread", "covers to make", "covers saved", "cover image changed", "sync full scan", "edits", "album ids moved"],
            "LastFM.swift": ["connected", "connect failed", "flush stopped", "flush split", "scrobble isolated", "scrobble response invalid", "settle", "now playing"],
            "Player.swift": ["tags refreshed", "restore partial", "give up", "no gain", "no mix", "gain deferred", "stale item event", "position jump", "muted", "reorder", "requeue", "spectrum", "random ignored"],
            "Plays.swift": ["load skipped", "load", "saved", "save failed", "flush skipped", "counts carried", "bump"],
            "Discovery.swift": ["discovery", "discovery ignored", "discovery stopped", "discovery empty", "discovery result", "discovery superseded"],
            "Loves.swift": ["load", "sync asked", "sync skipped", "queued", "queue kept", "queue held", "sent", "pull stopped", "pull wide", "pull fast", "pull", "apply", "push", "arrive", "arrive ignored"],
            "YouTube.swift": ["ready", "login check failed", "candidate rejected", "superseded", "no video", "remote", "window closed", "song resumed", "corner", "failure ignored"],
            "Lyrics.swift": ["refresh result", "replace", "source", "invalid json", "latin1 fallback", "request gave up"],
            "Spectrum.swift": ["spectrum tap failed"],
            "AppleMusic.swift": ["blocked apple music"],
            "LyricsPanel.swift": ["panel shown", "panel hidden"],
            "Views.swift": ["drop ignored", "drop", "create cancelled", "delete cancelled", "clear cancelled", "shown", "gesture", "gesture ignored", "discovery", "open in mp3tag", "show in finder"],
        ]
        for (file, names) in events {
            let text = try source(file)
            for name in names {
                #expect(text.contains("\"\(name)\", metadata") || text.contains("(\"\(name)\")"), "\(file) must log \(name)")
            }
        }
    }

    @Test func everyActionLogs() throws {
        let player = try source("Player.swift")
        for name in ["toggleMute", "play", "insert", "random", "jump", "move", "clear", "remove", "restore", "resume", "pause", "next", "previous", "seek", "perform", "stop", "load", "finished", "failed", "begin"] {
            #expect(body(player, "func \(name)(").contains("Log.player."), "Player.\(name) must log")
        }

        let youTube = try source("YouTube.swift")
        for name in ["watch", "close", "signOut", "load", "show", "stop", "failed", "search", "webViewWebContentProcessDidTerminate"] {
            #expect(body(youTube, "func \(name)(").contains("Log.youTube."), "YouTube.\(name) must log")
        }

        let plays = try source("Plays.swift")
        for name in ["bump", "rebind", "load", "flush"] {
            #expect(body(plays, "func \(name)(").contains("Log.plays."), "Plays.\(name) must log")
        }

        let discovery = try source("Discovery.swift")
        #expect(body(discovery, "func pick(_ pool: Pool, _ count: Int) {").contains("Log.player."), "Discovery.pick must log the click")
        #expect(body(discovery, "private func walk(_ pool: Pool, _ count: Int) async -> [Track] {").contains("Log.player."), "Discovery.walk must log its result")
        #expect(body(discovery, "private func start(_ tracks: [Track], _ mine: Int, _ pool: Pool, _ count: Int) {").contains("Log.player."), "Discovery.start must log an empty answer")

        let loves = try source("Loves.swift")
        for name in ["syncNow", "arrive", "sync", "local", "drain", "pull"] {
            #expect(body(loves, "func \(name)(").contains("Log.loves.") || body(loves, "private func \(name)(").contains("Log.loves."), "Loves.\(name) must log")
        }

        let views = try source("Views.swift")
        for signature in ["func goBack(", "func goForward(", "func press(", "func reveal(_ track", "func navigate("] {
            #expect(body(views, signature).contains("Log."), "\(signature) must log")
        }
        #expect(views.contains(".environment(\\.go, GoAction { destination in\n            Log.navigation.info(\"go\""))
        #expect(views.contains("Log.navigation.info(\"place\""), "every screen change logs the full path")
        #expect(views.contains("Log.navigation.info(\"query\""), "every query change logs")
    }

    @Test @MainActor func theComponentsWriteStructuredRecords() async throws {
        let records = logRecords

        let folder = FileManager.default.temporaryDirectory.appending(path: "LogCoverage-\(UUID().uuidString)")
        defer { Persist.flush(); try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "A"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appending(path: "cbr.mp3"), to: folder.appending(path: "A/one.mp3"))
        let real = folder.resolvingSymlinksInPath()

        let result = await Library.load([folder], [:])
        let track = try #require(result.albums.first?.tracks.first)
        #expect(records.find("library", "load", "folders", folder.lastPathComponent))
        #expect(records.find("library", "walk", "read", "1"))
        #expect(records.find("cache", "saved", "changes", "1"))

        let file = folder.appending(path: "x.plist")
        Persist.write(Data([1]), to: file)
        Persist.move(file, to: folder.appending(path: "y.plist"))
        Persist.remove(folder.appending(path: "y.plist"))
        Persist.remove(folder.appending(path: "missing.plist"))
        #expect(records.find("persist", "write", "path", "x.plist"))
        #expect(records.find("persist", "move", "to", "y.plist"))
        #expect(records.find("persist", "remove", "result", "ok"))
        #expect(records.find("persist", "remove", "result", "No such file"), "a failed write logs the system error")

        let likes = Likes(file: real.appending(path: "Likes.plist"), folder: real)
        likes.add([track])
        likes.remove([track])
        #expect(records.find("likes", "add", "paths", "one.mp3"))
        #expect(records.find("likes", "remove", "paths", "one.mp3"))

        let playlists = Playlists(directory: real.appending(path: "Playlists"), folder: real)
        _ = playlists.create("Mix", [track.url])
        playlists.add([track.url], to: "Mix")
        playlists.reorder([0], in: "Mix")
        playlists.remove([0], from: "Mix")
        playlists.delete("Mix")
        for event in ["create", "add", "reorder", "remove", "delete"] {
            #expect(records.find("playlists", event, "name", "Mix"), "playlists \(event)")
        }

        try Data("[00:01.00]line".utf8).write(to: track.url.deletingPathExtension().appendingPathExtension("lyrics"))
        let lyrics = Lyrics()
        lyrics.show(track)
        lyrics.save("[00:02.00]new", for: track)
        #expect(records.find("lyrics", "show", "path", "one.mp3"))
        #expect(records.find("lyrics", "local", "path", "one.lyrics"))
        #expect(records.find("lyrics", "save", "characters", "13"))

        let loudness = Loudness(folders: [real])
        await loudness.measure(track, album: false)
        #expect(records.find("loudness", "measured", "lufs"))
    }
}
