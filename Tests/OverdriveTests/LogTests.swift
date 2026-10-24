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
            #expect(!source.contains("print("), "\(name): use Log")
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
