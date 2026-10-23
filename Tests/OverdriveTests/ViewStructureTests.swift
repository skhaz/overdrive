import Foundation
import Testing

struct ViewStructureTests {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try String(contentsOf: root.appending(path: "Sources/Overdrive/Views.swift"), encoding: .utf8)
    }

    private func region(_ source: String, from marker: String) -> String {
        guard let start = source.range(of: marker) else { return "" }

        let rest = source[start.upperBound...]
        let end = rest.range(of: "\nstruct ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test func theStackRootNeverChangesItsIdentity() throws {
        let source = try source()

        #expect(!source.contains(".id(library.query)"), "the stack root must not be recreated when the query changes")
        #expect(!source.contains(".id(library.version)"), "the stack root must not be recreated when the library changes")
    }

    @Test func thePushedScreenKeepsARouteIdentity() throws {
        #expect(try source().contains(".id(route)"), "each pushed route must build a fresh screen")
    }

    @Test func onlyTheSongsListOpensAnAlbumOnPlay() throws {
        let source = try source()

        #expect(region(source, from: "struct SongTable").contains("go(.playing"), "the songs list (and the search results) open the album of the played song")
        #expect(!region(source, from: "struct PlaylistView").contains("go(.playing"), "a playlist only plays the row")
        #expect(!region(source, from: "struct LikedView").contains("go(.playing"), "the liked songs only play the row")
    }

    @Test func onlyTheCurrentStackWritesThePath() throws {
        let source = try source()

        #expect(source.contains("navigation.write(value, on: page"), "a stack writes its path only through Navigation.write, which checks the page at call time")
        #expect(!source.contains("if current { navigate(value) }"), "a captured flag goes stale and lets a hidden stack open its album on another page")
    }

    @Test func theAlbumOnlyPlaysTheRow() throws {
        #expect(!region(try source(), from: "struct AlbumView").contains("go(.playing"), "playing a song in an open album stays on that album")
    }

    @Test func theArrowsMoveTheSidebarWhenItHasTheFocus() throws {
        #expect(try source().contains("case (123...126, true): return false"), "the sidebar keeps its own arrow keys")
    }
}
