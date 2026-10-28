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
        let file = Bans.file(in: root)
        let first = track(root.appending(path: "A/one.mp3").path, "One")
        let second = track(root.appending(path: "A/two.mp3").path, "Two")

        let bans = Bans(file: file, folder: root)
        #expect(bans.paths.isEmpty)

        bans.add([first, first, second])
        Persist.flush()
        #expect(bans.count == 2, "a song the ban already holds is not written twice")
        #expect(bans.contains(first))

        let read = Bans(file: file, folder: root)
        #expect(read.paths == [first.url.path, second.url.path], "the order the user denied in comes back")
        #expect(read.contains(second))

        let stored = try #require(Persist.read([String].self, from: file))
        #expect(stored.allSatisfy { !$0.hasPrefix("/") }, "the file holds paths relative to the folder, so the library can move: \(stored)")
        #expect(stored.allSatisfy { $0.hasPrefix("A/") })

        let moved = root.deletingLastPathComponent().appending(path: "MovedSkips-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: root, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }

        let after = Bans(file: Bans.file(in: moved), folder: moved)
        #expect(after.count == 2, "a folder that moved keeps its denials, because the file moved with it")
        #expect(after.contains(track(moved.appending(path: "A/one.mp3").path, "One")))
    }

    @Test func nothingIsWrittenWhileTheFolderIsMissing() throws {
        let root = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: root) }
        let gone = root.appending(path: "NotMounted")
        let file = Bans.file(in: gone)
        let at: () -> URL? = { gone }
        let bans = Bans(file: { file }, folder: at)

        bans.add([track(gone.appending(path: "a.mp3").path)])
        Persist.flush()

        #expect(bans.count == 1, "the ban is in memory at once, so a discovery on a missing drive still respects it")
        #expect(!FileManager.default.fileExists(atPath: file.path), "and nothing is written to a folder that is not there")
    }

    @Test func theSameSongIsDeniedOnceAndAllowedOnce() throws {
        let root = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: root) }
        let one = track(root.appending(path: "a.mp3").path, "One")
        let two = track(root.appending(path: "b.mp3").path, "Two")
        let bans = Bans(file: Bans.file(in: root), folder: root)

        bans.add([one])
        #expect(bans.contains(one))

        bans.toggle([one])
        #expect(!bans.contains(one), "the same item that denies a song gives it back")

        bans.toggle([one, two])
        #expect(bans.contains(one) && bans.contains(two), "a group that is not wholly banned is banned whole")

        bans.toggle([one, two])
        #expect(!bans.contains(one) && !bans.contains(two), "and a wholly banned group is allowed whole")
        #expect(bans.count == 0)
    }

    @Test func theFilterKeepsEverySongTheUserWants() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let songs = (1...4).map { track(root.appending(path: "\($0).mp3").path, "Song \($0)") }
        let bans = Bans(file: Bans.file(in: root), folder: root)

        #expect(bans.allowed(songs) == songs, "with no ban the pool is the pool, not a copy of it")

        bans.add([songs[1], songs[3]])
        #expect(bans.allowed(songs) == [songs[0], songs[2]])
        #expect(bans.allowed([]).isEmpty, "an empty pool stays empty")
        #expect(bans.allowed([songs[1]]).isEmpty, "a song the user denied is no pool at all")
    }

    @Test func aFileThatIsNotAListIsReplacedNotCrashedOn() throws {
        let root = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: root) }
        let file = Bans.file(in: root)
        try Data("junk".utf8).write(to: file)

        let bans = Bans(file: file, folder: root)
        #expect(bans.paths.isEmpty, "a file that does not match the format is ignored, not read")

        bans.add([track(root.appending(path: "a.mp3").path)])
        Persist.flush()
        #expect(bans.count == 1, "and the app writes its own list over it")
    }

    /// The ban is applied where a pool of songs is built, and nowhere else: a
    /// second filter at the end of `start` would only shrink a pick that already
    /// came back short, so no test could ever see it run. `BansProofTests` removes
    /// each of these and shows the pick that depends on it fails.
    @Test func everyPoolBuilderReadsTheBan() throws {
        let discovery = try source("Discovery.swift")

        #expect(body(discovery, "private func picked(_ pool: Pool, _ count: Int) -> [Track] {").contains("let allowed = bans.allowed(library.tracks)"),
                "the three library pools draw from the songs the user still wants")
        #expect(body(discovery, "private func picked(_ pool: Pool, _ count: Int) -> [Track] {").contains("bans.count > 0"),
                "an empty ban costs nothing: the pickers run unchanged")
        #expect(body(discovery, "private func walk(_ pool: Pool, _ count: Int) async -> (tracks: [Track], note: String?) {").contains("Discovery.allowed(library.topBands(count), banning: bans)"),
                "Top Bands filters before a request goes")
        #expect(body(discovery, "private func walk(_ pool: Pool, _ count: Int) async -> (tracks: [Track], note: String?) {").contains("}, banning: bans)"),
                "and so does Last.fm Artists")
        #expect(body(discovery, "static func allowed(_ pool: [(name: String, songs: [Track])], banning bans: Bans)").contains("guard !held.isEmpty else { return nil }"),
                "an artist whose every song is banned never costs a request")
        #expect(!body(discovery, "private func start(_ tracks: [Track], _ mine: Int, _ pool: Pool, _ count: Int, _ why: String?) {").contains("bans."),
                "the one door at the end holds no second filter, so every builder is reachable by a test")
        #expect(discovery.contains("\"discovery banned\""), "a pick that lost songs to the ban says so")
        #expect(!discovery.contains("bans.add") && !discovery.contains("bans.remove"), "the discovery never sets the ban itself, only the user does")

        let infinity = try source("Infinity.swift")

        #expect(body(infinity, "private func draw() async -> [Track] {").contains("Discovery.allowed(library.pool(excluding: served), banning: bans)"),
                "and so does every fill of the mode, start and refill alike")
    }

    @Test func theVetoIsTheUsersAndLivesWithTheCollection() throws {
        let bans = try source("Bans.swift")

        #expect(bans.contains("appending(path: \"Bans.plist\""), "the file travels with the library, next to Likes and Playlists")
        #expect(!bans.contains("Persist.read([String].self, from: location()) ?? []\n        denied"), "the load decodes once")
        #expect(body(bans, "private func save() {").contains("guard let folder = folder(), FileManager.default.fileExists"), "a missing folder never writes a file on the boot disk")
        #expect(bans.contains("Log.bans."), "every change logs")

        let app = try source("Overdrive.swift")
        #expect(app.contains("Bans(file: { Bans.file(in: library.folders.first) }, folder: { library.folders.first })"), "the file follows the first folder, like Likes")

        let views = try source("Views.swift")
        #expect(views.components(separatedBy: "bans.load()").count - 1 == 2, "a scan and a folder change reload the ban, so a moved folder brings its denials back")
    }

    @Test func everyListOfSongsOffersTheBan() throws {
        let views = try source("Views.swift")

        #expect(body(views, "struct BanMenu: View {").contains("NotificationCenter.default.post(name: .banSongs, object: tracks)"),
                "one definition of the item, and it asks rather than write")
        #expect(views.contains("Button(Bans.label(tracks.count, banned: banned), systemImage: banned ? \"arrow.uturn.backward\" : \"nosign\")"),
                "the same words ban and unban, so a click is never forever")

        for list in ["SongTable", "UpNextView", "PlaylistView", "LikedView", "BannedView", "AlbumView", "AlbumStrip"] {
            let body = screen(list, views)

            #expect(body.contains("BanMenu(tracks:") || body.contains("TrackMenu(tracks:"),
                  "\(list) shows songs, so it must offer the ban, through BanMenu or through TrackMenu, which holds it")
        }

        #expect(screen("TrackMenu", views).contains("BanMenu(tracks: tracks)"), "the song menu of every list carries it")
        #expect(screen("UpNextView", views).contains("TrackMenu(tracks: picked.map(\\.track))"),
                "Up Next carries the whole song menu: it is where an Infinity pick leaves the user, and Like, Ban, and Add to Playlist belong there too")
        #expect(views.components(separatedBy: "BanMenu(tracks:").count - 1 == 1, "TrackMenu holds the item, and no list copies it")
    }

    @Test func theBanAsksBeforeItWrites() throws {
        let views = try source("Views.swift")
        let dialog = screen("BanSongs", views)

        #expect(views.contains(".modifier(BanSongs())"), "the window hosts the question")
        #expect(dialog.contains(".confirmationDialog(label, isPresented: $showing)"), "and it is a confirmation, not a silent write")
        #expect(dialog.contains("label: String { Bans.label(pending.count, banned: banned) }"), "the dialog speaks with the words of the item, so the two cannot drift")
        #expect(dialog.contains("role: banned ? nil : .destructive"), "a ban is destructive, taking it back is not")
        #expect(dialog.contains("bans.add(pending)") && dialog.contains("bans.remove(pending)"), "the answer goes to the one list")
        #expect(dialog.contains("\"ban confirmed\"") && dialog.contains("\"ban cancelled\""), "both answers log")
        #expect(views.contains("static let banSongs = Notification.Name(\"banSongs\")"), "one notification for one question")
    }

    @Test func theBannedListOnlyTakesSongsOutOfTheBan() throws {
        let views = try source("Views.swift")
        let body = screen("BannedView", views)

        #expect(body.contains("library.rows(bans.paths)"), "the rows are the banned songs the library holds, in the order the user banned them")
        #expect(body.contains("if bans.paths.isEmpty {"), "an empty ban says what the item is for")
        #expect(body.contains("Button(Bans.label(picked.count, banned: true))"), "the menu of a row takes it out of the ban")
        #expect(body.contains("delete: { remove(rows.filter { selection.contains($0.id) }.map(\\.track)) }"), "Delete does the same for the whole selection")
        #expect(body.contains("selection = []\n        bans.remove(tracks)"), "the action clears the selection before the rows change, so the next action never hits a moved row")
        #expect(body.contains("TrackMenu(tracks: picked.map(\\.track))"), "and the song menu is there, so a row can go back into the ban from the same screen")
        #expect(body.contains("GoMenu(track: picked[0].track)"), "a single row keeps Go to Album, Go to Artist, and Go to Last.fm")
        #expect(body.contains(".onChange(of: bans.paths) { selection = [] }"), "a ban that changed elsewhere empties the selection instead of pointing at another row")
        #expect(!body.contains("Persist."), "the screen writes nothing but through Bans")
        #expect(!body.contains("library.remove") && !body.contains("FileManager"), "the list never touches a song file")
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
