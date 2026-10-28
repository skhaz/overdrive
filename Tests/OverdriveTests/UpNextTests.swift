import Foundation
import Testing
@testable import Overdrive

struct UpNextTests {
    @Test func movesSongsDown() {
        #expect(Player.moved(5, [0], to: 3) == [1, 2, 0, 3, 4])
        #expect(Player.moved(5, [0, 1], to: 5) == [2, 3, 4, 0, 1])
    }

    @Test func movesSongsUp() {
        #expect(Player.moved(5, [4], to: 0) == [4, 0, 1, 2, 3])
        #expect(Player.moved(5, [1, 3], to: 0) == [1, 3, 0, 2, 4])
    }

    @Test func aMoveOutOfRangeKeepsTheOrder() {
        #expect(Player.moved(3, [], to: 1) == [0, 1, 2])
        #expect(Player.moved(3, [7], to: 1) == [0, 1, 2])
        #expect(Player.moved(3, [0], to: 9) == [1, 2, 0])
        #expect(Player.moved(3, [2], to: -1) == [2, 0, 1])
    }

    @Test func removesSongsAndKeepsTheCurrentOne() {
        let removed = Player.removing(5, [0, 2, 4], keeping: 2)

        #expect(removed.kept == [1, 2, 3], "the song that plays stays in Up Next")
        #expect(removed.index == 1)
    }

    @Test func removesSongsAfterTheCurrentOne() {
        let removed = Player.removing(4, [2, 3], keeping: 0)

        #expect(removed.kept == [0, 1])
        #expect(removed.index == 0)
    }

    @Test func addGoesRightAfterTheSongThatPlays() {
        let album = ["01", "02", "03", "04", "05", "06"]
        let added = Player.inserting(album, Array(repeating: false, count: 6), at: 0, ["02", "03", "05", "04"])

        #expect(added.items == ["01", "02", "03", "05", "04", "06"], "the picked songs play next, not at the end of Up Next")
        #expect(added.marks == [false, true, true, true, true, false])
        #expect(added.index == 0, "the song that plays does not move")
    }

    @Test func eachAddGoesAfterTheSongsAddedBefore() {
        let first = Player.inserting(["a", "b", "c"], [false, false, false], at: 0, ["x"])
        let second = Player.inserting(first.items, first.marks, at: first.index, ["y"])

        #expect(second.items == ["a", "x", "y", "b", "c"], "the next add follows the one before it, so the picks keep their order")
        #expect(second.marks == [false, true, true, false, false])
    }

    @Test func anAddWhilePlayingAnAddedSongGoesAfterTheAddedRun() {
        let first = Player.inserting(["a", "b", "c"], [false, false, false], at: 0, ["x", "y"])
        let second = Player.inserting(first.items, first.marks, at: 1, ["z"])

        #expect(second.items == ["a", "x", "y", "z", "b", "c"], "the picks of this run stay together")
        #expect(second.index == 1)
    }

    @Test func addAtTheEndOfTheListAddsToIt() {
        let added = Player.inserting(["a", "b"], [false, false], at: 1, ["x"])

        #expect(added.items == ["a", "b", "x"])
        #expect(added.index == 1, "the song that plays does not move")
    }

    @Test func aSongAddedTwiceMovesAndKeepsTheCurrentSong() {
        let added = Player.inserting(["a", "b", "c", "d"], [false, false, false, false], at: 2, ["a", "c", "d"])

        #expect(added.items == ["b", "c", "a", "d"])
        #expect(added.index == 1)
        #expect(added.marks == [false, false, true, true])
    }

    @Test func removingTheCurrentSongAndAllNextOnesClearsTheList() {
        #expect(Player.clears(5, [2, 3, 4], from: 2))
        #expect(Player.clears(3, [0, 1, 2], from: 0))
        #expect(!Player.clears(5, [3, 4], from: 2), "without the song that plays, the list stays")
        #expect(!Player.clears(5, [2, 4], from: 2))
        #expect(!Player.clears(0, [], from: 0))
    }

    @Test func clearingResetsThePlayer() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appending(path: "Sources/Overdrive/Player.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "    func clear() {"))
        let body = source[start.upperBound...].prefix { _ in true }
        let clear = String(body[..<body.range(of: "\n    }\n")!.lowerBound])

        for line in ["player.removeAllItems()", "item = nil", "queue = []", "order = []", "added = []", "playing = false", "position = 0", "update()", "save()"] {
            #expect(clear.contains(line), "Clear Up Next must reset the player: \(line)")
        }
        #expect(!clear.contains("pause()"), "clearing resets the player, it does not pause it")
    }

    @Test func theUpNextPageKeepsItsKey() {
        #expect(Page(key: Page.upNext.key) == .upNext)
        #expect(Page.upNext.title == "Up Next")
        #expect(Page.upNext.key == "up-next")
        #expect(Page(key: "queue") == nil, "the old page key is gone, not renamed in place")
        #expect(Navigation(page: .upNext).lyrics)
    }

    @Test func aContextMenuActsOnTheWholeSelection() {
        #expect(targets([3, 4], [3, 4, 5, 6]) == [3, 4, 5, 6], "SwiftUI hands the menu only the drawn rows of a Select All, so the menu reads the selection itself")
        #expect(targets([2], [2]) == [2])
        #expect(targets([9], [3, 4]) == [9], "a right-click outside the selection acts on the clicked row")
        #expect(targets([], [3, 4]) == [], "a right-click on the empty area acts on nothing")
    }

    @Test func everyTableMenuReadsTheSelection() throws {
        let views = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/Views.swift"), encoding: .utf8)

        #expect(views.components(separatedBy: "targets(ids, selection)").count - 1 == 4, "Songs, Liked Songs, playlists, and Up Next act on the selection, never on the rows SwiftUI drew")
    }

    @Test func theSongMenuHasOneAddAction() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let views = try String(contentsOf: root.appending(path: "Sources/Overdrive/Views.swift"), encoding: .utf8)

        #expect(views.contains("Button(\"Add to Up Next\") { player.insert(tracks) }"), "one action adds the selected songs right after the song that plays")
        #expect(!views.contains("Play Next"), "Play Next and Add to Queue were the same action twice")
        #expect(!views.contains("Add to Queue"), "Play Next and Add to Queue were the same action twice")
        #expect(views.contains(".keyboardShortcut(.return, modifiers: .command)"), "the one action keeps Command-Return")
        #expect(!views.contains("modifiers: [.command, .return]"), "no second shortcut for a removed action")
    }
}
