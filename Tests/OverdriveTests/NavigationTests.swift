import Testing
@testable import Overdrive

struct NavigationTests {
    @Test func goesBackAndForward() {
        var history = History<String>()
        history.visit(from: "albums", to: "album")
        history.visit(from: "album", to: "artist")

        #expect(history.goBack(from: "artist") == "album")
        #expect(history.goBack(from: "album") == "albums")
        #expect(history.goBack(from: "albums") == nil)
        #expect(history.goForward(from: "albums") == "album")
        #expect(history.goForward(from: "album") == "artist")
        #expect(history.goForward(from: "artist") == nil)
    }

    @Test func newVisitClearsForward() {
        var history = History<String>()
        history.visit(from: "albums", to: "album")
        _ = history.goBack(from: "album")
        history.visit(from: "albums", to: "songs")

        #expect(history.forward.isEmpty)
        #expect(history.back == ["albums"])
    }

    @Test func ignoresVisitToSamePlace() {
        var history = History<String>()
        history.visit(from: "albums", to: "albums")

        #expect(history.back.isEmpty)
    }

    @Test func removesDeletedPlaces() {
        var history = History<String>()
        history.visit(from: "mix", to: "albums")
        history.visit(from: "albums", to: "songs")
        _ = history.goBack(from: "songs")
        history.removeAll { $0 == "mix" || $0 == "songs" }

        #expect(history.back.isEmpty)
        #expect(history.forward.isEmpty)
    }

    @Test func stepsInList() {
        #expect(Step.down.index(first: nil, last: nil, count: 5, columns: 1) == 0)
        #expect(Step.up.index(first: nil, last: nil, count: 5, columns: 1) == 4)
        #expect(Step.down.index(first: 4, last: 4, count: 5, columns: 1) == 4)
        #expect(Step.up.index(first: 0, last: 0, count: 5, columns: 1) == 0)
        #expect(Step.down.index(first: 1, last: 3, count: 5, columns: 1) == 4)
        #expect(Step.up.index(first: 1, last: 3, count: 5, columns: 1) == 0)
        #expect(Step.left.index(first: 2, last: 2, count: 5, columns: 1) == nil)
        #expect(Step.down.index(first: nil, last: nil, count: 0, columns: 1) == nil)
    }

    @Test func stepsInGrid() {
        #expect(Step.down.index(first: 1, last: 1, count: 10, columns: 4) == 5)
        #expect(Step.down.index(first: 8, last: 8, count: 10, columns: 4) == 9)
        #expect(Step.up.index(first: 5, last: 5, count: 10, columns: 4) == 1)
        #expect(Step.up.index(first: 2, last: 2, count: 10, columns: 4) == 0)
        #expect(Step.left.index(first: 5, last: 5, count: 10, columns: 4) == 4)
        #expect(Step.right.index(first: 9, last: 9, count: 10, columns: 4) == 9)
    }

    @Test func extendsSelection() {
        #expect(Step.extendDown.index(first: 1, last: 2, count: 5, columns: 1) == 3)
        #expect(Step.extendUp.index(first: 1, last: 2, count: 5, columns: 1) == 0)
        #expect(Step.extendUp.index(first: 0, last: 2, count: 5, columns: 1) == nil)
        #expect(Step.extendDown.index(first: 0, last: 4, count: 5, columns: 1) == nil)
        #expect(Step.extendDown.index(first: nil, last: nil, count: 5, columns: 1) == nil)
    }
}

struct SwipeTests {
    @Test func detectsDirection() {
        var swipe = Swipe()
        swipe.begin()
        for _ in 0..<10 { swipe.move(20, 1) }
        #expect(swipe.end() == .back)

        swipe.begin()
        for _ in 0..<10 { swipe.move(-20, 1) }
        #expect(swipe.end() == .forward)
    }

    @Test func ignoresShortAndVerticalGestures() {
        var swipe = Swipe()
        swipe.begin()
        swipe.move(100, 0)
        #expect(swipe.end() == nil)

        swipe.begin()
        for _ in 0..<10 { swipe.move(20, 15) }
        #expect(swipe.end() == nil)
    }

    @Test func needsBegin() {
        var swipe = Swipe()
        for _ in 0..<10 { swipe.move(20, 0) }
        #expect(swipe.end() == nil)

        swipe.begin()
        for _ in 0..<10 { swipe.move(20, 0) }
        swipe.cancel()
        #expect(swipe.end() == nil)
    }
}
