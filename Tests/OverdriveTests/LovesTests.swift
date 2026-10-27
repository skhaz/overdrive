import Foundation
import Testing
@testable import Overdrive

struct LovesTests {
    private func love(_ artist: String, _ title: String) -> LastFM.Loved {
        LastFM.Loved(artist: artist, title: title)
    }

    private func entry(_ artist: String, _ title: String, _ wish: Bool) -> Loves.Entry {
        Loves.Entry(artist: artist, title: title, love: wish)
    }

    @Test func theKeyFoldsAndHoldsNoPath() {
        let key = Loves.key("Ratos de Porão", "Amor Exigido")

        #expect(key == "ratos de porao\u{1F}amor exigido")
        #expect(Loves.key("RATOS DE PORÃO", "AMOR EXIGIDO") == key, "case and accents are the same song")
        #expect(Loves.key("A", "B") != Loves.key("A\u{1FB}", "B"), "the separator keeps the two parts apart")

        let here = Track(url: URL(fileURLWithPath: "/Music/Death/Individual Thought Patterns/02 - In Human Form.mp3"),
                         title: "In Human Form", artist: "Death", album: "Individual Thought Patterns", number: 2, disc: 1,
                         albumArtist: "Death", year: 1995, duration: 200, albumID: "x")
        let there = here.at(URL(fileURLWithPath: "/Backup/elsewhere/02 - In Human Form.mp3"))

        #expect(Loves.key(here) == Loves.key(there), "the key is the song, not the file: a moved library keeps its loved tracks")
        #expect(!Loves.key(here).contains("In Human Form.mp3"), "and it holds no file name either")
    }

    @Test func theSameWishTwiceIsOneWish() {
        let a = entry("Death", "Bloodcraft", true)

        #expect(Loves.queued([], a, nil) == [a])
        #expect(Loves.queued([a], a, nil) == [a], "liking a song that is already waiting to be liked does not queue it twice")
        #expect(Loves.queued([a, entry("Krisiun", "Blood of Lions", true)], a, nil).count == 2, "the other wishes stay")
    }

    @Test func theOppositeWishCancelsItself() {
        let like = entry("Death", "Bloodcraft", true)
        let unlike = entry("Death", "Bloodcraft", false)

        #expect(Loves.queued([like], unlike, nil).isEmpty, "a like that never left and is undone needs no request")
        #expect(Loves.queued([unlike], like, nil).isEmpty, "and the other way round")
        #expect(Loves.queued(Loves.queued([], like, nil), unlike, nil).isEmpty)
    }

    @Test func aWishOnItsWayIsReplacedNotDropped() {
        let like = entry("Death", "Bloodcraft", true)
        let unlike = entry("Death", "Bloodcraft", false)
        let flying = Loves.key(like)

        #expect(Loves.queued([like], unlike, flying) == [unlike], "the love is already sent, so the unlove must go up after it")
        #expect(Loves.queued([entry("A", "One", true), like], unlike, flying) == [entry("A", "One", true), unlike], "and it keeps its place in the queue")
        #expect(Loves.queued([like], like, flying) == [like], "the same wish twice is still one wish, even in flight")
    }

    @Test func theLastWishWins() {
        let like = entry("Death", "Bloodcraft", true)
        let unlike = entry("Death", "Bloodcraft", false)
        let again = entry("Death", "Bloodcraft", true)

        #expect(Loves.queued(Loves.queued(Loves.queued([], like, nil), unlike, nil), again, nil) == [again], "three wishes leave the last one")
    }

    @Test func theQueueKeepsItsOrder() {
        let first = entry("A", "One", true)
        let second = entry("B", "Two", true)
        let third = entry("C", "Three", false)

        #expect(Loves.queued(Loves.queued(Loves.queued([], first, nil), second, nil), third, nil) == [first, second, third])
        #expect(Loves.queued(Loves.queued([first, second], first, nil), second, nil) == [first, second], "a repeat does not move the wish")
    }

    @Test func aCancelledWishLeavesTheRestOfTheQueueAlone() {
        let a = entry("A", "One", true)
        let b = entry("B", "Two", true)
        let c = entry("C", "Three", true)
        let queue = [a, b, c]

        let kept = Loves.queued(queue, entry("B", "Two", false), nil)

        #expect(kept == [a, c], "cancelling the middle wish keeps the others")
        #expect(kept.allSatisfy { Loves.key($0) != Loves.key(b) }, "and the cancelled song is gone, not left behind")
    }

    @Test func aReadAddsWhatTheAppDoesNotKnow() {
        let read = Loves.reconcile([love("Death", "Bloodcraft"), love("Krisiun", "Blood of Lions")], [], [])

        #expect(read.add.map(\.title) == ["Bloodcraft", "Blood of Lions"], "the remote order is kept")
        #expect(read.gone.isEmpty)
        #expect(read.fresh == [Loves.key("Death", "Bloodcraft"), Loves.key("Krisiun", "Blood of Lions")])
    }

    @Test func aReadUnlikesWhatLastFMDropped() {
        let known: Set<String> = [Loves.key("Death", "Bloodcraft"), Loves.key("Slayer", "Raining Blood")]
        let read = Loves.reconcile([love("Death", "Bloodcraft")], known, [])

        #expect(read.add.isEmpty, "a song the app already knows is not liked again")
        #expect(read.gone == [Loves.key("Slayer", "Raining Blood")], "an unlove on the website reaches the app")
        #expect(read.fresh == [Loves.key("Death", "Bloodcraft")])
    }

