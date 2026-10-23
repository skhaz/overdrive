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

    @Test func theQueuePageKeepsItsKey() {
        #expect(Page(key: Page.queue.key) == .queue)
        #expect(Page.queue.title == "Queue")
        #expect(Navigation(page: .queue).lyrics)
    }
}
