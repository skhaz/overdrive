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

    @Test func theEndOfTheListLeavesNothingBehind() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appending(path: "Sources/Overdrive/Player.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "    private func stop() {"))
        let rest = source[start.upperBound...]
        let stop = String(rest[..<rest.range(of: "\n    }\n")!.lowerBound])

        for line in ["queue = []", "order = []", "added = []", "origin = []", "index = 0", "player.removeAllItems()", "item = nil", "update()", "save()"] {
            #expect(stop.contains(line), "the end of a list leaves no old song behind: \(line)")
        }
        #expect(source.contains("guard let next = following(index) else { return stop() }"), "the last song that ends empties the list")
        #expect(source.contains("guard let next = following(index, manual: true) else { return stop() }"), "and Next on the last song does the same")

        let finished = try #require(source.range(of: "    private func finished(_ ended: AVPlayerItem?) {"))
        let tail = String(source[finished.upperBound...])
        #expect(tail.prefix(1200).contains("stop()"), "the natural end of the queue goes through the same door")
    }

    @Test func theHeadFollowsThePlayerAndStaysForASongTheUserClicked() {
        #expect(Player.head(0, 6, forward: false) == 0, "a click on the 7th song of ten keeps the six before it in the list")
        #expect(Player.head(0, 2, forward: false) == 0, "and a click on one nearer the top keeps the rest")
        #expect(Player.head(0, 6, forward: true) == 6, "the player passing to a song leaves everything behind it")
        #expect(Player.head(3, 4, forward: true) == 4, "one song at a time, as the list walks")
        #expect(Player.head(4, 2, forward: false) == 2, "the head is never above the song that plays")
        #expect(Player.head(0, 0, forward: true) == 0)
    }

    @Test func aJumpKeepsTheSkippedSongsInTheirOwnPlace() throws {
        let jump = try body("    func jump(to position: Int) {")

        #expect(jump.contains("index = position"), "the click makes its song the one that plays")
        #expect(jump.contains("head = Player.head(head, position, forward: false)"), "and keeps the songs it stepped over where they are")
        for untouched in ["queue", "order", "added", "origin"] {
            #expect(!jump.contains("\(untouched) ="), "a jump rewrites no list: \(untouched)")
        }

        let views = try source("Views.swift")

        #expect(views.contains("player.queue.indices.dropFirst(player.head)"), "the Up Next list begins at the head, not at the song that plays")
        #expect(views.contains("summary(player.queue.dropFirst(player.head))"), "and so does its window subtitle")
        #expect(views.contains("[player.revision, player.index, player.head, library.plays.revision]"), "the list is rebuilt when the head moves, not only when the song does")
        #expect(views.contains("to: max(player.head + index, player.index + 1)"), "a drop lands in the list it was read from, and never ahead of the song that plays")
    }

    @Test func everyMoveOfTheSongMovesTheHead() throws {
        for signature in ["func play(_ tracks: [Track], at start: Int = 0) {", "func next() {", "private func finished(_ ended: AVPlayerItem?) {", "private func failed(_ id: ObjectIdentifier) {", "func restore(complete: Bool, _ lookup: (String) -> Track?) {"] {
            let body = try self.body(signature)

            #expect(body.contains("index = "), "\(signature) moves the song that plays")
            #expect(body.contains("head = Player.head(head, "), "\(signature) moves the song that plays forward, so the head passes with it")
            #expect(body.contains("forward: true"), "\(signature) is a pass, not a click")
        }

        for signature in ["func jump(to position: Int) {", "func previous() {"] {
            #expect(try self.body(signature).contains("forward: false"), "\(signature) must never drop the songs before the one that plays")
        }

        for signature in ["func insert(_ tracks: [Track]) {", "func remove(_ positions: Set<Int>) {"] {
            #expect(try self.body(signature).contains("head = Player.passed(head, "), "\(signature) changes the list, so the head moves with it")
        }

        #expect(try body("func move(_ positions: Set<Int>, to target: Int) {").contains("head = moved.firstIndex(of: head) ?? head"), "a drag moves the head with the rows it moved")

        for signature in ["func clear() {", "private func stop() {"] {
            let body = try self.body(signature)

            #expect(body.contains("head = 0"), "\(signature) empties the list, so the head starts over")
            #expect(body.contains("index = 0"))
        }
    }

    @Test func theHeadIsNeverAboveTheSongThatPlays() {
        for count in 1...8 {
            for head in 0..<count {
                for index in head..<count {
                    for mask in 0..<(1 << count) {
                        let picked = Set((0..<count).filter { mask & (1 << $0) != 0 })

                        let removed = Player.removing(count, picked, keeping: index)
                        #expect(Player.passed(head, removed.kept) <= removed.index, "a removal of \(picked.sorted()) from \(count) songs leaves the head above the song that plays (head \(head), index \(index))")

                        let moved = Player.moved(count, picked, to: index)
                        let place = moved.firstIndex(of: head) ?? head
                        #expect(place <= (moved.firstIndex(of: index) ?? index), "a drag of \(picked.sorted()) to \(index) leaves the head above the song that plays (head \(head))")
                    }
                }
            }
        }
    }

    @Test func anAddOfASongThatWasAlreadyInListMovesTheHead() {
        let album = ["01", "02", "03", "04", "05"]
        let marks = Array(repeating: false, count: 5)

        let added = Player.inserting(album, marks, at: 3, ["02"])

        #expect(added.kept == [0, 2, 3, 4], "the song that is added leaves its old place, so the list shrinks before the head")
        #expect(added.index == 2)
        #expect(Player.passed(0, added.kept) == 0, "a head that stayed keeps its place")
        #expect(Player.passed(1, added.kept) == 1, "a head the add took away moves to the song that took its place")
        #expect(Player.passed(2, added.kept) == 1, "and a head below it follows its own song")

        let first = Player.inserting(album, marks, at: 3, ["01"])

        #expect(first.kept == [1, 2, 3, 4])
        #expect(Player.passed(0, first.kept) == 0, "the head of a list that lost its first song is the new first song")
        #expect(Player.passed(0, first.kept) <= first.index)
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

    // MARK: - helpers

    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }

    private func body(_ signature: String) throws -> String {
        let player = try source("Player.swift")
        let start = try #require(player.range(of: signature)).upperBound
        let rest = player[start...]

        return String(rest[..<rest.range(of: "\n    }\n")!.lowerBound])
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