    @Test func aReadNeverFightsAWishInTheAir() {
        let flying = Loves.key("Death", "Bloodcraft")
        let known: Set<String> = [flying]

        let unlove = Loves.reconcile([], known, [flying])
        #expect(unlove.gone.isEmpty, "an unlove the user just asked for is not undone by the read")
        #expect(unlove.fresh.isEmpty, "and the mirror follows the server, not the wish")

        let like = Loves.reconcile([love("Death", "Bloodcraft")], [], [flying])
        #expect(like.add.isEmpty, "a like the user just asked for is not pushed back as a new song")
        #expect(like.fresh == [flying])
    }

    @Test func anEmptyReadUnlikesEverythingKnown() {
        let known: Set<String> = [Loves.key("A", "B"), Loves.key("C", "D")]

        #expect(Loves.reconcile([], known, []).gone == known.sorted(), "a full but empty answer is an answer")
        #expect(Loves.reconcile([], [], []).gone.isEmpty, "nothing known, nothing to drop")
    }

    @Test func aConfirmedWriteSurvivesAReadBehind() {
        let key = Loves.key("Death", "Bloodcraft")

        let liked = Loves.reconcile([love("Slayer", "Raining Blood")], [key], [key])
        #expect(liked.gone.isEmpty, "a love the app just confirmed is not unliked by a server that has not caught up")
        #expect(liked.fresh == [Loves.key("Slayer", "Raining Blood")], "but the mirror still follows the server")

        let unliked = Loves.reconcile([love("Death", "Bloodcraft")], [], [key])
        #expect(unliked.add.isEmpty, "and an unlove the app just confirmed is not put back by a stale read")
    }

    @Test func theLedgerRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "LovesLedger-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }

        let ledger = Loves.Ledger(remote: [Loves.key("Death", "Bloodcraft")], pending: [entry("Krisiun", "Blood of Lions", true)])
        #expect(Persist.write(try #require(Persist.encode(ledger, for: url)), to: url))
        #expect(Persist.read(Loves.Ledger.self, from: url) == ledger)
        #expect(Persist.read(Loves.Ledger.self, from: url.appendingPathExtension("missing")) == nil, "a missing file is normal")
    }

    @Test func theFileIsInTheAppFolder() {
        #expect(Loves.file.path.hasSuffix("Overdrive/Loves.plist"))
        #expect(!Loves.file.path.contains("Music"), "the ledger is not music data: it is about the account, not the folder")
    }

    @Test func theSyncIsOfferedOnlyWithAnAccount() throws {
        let loves = try source("Loves.swift")

        #expect(loves.contains("!lastFM.user.isEmpty"), "no user means no request")
        #expect(loves.contains("!library.albums.isEmpty"), "an empty library is not a mirror yet")
        #expect(loves.contains("guard !syncing else {"), "one sync at a time")
        #expect(loves.contains("guard !draining else {"), "one push at a time")
        #expect(loves.contains("guard !pulling else {"), "one read at a time")
        #expect(loves.contains("guard !arrived else {"), "the boot sync runs once")
    }

    @Test func aFailedReadChangesNothing() throws {
        let loves = try source("Loves.swift")
        let guardBlock = inner(loves, "guard let loved else {")

        #expect(guardBlock.contains("pull stopped"), "a read that is not the whole truth leaves the mirror alone")
        #expect(!guardBlock.contains("remote ="), "and never looks like an unlove")
        #expect(!guardBlock.contains("likes."), "and never touches the local list")
    }

    @Test func theWritesAreSpacedAndHeldOnFailure() throws {
        let loves = try source("Loves.swift")
        let drain = body(loves, "private func drain() async {")

        #expect(loves.contains("gap = Duration.milliseconds(300)"), "one love write at a time, with a pause between them")
        #expect(drain.contains("guard outcome != .retry else {"), "an unconfirmed write stays in the queue")
        #expect(drain.contains("if let at = pending.firstIndex(of: entry) { pending.remove(at: at) }"), "a wish is taken out by its own value, so a queue that shrank during the request cannot read past the end")
        #expect(drain.contains("flight = key"), "the wish on its way is marked, so it can be replaced and not dropped")
        #expect(drain.contains("flight = nil"), "and the mark is cleared before the queue is touched again")
        #expect(!drain.contains("removeFirst"), "no index cursor over a queue that moves")
        #expect(drain.contains("try? await Task.sleep(for: Loves.gap)"), "and the next write waits for the gap")
    }

    @Test func thePullTellsTheLibraryAboutTheAccount() throws {
        let loves = try source("Loves.swift")

        #expect(loves.contains("likes.add(added, notify: false)"), "a song from Last.fm is liked without pushing it back")
        #expect(loves.contains("likes.remove(gone, notify: false)"), "and dropped the same way")
        #expect(body(loves, "private func local(_ tracks: [Track], _ love: Bool) {").contains("Task { await drain() }"), "a like the user made goes up at once")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }

    private func body(_ source: String, _ signature: String) -> String {
        guard let start = source.range(of: signature) else { return "" }
        let rest = source[start.upperBound...]
        return String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
    }

    private func inner(_ source: String, _ signature: String) -> String {
        guard let start = source.range(of: signature) else { return "" }
        let rest = source[start.upperBound...]
        return String(rest[..<(rest.range(of: "\n        }\n")?.lowerBound ?? rest.endIndex)])
    }
}
