import Testing
@testable import Overdrive

struct QueueTests {
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

        #expect(removed.kept == [1, 2, 3], "the song that plays stays in the queue")
        #expect(removed.index == 1)
    }

    @Test func removesSongsAfterTheCurrentOne() {
        let removed = Player.removing(4, [2, 3], keeping: 0)

        #expect(removed.kept == [0, 1])
        #expect(removed.index == 0)
    }

    @Test func addToQueuePlaysTheSongsBeforeTheRestOfTheAlbum() {
        let album = ["01", "02", "03", "04", "05", "06"]
        let added = Player.inserting(album, Array(repeating: false, count: 6), at: 0, ["02", "03", "05", "04"], next: false)

        #expect(added.items == ["01", "02", "03", "05", "04", "06"], "the picked songs went to the end, after the rest of the album")
        #expect(added.marks == [false, true, true, true, true, false])
        #expect(added.index == 0)
    }

    @Test func addToQueueGoesAfterTheSongsAddedBefore() {
        let first = Player.inserting(["a", "b", "c"], [false, false, false], at: 0, ["x"], next: false)
        let second = Player.inserting(first.items, first.marks, at: first.index, ["y"], next: false)

        #expect(second.items == ["a", "x", "y", "b", "c"])
        #expect(second.marks == [false, true, true, false, false])
    }

    @Test func playNextGoesRightAfterTheCurrentSong() {
        let first = Player.inserting(["a", "b", "c"], [false, false, false], at: 0, ["x"], next: false)
        let next = Player.inserting(first.items, first.marks, at: first.index, ["y"], next: true)

        #expect(next.items == ["a", "y", "x", "b", "c"])
    }

    @Test func aSongAddedTwiceMovesAndKeepsTheCurrentSong() {
        let added = Player.inserting(["a", "b", "c", "d"], [false, false, false, false], at: 2, ["a", "c", "d"], next: false)

        #expect(added.items == ["b", "c", "a", "d"])
        #expect(added.index == 1)
        #expect(added.marks == [false, false, true, true])
    }

    @Test func theQueuePageKeepsItsKey() {
        #expect(Page(key: Page.queue.key) == .queue)
        #expect(Page.queue.title == "Queue")
        #expect(Navigation(page: .queue).lyrics)
    }
}
