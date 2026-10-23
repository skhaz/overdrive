import Foundation
import Testing

struct ViewStructureTests {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try String(contentsOf: root.appending(path: "Sources/Overdrive/Views.swift"))
    }

    @Test func theStackRootNeverChangesItsIdentity() throws {
        let source = try source()

        #expect(!source.contains(".id(library.query)"), "the stack root must not be recreated when the query changes")
        #expect(!source.contains(".id(library.version)"), "the stack root must not be recreated when the library changes")
    }

    @Test func thePushedScreenKeepsARouteIdentity() throws {
        #expect(try source().contains(".id(route)"), "each pushed route must build a fresh screen")
    }
}
