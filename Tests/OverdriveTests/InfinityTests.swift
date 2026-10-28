import Foundation
import Testing
@testable import Overdrive

@MainActor
@Suite(.serialized)
struct InfinityTests {
    func track(_ title: String, _ artist: String) -> Track {
        Track(url: URL(fileURLWithPath: "/m/\(artist)/\(title).mp3"), title: title, artist: artist, album: "Album", number: 1, disc: 1,
              albumArtist: "", year: 2000, duration: 200, albumID: "x")
    }

    // MARK: - the buffer rule

    @Test func aFillRunsWhenTheBufferIsBelowWhatTheModeKeeps() {
        #expect(Player.needs(ahead: 0, kept: Infinity.keep), "an empty list is always below the buffer")
        #expect(Player.needs(ahead: Infinity.keep - 1, kept: Infinity.keep))
        #expect(!Player.needs(ahead: Infinity.keep, kept: Infinity.keep), "a full buffer needs no request")
        #expect(!Player.needs(ahead: Infinity.keep + 5, kept: Infinity.keep))
        #expect(Infinity.batch == Infinity.keep, "one fill tops the buffer up, so a second fill cannot be needed at once")
        #expect(Infinity.batch == 20, "20 songs at a time, as the user allowed")
        #expect(Infinity.asks == 60, "one fill never walks the whole chart")
    }

    @Test func theBufferCountsTheSongsAfterTheOneThatPlays() {
        #expect(Player.ahead(30, index: 9) == 20, "30 songs, the 10th plays, 20 are ahead")
        #expect(Player.ahead(30, index: 29) == 0, "the last song of the list has nothing ahead")
        #expect(Player.ahead(30, index: 30) == 0, "and a list that ended is not negative")
        #expect(Player.ahead(0, index: 0) == 0)
    }

    @Test func oneTickInFiveCannotStartASecondFill() {
        #expect(Infinity.pause(on: false, flight: false, ahead: 0, kept: Infinity.keep) == .off, "a mode that is off spends no request")
        #expect(Infinity.pause(on: false, flight: true, ahead: 0, kept: Infinity.keep) == .off, "and it does not care about a fill it already stopped")
        #expect(Infinity.pause(on: true, flight: true, ahead: 0, kept: Infinity.keep) == .filling, "a fill in flight is never doubled by the next tick")
        #expect(Infinity.pause(on: true, flight: false, ahead: Infinity.keep, kept: Infinity.keep) == .full, "a full buffer needs no fill")
        #expect(Infinity.pause(on: true, flight: false, ahead: Infinity.keep + 9, kept: Infinity.keep) == .full)
        #expect(Infinity.pause(on: true, flight: false, ahead: Infinity.keep - 1, kept: Infinity.keep) == .now, "a low buffer starts one")
        #expect(Infinity.pause(on: true, flight: false, ahead: 0, kept: Infinity.keep) == .now, "and so does an empty list")
    }

    @Test func aFillThatFoundNoArtistStartsTheLibraryOver() {
        #expect(Infinity.cycles(pool: 0, served: 20), "every song of the library played, so the cycle begins again")
        #expect(!Infinity.cycles(pool: 3, served: 20), "artists are left, so the fill asks them")
        #expect(!Infinity.cycles(pool: 0, served: 0), "a library with no song never cycles: there is nothing to start over")
        #expect(!Infinity.cycles(pool: 20, served: 0))
    }

    // MARK: - the draw

    @Test func theArtistsAreDrawnFromTheLibraryPool() {
        let pool = (0..<100).map { (name: "Artist \($0)", songs: [track("Song \($0)", "Artist \($0)")]) }

        for index in pool.indices where index < 10 {
            #expect(Discovery.drawn(pool, 1, using: { _ in index }).first?.name == pool[index].name, "any artist of the library can be the one")
        }

        let head = Discovery.drawn(pool, 20, using: { _ in 0 })
        #expect(head.first?.name == "Artist 0", "each draw takes one artist out of the pool")
        #expect(Set(head.map(\.name)).count == 20, "and never the same artist twice")
        #expect(Set(Discovery.drawn(pool, 50, using: { _ in 3 }).map(\.name)).count == 50, "an artist never comes twice in one fill")
        #expect(Discovery.drawn(pool, 200, using: { _ in 0 }).count == 100, "a pool of 100 artists gives 100, not 200")
        #expect(Discovery.drawn(pool, min(Infinity.asks, pool.count), using: { _ in 0 }).count == Infinity.asks, "the cap of one fill is the cap of the draw")
        #expect(Discovery.drawn([(name: "A", songs: [] as [Track])], 5, using: { _ in 0 }).count == 1, "an entry with no song is still one draw, it never traps")
        #expect(Discovery.drawn(pool, 0, using: { _ in 0 }).isEmpty)
        #expect(Discovery.drawn([] as [(name: String, songs: [Track])], 5, using: { _ in 0 }).isEmpty)
    }

