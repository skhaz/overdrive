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

    @Test func aReadWithNothingKownDropsNothing() {
        let keys: Set<String> = [Loves.key("Death", "Bloodcraft"), Loves.key("Krisiun", "Blood of Lions")]

        #expect(Loves.dropped(keys, [], []).isEmpty)
        #expect(Loves.dropped([], [], []).isEmpty, "an account with no loves mirrors nothing")
    }

    @Test func aReadUnlikesWhatLastFMDropped() {
        let known: Set<String> = [Loves.key("Death", "Bloodcraft"), Loves.key("Slayer", "Raining Blood")]
        let gone = Loves.dropped([Loves.key("Death", "Bloodcraft")], known, [])

        #expect(gone == [Loves.key("Slayer", "Raining Blood")], "an unlove on the website reaches the app")
    }

    @Test func aReadNeverFightsAWishInTheAir() {
        let flying = Loves.key("Death", "Bloodcraft")

        #expect(Loves.dropped([], [flying], [flying]).isEmpty, "an unlove the user just asked for is not undone by the read")
        #expect(Loves.dropped([flying], [], [flying]).isEmpty, "and a love on its way up is not read as a stranger")
    }

    @Test func anEmptyReadUnlikesEverythingKnown() {
        let known: Set<String> = [Loves.key("A", "B"), Loves.key("C", "D")]

        #expect(Loves.dropped([], known, []) == known.sorted(), "a full but empty answer is an answer")
        #expect(Loves.dropped([], [], []).isEmpty, "nothing known, nothing to drop")
    }

    @Test func aConfirmedWriteSurvivesAReadBehind() {
        let key = Loves.key("Death", "Bloodcraft")

        #expect(Loves.dropped([Loves.key("Slayer", "Raining Blood")], [key], [key]).isEmpty, "a love the app just confirmed is not unliked by a server that has not caught up")
        #expect(Loves.dropped([Loves.key("Death", "Bloodcraft")], [], [key]).isEmpty, "and an unlove the app just confirmed is not put on the drop list by a stale read")
    }

    @Test func aScanReAppliesTheMirrorWithoutARequest() throws {
        let app = try source("Overdrive.swift")
        let loaded = region(app, "library.loaded = { [unowned library] complete in", "\n        }\n")

        #expect(!loaded.isEmpty, "the app must wire the sync into the scan")
        #expect(loaded.contains("loves.apply()"), "every completed scan re-applies the mirror, so a loved song that arrives later is liked with no read")
        #expect(loaded.contains("guard complete else { return }"), "and only a complete one: a partial library is not a mirror yet")
        #expect(loaded.contains("loves.arrive()"), "the first complete scan also syncs")
        #expect(loaded.range(of: "loves.apply()")!.lowerBound < loaded.range(of: "loves.arrive()")!.lowerBound, "the local pass runs before the network, so it costs no wait")
    }

    @Test func theLocalHalfIsTheOnlyPlaceThatTouchesTheLikes() throws {
        let loves = try source("Loves.swift")
        let settle = body(loves, "private func settle(_ dropped: [String], _ resolved: [(key: String, track: Track)] = []) {")

        #expect(!settle.isEmpty, "the local pass must be there")
        #expect(settle.contains("likes.add(added, notify: false)"), "a loved song is liked without pushing it back")
        #expect(settle.contains("likes.remove(gone, notify: false)"), "and dropped the same way")
        #expect(settle.contains("for key in unresolved where !held.contains(key)"), "the pass walks what the library cannot hold yet, so a song that arrives later is picked up")
        #expect(settle.contains("!likes.contains(track)"), "an already liked song is not queued again")
        #expect(settle.contains("guard let track = hold(key)"), "the scan pass uses the exact name, so it costs two dictionary reads per key")
        #expect(settle.contains("hold(key) ?? loose(key)"), "a drop resolves the same way a like did")
        #expect(body(loves, "func apply() {").contains("settle([])"), "a scan re-applies the mirror with no request")
        #expect(body(loves, "private func absorb(_ keys: Set<String>, whole: Bool) {").contains("settle(gone, matched)"), "and a read drops what the server let go through the same door")
        #expect(!settle.contains("await"), "the local half never waits on the network")
    }

    @Test func aScanWalksOnlyWhatTheLibraryCannotHold() throws {
        let loves = try source("Loves.swift")
        let settle = body(loves, "private func settle(_ dropped: [String], _ resolved: [(key: String, track: Track)] = []) {")

        #expect(settle.contains("if !primed {"), "the first pass of a launch builds the list of waiting keys")
        #expect(settle.contains("unresolved = mirror"), "and it is the whole mirror then")
        #expect(settle.contains("unresolved.subtract(settled)"), "a key that found its song leaves, so no scan pays for it again")
        #expect(settle.contains("guard let track = hold(key) else { continue }"), "a key with no song waits for a later scan")
        #expect(!settle.contains("for key in mirror"), "and no pass walks the whole mirror again")
    }

    @Test func theMirrorIsTheServerPlusOurWishesAndNeverFightsThem() throws {
        let loves = try source("Loves.swift")
        let mirror = body(loves, "var mirror: Set<String> {")
        let absorb = body(loves, "private func absorb(_ keys: Set<String>, whole: Bool) {")

        #expect(mirror.contains("if wish {\n                pool.insert(key)"), "an outstanding love rides on top of the server list")
        #expect(mirror.contains("pool.remove(key)") && mirror.contains("} else {"), "an outstanding unlove is taken out of it")
        #expect(!absorb.contains("remote.insert"), "the server list stays the server alone")
        #expect(absorb.contains("for (key, wish) in wishes where wish == keys.contains(key) { wishes.removeValue(forKey: key) }"), "a wish clears only when the server agrees with its direction")
        #expect(body(loves, "private func drain() async {").contains("wishes[key] = entry.love"), "a confirmed write becomes a wish, not a server fact")
        #expect(!body(loves, "private func drain() async {").contains("remote.insert"), "and never pretends to be the server list")
    }

    @Test func aRejectedNameIsOnlyHeldBackWhereTheServerSaidNo() throws {
        let loves = try source("Loves.swift")
        let drain = body(loves, "private func drain() async {")

        #expect(drain.contains("rejected.insert(key)"), "a name the server refuses does not go up again")
        #expect(drain.contains("} else if entry.love {"), "only a refused love is a refused name")
        #expect(drain.contains("wishes[key] = false"), "an unlove of a song that was not loved upstream is already where the user wants it")
        #expect(!drain.contains("rejected.insert(key)\n            } else {\n                wishes[key] = false"), "and it never poisons a future love")
        #expect(body(loves, "private func push() {").contains("!rejected.contains(key)"), "the automatic push respects the refusal")
        #expect(body(loves, "private func local(_ tracks: [Track], _ love: Bool) {").contains("flight"), "a wish the user made does not")
    }

    @Test func theFuzzyWalkRunsOncePerKeyOnTheReadThatBringsIt() throws {
        let loves = try source("Loves.swift")
        let absorb = body(loves, "private func absorb(_ keys: Set<String>, whole: Bool) {")

        #expect(absorb.contains("let fresh = keys.subtracting(known).subtracting(held)"), "only a key the mirror did not have is walked")
        #expect(absorb.contains("hold(key) == nil, let track = self.loose(key)"), "and only when its exact name is not in the library")
        #expect(absorb.contains("loved(folded:") || body(loves, "private func loose(_ key: String) -> Track? {").contains("loved(folded:"), "the walk itself lives in one place")
        #expect(!body(loves, "func apply() {").contains("loose"), "a scan never pays for it")
    }

    @Test func theFastReadIsOneRequestUntilTheCountDisagrees() throws {
        let loves = try source("Loves.swift")
        let newest = body(loves, "private func newest() async -> Read {")
        let every = body(loves, "private func every() async -> Read {")

        #expect(newest.contains("fetch(1, Loves.window)"), "the fast read asks for one page of the newest songs")
        #expect(newest.contains("let added = keys.subtracting(remote)"), "and it costs what the page holds, not the whole mirror")
        #expect(newest.contains("first.total == remote.count + added.count"), "the count the server reports is what says the cache is current")
        #expect(newest.contains("return await every()"), "anything the count cannot explain is read in full")
        #expect(every.contains("fetch(number, LastFM.wide)"), "a whole read takes the big pages")
        #expect(every.contains("answer.pages <= LastFM.pages"), "and a list past the cap is not taken for the whole truth")
        #expect(every.contains("absorb(Set(loved.map"), "only the whole list can drop a love")
        #expect(body(loves, "private func pull(full: Bool) async -> Read {").contains("guard !full, !remote.isEmpty else { return await every() }"), "a cache with no mirror or a sync asked for in full reads everything")
    }

    @Test func theFileMenuForcesTheWholeListAndPagesIt() throws {
        let app = try source("Overdrive.swift")
        let item = region(app, "Button(\"Sync Liked Songs from Last.fm\"", "\n            }")

        #expect(!item.isEmpty, "the File menu must offer the sync")
        #expect(item.contains("action: loves.syncNow"), "and it goes through the same sync as Settings")
        #expect(item.contains(".disabled(loves.syncing || lastFM.user.isEmpty)"), "dimmed while it runs and with no account")

        let loves = try source("Loves.swift")
        #expect(body(loves, "func syncNow() {").contains("sync(full: true)"), "the command asks for the whole list, not the fast page")
        #expect(body(loves, "private func every() async -> Read {").contains("fetch(number, LastFM.wide)"), "and the whole list is read page by page")
    }

    @Test func aLikeMadeInTheAppIsSavedAndSentAtOnce() throws {
        let loves = try source("Loves.swift")
        let local = body(loves, "private func local(_ tracks: [Track], _ love: Bool) {")

        #expect(local.contains("pending = next"), "a like the user makes is in the app before the network")
        #expect(local.contains("save()"), "and it is on the disk before the request")
        #expect(local.contains("Task { await drain() }"), "the write goes up at once")
        #expect(body(loves, "private func push() {").contains("local(raised, true)"), "a like that predates the account goes up through the same door")
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
        let newest = body(loves, "private func newest() async -> Read {")
        let guardBlock = inner(newest, "guard let first = await fetch(1, Loves.window) else {")

        #expect(guardBlock.contains("pull stopped"), "a read with no answer leaves the mirror alone")
        #expect(!guardBlock.contains("remote ="), "and never looks like an unlove")
        #expect(!guardBlock.contains("absorb"), "and never reaches the cache")
        #expect(!guardBlock.contains("likes."), "and never touches the local list")
        #expect(body(loves, "private func every() async -> Read {").contains("reason\": \"too many pages\""), "a list past the cap is not the whole truth either")
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

    /// The text between a signature and the first `end` after it, or empty when the
    /// signature is gone, so a wired call cannot pass by accident.
    private func region(_ source: String, _ signature: String, _ end: String) -> String {
        guard let start = source.range(of: signature) else { return "" }
        let rest = source[start.lowerBound...]
        guard let stop = rest.range(of: end) else { return String(rest) }

        return String(rest[..<stop.upperBound])
    }
}
