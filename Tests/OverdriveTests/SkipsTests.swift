import Foundation
import Testing
@testable import Overdrive

@MainActor
@Suite struct SkipsTests {
    private func track(_ path: String, _ title: String = "Song") -> Track {
        Track(url: URL(fileURLWithPath: path), title: title, artist: "Artist", album: "Album", number: 1, disc: 1,
              albumArtist: "Artist", year: 2020, duration: 100, albumID: "Album")
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OverdriveSkips-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        return URL(fileURLWithPath: Library.real(url))
    }

    @Test func theVetoSurvivesAReloadAndTravelsWithTheFolder() throws {
        let root = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: root) }
        let file = Skips.file(in: root)
        let first = track(root.appending(path: "A/one.mp3").path, "One")
        let second = track(root.appending(path: "A/two.mp3").path, "Two")

        let skips = Skips(file: file, folder: root)
        #expect(skips.paths.isEmpty)

        skips.add([first, first, second])
        Persist.flush()
        #expect(skips.count == 2, "a song the veto already holds is not written twice")
        #expect(skips.contains(first))

        let read = Skips(file: file, folder: root)
        #expect(read.paths == [first.url.path, second.url.path], "the order the user denied in comes back")
        #expect(read.contains(second))

        let stored = try #require(Persist.read([String].self, from: file))
        #expect(stored.allSatisfy { !$0.hasPrefix("/") }, "the file holds paths relative to the folder, so the library can move: \(stored)")
        #expect(stored.allSatisfy { $0.hasPrefix("A/") })

        let moved = root.deletingLastPathComponent().appending(path: "MovedSkips-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }

        let after = Skips(file: Skips.file(in: moved), folder: moved)
        #expect(after.count == 2, "a folder that moved keeps its denials, because the file moved with it")
        #expect(after.contains(track(moved.appending(path: "A/one.mp3").path, "One")))
    }

    @Test func nothingIsWrittenWhileTheFolderIsMissing() throws {
        let root = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: root) }
        let gone = root.appending(path: "NotMounted")
        let file = Skips.file(in: gone)
        let at: () -> URL? = { gone }
        let skips = Skips(file: { file }, folder: at)

        skips.add([track(gone.appending(path: "a.mp3").path)])
        Persist.flush()

        #expect(skips.count == 1, "the veto is in memory at once, so a discovery on a missing drive still respects it")
        #expect(!FileManager.default.fileExists(atPath: file.path), "and nothing is written to a folder that is not there")
    }

    @Test func theSameSongIsDeniedOnceAndAllowedOnce() throws {
        let root = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: root) }
        let one = track(root.appending(path: "a.mp3").path, "One")
        let two = track(root.appending(path: "b.mp3").path, "Two")
        let skips = Skips(file: Skips.file(in: root), folder: root)

        skips.add([one])
        #expect(skips.contains(one))

        skips.toggle([one])
        #expect(!skips.contains(one), "the same item that denies a song gives it back")

        skips.toggle([one, two])
        #expect(skips.contains(one) && skips.contains(two), "a group that is not wholly denied is denied whole")

        skips.toggle([one, two])
        #expect(!skips.contains(one) && !skips.contains(two), "and a wholly denied group is allowed whole")
        #expect(skips.count == 0)
    }

    @Test func theFilterKeepsEverySongTheUserWants() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let songs = (1...4).map { track(root.appending(path: "\($0).mp3").path, "Song \($0)") }
        let skips = Skips(file: Skips.file(in: root), folder: root)

        #expect(skips.allowed(songs) == songs, "with no veto the pool is the pool, not a copy of it")

        skips.add([songs[1], songs[3]])
        #expect(skips.allowed(songs) == [songs[0], songs[2]])
        #expect(skips.allowed([]).isEmpty, "an empty pool stays empty")
        #expect(skips.allowed([songs[1]]).isEmpty, "a song the user denied is no pool at all")
    }

    @Test func aFileThatIsNotAListIsReplacedNotCrashedOn() throws {
        let root = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: root) }
        let file = Skips.file(in: root)
        try Data("junk".utf8).write(to: file)

        let skips = Skips(file: file, folder: root)
        #expect(skips.paths.isEmpty, "a file that does not match the format is ignored, not read")

        skips.add([track(root.appending(path: "a.mp3").path)])
        Persist.flush()
        #expect(skips.count == 1, "and the app writes its own list over it")
    }

    @Test func everyDiscoveryDoorReadsTheVeto() throws {
        let discovery = try source("Discovery.swift")

        #expect(body(discovery, "private func start(_ picked: [Track], _ mine: Int, _ pool: Pool, _ count: Int, _ why: String?) {").contains("let tracks = skips.allowed(picked)"),
                "the one door every pool goes through filters the veto, so no picker can slip past it")
        #expect(body(discovery, "private func picked(_ pool: Pool, _ count: Int) -> [Track] {").contains("skips.count > 0"),
                "an empty veto costs nothing: the library pickers run unchanged")
        #expect(body(discovery, "private func picked(_ pool: Pool, _ count: Int) -> [Track] {").contains("skips.allowed(library.tracks)"),
                "and a veto that is not empty draws from the songs the user still wants")
        #expect(body(discovery, "static func allowed(_ pool: [(name: String, songs: [Track])], skipping skips: Skips)").contains("guard !held.isEmpty else { return nil }"),
                "an artist whose every song is denied never costs a request")
        #expect(discovery.contains("\"discovery denied\""), "a pick that lost songs to the veto says so")
        #expect(!discovery.contains("skips.add") && !discovery.contains("skips.remove"), "the discovery never sets the veto itself, only the user does")
    }

    @Test func theVetoIsTheUsersAndLivesWithTheCollection() throws {
        let skips = try source("Skips.swift")

        #expect(skips.contains("appending(path: \"Skip.plist\""), "the file travels with the library, next to Likes and Playlists")
        #expect(!skips.contains("Persist.read([String].self, from: location()) ?? []\n        denied"), "the load decodes once")
        #expect(body(skips, "private func save() {").contains("guard let folder = folder(), FileManager.default.fileExists"), "a missing folder never writes a file on the boot disk")
        #expect(skips.contains("Log.skips."), "every change logs")

        let app = try source("Overdrive.swift")
        #expect(app.contains("Skips(file: { Skips.file(in: library.folders.first) }, folder: { library.folders.first })"), "the file follows the first folder, like Likes")

        let views = try source("Views.swift")
        #expect(views.components(separatedBy: "skips.load()").count - 1 == 2, "a scan and a folder change reload the veto, so a moved folder brings its denials back")
    }

    @Test func theSongMenuAsksBeforeItDenies() throws {
        let views = try source("Views.swift")
        let menu = screen("TrackMenu", views)
        let dialog = screen("DenySongs", views)

        #expect(menu.contains("NotificationCenter.default.post(name: .denySongs, object: tracks)"), "the menu asks, it does not write the veto itself")
        #expect(menu.contains("\"Never Pick in Discovery\"") && menu.contains("\"Pick Again in Discovery\""), "one item both ways, so a click is never forever")
        #expect(views.contains(".modifier(DenySongs())"), "the window hosts the question")
        #expect(dialog.contains(".confirmationDialog(label, isPresented: $showing)"), "and it is a confirmation, not a silent write")
        #expect(dialog.contains("role: denied ? nil : .destructive"), "denying is destructive, allowing it back is not")
        #expect(dialog.contains("skips.add(pending)") && dialog.contains("skips.remove(pending)"), "the answer goes to the one list")
        #expect(dialog.contains("\"deny confirmed\"") && dialog.contains("\"deny cancelled\""), "both answers log")
        #expect(views.contains("static let denySongs = Notification.Name(\"denySongs\")"), "one notification name for one question")
    }

    @Test func anArtistWhoseSongsAreAllDeniedCostsNoRequest() throws {
        let root = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: root) }
        let skips = Skips(file: Skips.file(in: root), folder: root)
        let kataklysm = (1...3).map { track(root.appending(path: "Kataklysm/\($0).mp3").path, "Song \($0)") }
        let krisiun = (1...2).map { track(root.appending(path: "Krisiun/\($0).mp3").path, "Song \($0)") }
        let pool = [(name: "Kataklysm", songs: kataklysm), (name: "Krisiun", songs: krisiun)]

        let whole = Discovery.allowed(pool, skipping: skips)

        #expect(whole.map(\.name) == ["Kataklysm", "Krisiun"], "no veto, the pool as the library holds it")
        #expect(whole.map(\.songs) == [kataklysm, krisiun])

        skips.add([kataklysm[0]])
        let partly = Discovery.allowed(pool, skipping: skips)

        #expect(partly.count == 2, "an artist that is denied partly stays, with the songs that are left")
        #expect(partly[0].songs == [kataklysm[1], kataklysm[2]])
        #expect(partly[1].songs == krisiun)

        skips.add(Array(kataklysm.dropFirst()))
        let gone = Discovery.allowed(pool, skipping: skips)

        #expect(gone.count == 1, "an artist whose every song is denied leaves the pool before a request goes")
        #expect(gone.first?.name == "Krisiun")

        skips.add(krisiun)
        #expect(Discovery.allowed(pool, skipping: skips).isEmpty, "a fully denied library is an empty pool")
        #expect(Discovery.allowed([], skipping: skips).isEmpty, "and an empty pool stays empty")
    }

    // MARK: - the sidebar list

    @Test func theDeniedListIsAPageOfItsOwn() {
        #expect(Page(key: Page.denied.key) == .denied, "the page key round-trips")
        #expect(Page.denied.key == "denied")
        #expect(Page.denied.title == "Never Picked")
        #expect(Navigation(page: .denied).lyrics, "the denied list shows the docked lyrics, like every song list")
    }

    @Test func theSidebarRowOpensTheDeniedList() throws {
        let views = try source("Views.swift")

        #expect(views.contains("row(\"Liked Songs\", \"heart\", .liked)\n                        row(\"Never Picked\", \"nosign\", .denied)"), "the list sits under Liked Songs, in the style of the other rows")
        #expect(views.contains("case .denied: DeniedView()"), "the page draws its own screen")
        #expect(views.contains("case .denied: skips.count"), "the sidebar count and the subtitle read the veto")
        #expect(views.contains("case (nil, .denied): summary(library.rows(skips.paths).map(\\.track))"), "the window subtitle counts the songs the library still holds")
        #expect(views.contains("case .liked, .denied, .playlist, .upNext:"), "a launch on the denied list opens the list, never an old path into it")
    }

    @Test func theDeniedListOnlyTakesSongsOutOfTheVeto() throws {
        let views = try source("Views.swift")
        let start = try #require(views.range(of: "struct DeniedView: View {"))
        let rest = views[start.lowerBound...]
        let screen = String(rest[..<(try #require(rest.range(of: "\n}\n")).lowerBound)])

        #expect(screen.contains("library.rows(skips.paths)"), "the rows are the vetoed songs the library holds, in the order the user denied them")
        #expect(screen.contains("if skips.paths.isEmpty {"), "an empty veto says what the item is for")
        #expect(screen.contains("Button(\"Pick Again in Discovery\") { remove(picked.map(\\.track)) }"), "the menu of a row takes it out of the veto")
        #expect(screen.contains("delete: { remove(rows.filter { selection.contains($0.id) }.map(\\.track)) }"), "Delete does the same for the whole selection")
        #expect(screen.contains("selection = []\n        skips.remove(tracks)"), "the action clears the selection before the rows change, so the next action never hits a moved row")
        #expect(screen.contains("TrackMenu(tracks: picked.map(\\.track))"), "and the song menu is there, so a row can go back into the veto from the same screen")
        #expect(screen.contains("GoMenu(track: picked[0].track)"), "a single row keeps Go to Album, Go to Artist, and Go to Last.fm")
        #expect(screen.contains(".onChange(of: skips.paths) { selection = [] }"), "a veto that changed elsewhere empties the selection instead of pointing at another row")
        #expect(!screen.contains("Persist."), "the screen writes nothing but through Skips")
        #expect(!screen.contains("library.remove") && !screen.contains("FileManager"), "the list never touches a song file")
        #expect(views.contains("static let denySongs = Notification.Name(\"denySongs\")"), "one notification for the question the song menu asks")
    }

    // MARK: - helpers

    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }

    private func screen(_ name: String, _ source: String) -> String {
        guard let start = source.range(of: "struct \(name): ") else { return "" }
        let rest = source[start.lowerBound...]

        return String(rest[..<(rest.range(of: "\n}\n")?.lowerBound ?? rest.endIndex)])
    }

    private func body(_ source: String, _ signature: String) -> String {
        guard let start = source.range(of: signature) else { return "" }
        let rest = source[start.upperBound...]

        return String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
    }
}