    @Test func anArtistWhoseSongsAllPlayedLeavesThePool() {
        let krisiun = (1...3).map { track("Blood of Lions \($0)", "Krisiun") }
        let death = (1...2).map { track("Individual Thought \($0)", "Death") }
        let morra = [track("Sábado de Sol", "Morra")]
        let groups = [krisiun, death, morra]

        let all = Library.pool(groups, excluding: [])
        #expect(all.count == 3, "one entry per artist")
        #expect(Set(all.map(\.name)) == Set(["Krisiun", "Death", "Morra"]), "the spelling of the tags is what the service is asked")
        #expect(all.allSatisfy { entry in entry.songs.count == groups.first { $0.first?.artist == entry.name }?.count })

        let rest = Library.pool(groups, excluding: Set(krisiun.map(\.id)))
        #expect(rest.count == 2, "an artist whose songs all played is out of the pool")
        #expect(!rest.contains { $0.name == "Krisiun" })

        let partly = Library.pool(groups, excluding: [death[0].id])
        #expect(partly.first { $0.name == "Death" }?.songs.count == 1, "an artist that played partly keeps the songs it did not")
        #expect(partly.count == 3)

        #expect(Library.pool(groups, excluding: Set(all.flatMap(\.songs).map(\.id))).isEmpty, "a library where everything played has no pool, so the cycle starts again")
        #expect(Library.pool([], excluding: []).isEmpty, "no library, no pool")
        #expect(Library.pool([[track("X", "Y")]], excluding: []).first?.songs.count == 1)
    }

    // MARK: - the wiring

