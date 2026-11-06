import Foundation
import Testing
@testable import Overdrive

@Suite struct PersistTests {
    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    @Test func writesAtomically() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = directory.appending(path: "Data.plist")
        #expect(Persist.write(Data("value".utf8), to: file))

        #expect(try Data(contentsOf: file) == Data("value".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("tmp").path))
    }

    @Test func movesOverTarget() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let source = directory.appending(path: "Source.plist")
        let target = directory.appending(path: "Target.plist")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: target)

        #expect(Persist.move(source, to: target))
        #expect(try Data(contentsOf: target) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func aLaterWriteKeepsTheOrderAndLeavesTheCallerAtOnce() throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = directory.appending(path: "Data.plist")
        let gate = DispatchSemaphore(value: 0)
        Persist.later { _ = gate.wait(timeout: .now() + 2); return [] }

        let clock = ContinuousClock()
        let start = clock.now
        Persist.later { [(file, Data("first".utf8))] }
        Persist.later { [(file, Data("second".utf8))] }
        #expect(clock.now - start < .milliseconds(500), "the caller never waits for the queue")
        #expect(!FileManager.default.fileExists(atPath: file.path), "nothing is written before the queue reaches it")

        gate.signal()
        Persist.flush()
        #expect(try Data(contentsOf: file) == Data("second".utf8), "the writes land in the order they were asked")
    }
}
