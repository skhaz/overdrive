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
        Persist.write(Data("value".utf8), to: file, wait: true)

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
}