    @Test func theSongHalfFiresOncePerSongAndEveryListResetsIt() throws {
        let player = try source("Player.swift")
        let tick = body(player, "private func tick(_ seconds: Double) {")

        #expect(tick.contains("if !halved, track.duration > 0, played * 2 >= track.duration {"), "the halfway point is the half of the song, not a fixed time")
        #expect(tick.components(separatedBy: "halfway?()").count - 1 == 1, "one call per song")
        #expect(tick.contains("halved = true"), "and it is remembered, so a tick every half second spends nothing")
        #expect(tick.range(of: "halved = true")!.lowerBound < tick.range(of: "scrobbled = true")!.lowerBound, "the fill is asked before the scrobble, so a slow answer still arrives in time")

        for signature in ["private func begin() {", "private func stop() {"] {
            #expect(try body(player, signature).contains("halved = false"), "\(signature) must arm the next song again")
        }

        #expect(player.contains("resets?(\"new list\")"), "a list that replaces the player stops the mode")
        #expect(player.contains("resets?(\"list ended\")"), "so does a list that ended")
        #expect(player.contains("resets?(\"cleared\")"), "and a Clear Up Next")
        #expect(body(player, "func play(_ tracks: [Track], at start: Int = 0) {").range(of: "resets?(")!.lowerBound < body(player, "func play(_ tracks: [Track], at start: Int = 0) {").range(of: "order = tracks")!.lowerBound,
                "the mode is told before the new list is in place, so no fill of the old one lands on it")
    }

    @Test func anAppendMovesNothingAndNeverStartsAList() throws {
        let player = try source("Player.swift")
        let append = body(player, "func append(_ tracks: [Track]) {")

        #expect(append.contains("queue += tracks"), "a fill goes at the end of the list")
        #expect(append.contains("added += Array(repeating: false, count: tracks.count)"), "the new songs are not marked as added to Up Next, they are the mode's own")
        for untouched in ["index", "head", "item", "upcoming", "position", "playing"] {
            #expect(!append.contains("\(untouched) ="), "an append never touches \(untouched): the song that plays is not interrupted")
        }
        #expect(append.contains("guard current != nil else { return Log.player.debug(\"append ignored\", metadata: [\"reason\": \"no song\"]) }"),
                "a fill never starts playing on its own, only the user starts a list")
        #expect(append.contains("guard !tracks.isEmpty else {"), "and an empty answer changes nothing")
        #expect(append.contains("origin = []"), "an edit of a shuffled list clears the shuffle map, as insert and move do")
        #expect(append.contains("order += tracks"), "with shuffle on the new songs go to the end of the play order")
        #expect(append.contains("order = queue"), "with shuffle off the list is the order")
        #expect(append.contains("save()"), "a fill that survives a crash survives in the session")
    }

    @Test func theModeStartsThroughTheOneDoorAndStopsWithTheList() throws {
        let infinity = try source("Infinity.swift")
        let fill = body(infinity, "private func fill(at why: String) async {")

        #expect(fill.contains("player.random(songs)"), "the start plays the first song, as every discovery pool does")
        #expect(fill.contains("player.append(songs)"), "and a refill only adds to the end")
        #expect(fill.range(of: "guard on else {")!.lowerBound < fill.range(of: "player.random(songs)")!.lowerBound,
                "an answer that arrived after the mode stopped touches no player")
        #expect(fill.contains("starting = false"), "the start mark clears, so the next list does stop the mode")
        #expect(body(infinity, "func stopped(_ reason: String) {").contains("guard !starting else {"), "the mode survives the list it just started")
        #expect(body(infinity, "func toggle() {").contains("starting = true"), "and it marks that start")
        #expect(body(infinity, "func toggle() {").contains("guard discovery.ready else {"), "a click with no account is refused before any request")
        let passed = body(infinity, "func passed() {")

        #expect(passed.contains("Infinity.pause(on: on, flight: flight != nil, ahead: player.ahead, kept: Infinity.keep)"), "the tick asks the rule, it does not invent one")
        #expect(passed.components(separatedBy: "flight = Task").count - 1 == 1, "one door starts a fill")
        #expect(passed.range(of: "case .off:\n            return") != nil, "and an off mode returns from it without a log line of its own")
        #expect(body(infinity, "func off(_ reason: String) {").contains("flight?.cancel()"), "stopping cancels the fill in flight")
        #expect(body(infinity, "func off(_ reason: String) {").contains("served = []"), "and forgets what it played, for the next time")
        #expect(!body(infinity, "func off(_ reason: String) {").contains("player.remove"), "the songs already in the list stay: the user keeps what they heard")
        #expect(body(infinity, "private func draw() async -> [Track] {").contains("library.pool(excluding: served)"), "an artist whose songs all played is out before a request goes")
        #expect(body(infinity, "private func draw() async -> [Track] {").contains("Infinity.cycles(pool:"), "and the cycle is one rule, not a loop")
        #expect(body(infinity, "private func draw() async -> [Track] {").contains("Discovery.collect(Infinity.batch, wanted)"), "the fill walks the drawn artists four at a time, as a discovery does")
        #expect(body(infinity, "private func draw() async -> [Track] {").contains("fm.topTracks($0, Discovery.tracks)"), "the same top five of the same service")
        #expect(!infinity.contains("Persist."), "the mode is never written to the disk")
        #expect(!infinity.contains("Timer(") && !infinity.contains("Task.sleep"), "nothing polls: the player calls at the half of a song")
    }

    @Test func thePoolComesFromTheWholeLibraryNotTheSearch() throws {
        let library = try source("Library.swift")
        let pool = body(library, "func pool(excluding served: Set<Track.ID>) -> [(name: String, songs: [Track])] {")

        #expect(pool.contains("Library.pool(Array(bySong.values), excluding: served)"), "the groups are the ones the scan built, so a fill costs no walk of the library")
        #expect(!pool.contains("filtered") && !pool.contains("query"), "the search results are never the pool")
        #expect(body(library, "nonisolated static func pool(_ groups: [[Track]], excluding served: Set<Track.ID>)").contains("first.artist"), "the name the service is asked carries the spelling of the tags")
    }

    // MARK: - the menu

    @Test func theToggleIsInTheDiscoveryMenuAndNeedsAnAccount() throws {
        let menu = try discovery(try source("Views.swift"))

        #expect(menu.contains("Toggle(\"Infinity\", systemImage: \"infinity\", isOn: Binding { infinity.on } set: { _ in infinity.toggle() })"), "one item that turns the mode on and off")
        #expect(menu.contains(".disabled(!discovery.ready)"), "no key, no account, or no songs means no infinity")
        #expect(menu.range(of: "Divider()")!.lowerBound < menu.range(of: "Toggle(\"Infinity\"")!.lowerBound, "the endless mode is apart from the pickers that fill a list once")
        #expect(menu.components(separatedBy: "Toggle(\"Infinity\"").count - 1 == 1, "one door, not two")
    }

    @Test func everyHostOfTheDiscoveryMenuCarriesTheMode() throws {
        let app = try source("Overdrive.swift")

        let content = try #require(app.range(of: "ContentView()")).upperBound
        #expect(String(app[content...].prefix(700)).contains(".environment(infinity)"), "the window reads the discovery host, so the mode must be there too")

        let menu = try #require(app.range(of: "CommandMenu(\"Discovery\") {")).upperBound
        #expect(String(app[menu...].prefix(400)).contains(".environment(infinity)"), "the menu builds the toggle that reads it, or the app traps at launch")

        #expect(app.contains("player.halfway = { [weak infinity] in infinity?.passed() }"), "the player calls the mode at the half of a song")
        #expect(app.contains("player.resets = { [weak infinity] reason in infinity?.stopped(reason) }"), "and when a list takes its place")
        #expect(String(app[app.range(of: "let infinity = ")!.lowerBound...].prefix(300)).contains("discovery: discovery"), "the mode borrows the readiness rule of the pickers, so it is offered on the same terms")
    }

    // MARK: - helpers

    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }

    private func body(_ source: String, _ signature: String) -> String {
        guard let start = source.range(of: signature) else { return "" }
        let rest = source[start.upperBound...]

        return String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
    }

    private func discovery(_ source: String) throws -> String {
        let start = try #require(source.range(of: "struct DiscoveryMenu: View {")).upperBound
        let rest = source[start...]

        return String(rest[..<(try #require(rest.range(of: "\n}\n")).lowerBound)])
    }
}
