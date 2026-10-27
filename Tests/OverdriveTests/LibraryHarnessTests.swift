import Foundation
import SQLite3
import Testing
@testable import Overdrive

private let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")
private let samples = ["cbr.mp3", "vbr.mp3", "abr.mp3", "cbr-320.mp3", "vbr-mono.mp3", "cbr-mono.mp3"]

@MainActor
@Suite(.serialized)
struct LibraryHarnessTests {
    private final class Box: @unchecked Sendable {
        var first: Set<String>?
    }

    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OverdriveHarness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(filePath: url.path.withCString { String(cString: realpath($0, nil)) })
    }

    private func clean(_ urls: URL...) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private func library(_ folders: [URL]) -> Library {
        let loudness = Loudness()
        let library = Library(loudness: loudness, folders: folders)
        library.query = ""
        return library
    }

    private func put(_ folder: URL, _ path: String, _ sample: String = "cbr.mp3", date: Double = 1_000_000) throws {
        let target = folder.appending(path: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: fixtures.appending(path: sample), to: target)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: target.path)
    }

    private func audio(_ folders: [URL]) -> Set<String> {
        var result = Set<String>()
        for folder in folders {
            let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension == "mp3" { result.insert(url.path) }
            }
        }
        return result
    }

    private func stored(_ folder: URL) -> Set<String> {
        Set(Cache(folder)?.entries().values.map(\.track.url.path) ?? [])
    }

    private func consistent(_ folder: URL) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(folder.appending(path: Cache.name).path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, "INSERT INTO search(search, rank) VALUES ('integrity-check', 1)", nil, nil, nil) == SQLITE_OK
    }

    private func loaded(_ library: Library) -> Set<String> {
        Set(library.albums.flatMap(\.tracks).map(\.url.path))
    }

    private func synced(_ library: Library, _ folders: [URL]) -> Bool {
        let files = audio(folders)
        guard !library.scanning, loaded(library) == files else { return false }

        let memory = Dictionary(library.albums.flatMap(\.tracks).map { ($0.url.path, $0) }) { first, _ in first }

        for folder in folders {
            let inside = files.filter { $0.hasPrefix(folder.path + "/") }
            guard FileManager.default.fileExists(atPath: folder.appending(path: Cache.name).path), stored(folder) == inside, consistent(folder), let cache = Cache(folder) else { return false }

            for entry in cache.entries().values {
                let path = entry.track.url.path
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let date = attributes[.modificationDate] as? Date, let size = attributes[.size] as? Int,
                      entry.modified == date.timeIntervalSinceReferenceDate, entry.size == size,
                      let track = memory[path], track.title == entry.track.title, track.album == entry.track.album,
                      track.duration == entry.track.duration, track.albumID == entry.track.albumID
                else { return false }
            }

            for file in inside {
                let title = Fuzzy.fold(URL(filePath: file).deletingPathExtension().lastPathComponent)
                guard title.count >= 3 else { continue }

                let found = cache.search([title])
                guard found.contains(file), found.allSatisfy(files.contains) else { return false }
            }
        }

        return true
    }

    private func settle(_ library: Library, _ folders: [URL], sourceLocation: SourceLocation = #_sourceLocation) async {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(30)

        while clock.now < end {
            if synced(library, folders) { return }
            try? await Task.sleep(for: .milliseconds(50))
        }

        Issue.record("not in sync: memory \(loaded(library).count), disk \(audio(folders).count), scanning \(library.scanning)", sourceLocation: sourceLocation)
    }

    private func quiet(_ library: Library, _ folders: [URL], sourceLocation: SourceLocation = #_sourceLocation) async {
        func stamps() -> [String] {
            folders.flatMap { folder in
                ["", "-wal"].map { suffix in
                    let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appending(path: Cache.name + suffix).path)
                    return "\(attributes?[.modificationDate] ?? "none") \(attributes?[.size] ?? "none")"
                }
            }
        }

        let before = stamps()
        try? await Task.sleep(for: .seconds(4))
        #expect(stamps() == before, "the cache changed without a change in the music", sourceLocation: sourceLocation)
        #expect(synced(library, folders), sourceLocation: sourceLocation)
    }

    @Test func anEmptyFolderThatReceivesAFile() async throws {
        let folder = try folder()
        defer { clean(folder) }
        let library = library([folder])
        await settle(library, [folder])

        try put(folder, "Album/arrival.mp3")
        await settle(library, [folder])
        await quiet(library, [folder])
    }

    @Test func manyFilesAddedWhileRunning() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/seed.mp3")
        let library = library([folder])
        await settle(library, [folder])

        for number in 0..<300 {
            try put(folder, "Bulk \(number / 50)/bulk\(number)y.mp3", samples[number % samples.count])
        }
        await settle(library, [folder])
        await quiet(library, [folder])
    }

    @Test func aFileRemovedWhileRunning() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/stays.mp3")
        try put(folder, "Album/leaves.mp3")
        let library = library([folder])
        await settle(library, [folder])

        try FileManager.default.removeItem(at: folder.appending(path: "Album/leaves.mp3"))
        await settle(library, [folder])
        #expect(Cache(folder)!.search(["leaves"]).isEmpty)
        await quiet(library, [folder])
    }

    @Test func aFileRenamedWhileRunning() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/oldname.mp3")
        let library = library([folder])
        await settle(library, [folder])

        try FileManager.default.moveItem(at: folder.appending(path: "Album/oldname.mp3"), to: folder.appending(path: "Album/newname.mp3"))
        await settle(library, [folder])
        #expect(Cache(folder)!.search(["oldname"]).isEmpty)
    }

    @Test func aFolderRenamedWhileRunning() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Oldalbum/track.mp3")
        let library = library([folder])
        await settle(library, [folder])

        try FileManager.default.moveItem(at: folder.appending(path: "Oldalbum"), to: folder.appending(path: "Newalbum"))
        await settle(library, [folder])
        #expect(library.albums.map(\.title) == ["Newalbum"])
        #expect(Cache(folder)!.search(["oldalbum"]).isEmpty)
        #expect(Cache(folder)!.search(["newalbum"]) == [folder.path + "/Newalbum/track.mp3"])
    }

    @Test func aFileMovedBetweenFoldersWhileRunning() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "From/traveler.mp3")
        try put(folder, "To/resident.mp3")
        let library = library([folder])
        await settle(library, [folder])

        try FileManager.default.moveItem(at: folder.appending(path: "From/traveler.mp3"), to: folder.appending(path: "To/traveler.mp3"))
        await settle(library, [folder])
        #expect(Cache(folder)!.search(["traveler"]) == [folder.path + "/To/traveler.mp3"])
    }

    @Test func newContentWhileRunning() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/changing.mp3", "cbr.mp3")
        let library = library([folder])
        await settle(library, [folder])

        try put(folder, "Album/changing.mp3", "vbr-mono.mp3", date: 2_000_000)
        await settle(library, [folder])
        let after = library.albums.flatMap(\.tracks).first?.duration
        let fresh = await Library.load([try copy(folder)], [:]).albums.flatMap(\.tracks).first?.duration

        #expect(after == fresh)
    }

    @Test func aTouchWhileRunningKeepsEverythingInSync() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/touched.mp3")
        let library = library([folder])
        await settle(library, [folder])

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5_000_000)], ofItemAtPath: folder.appending(path: "Album/touched.mp3").path)
        let clock = ContinuousClock()
        let end = clock.now + .seconds(30)
        while clock.now < end, Cache(folder)!.entries()["Album/touched.mp3"]?.modified != Date(timeIntervalSince1970: 5_000_000).timeIntervalSinceReferenceDate {
            try? await Task.sleep(for: .milliseconds(50))
        }

        #expect(Cache(folder)!.entries()["Album/touched.mp3"]?.hash == Library.hash(folder.appending(path: "Album/touched.mp3")))
        await settle(library, [folder])
    }

    @Test func aBurstOfChangesWhileRunning() async throws {
        let folder = try folder()
        defer { clean(folder) }
        let library = library([folder])
        await settle(library, [folder])
        var random = SystemRandomNumberGenerator()
        var names: [String] = []

        for step in 0..<60 {
            switch Int.random(in: 0..<4, using: &random) {
            case 0, 1:
                let name = "Album \(Int.random(in: 0..<3, using: &random))/burst\(step)b.mp3"
                try put(folder, name, samples.randomElement(using: &random)!)
                names.append(name)
            case 2 where !names.isEmpty:
                try FileManager.default.removeItem(at: folder.appending(path: names.remove(at: Int.random(in: 0..<names.count, using: &random))))
            case 3 where !names.isEmpty:
                let index = Int.random(in: 0..<names.count, using: &random)
                let renamed = "Album \(Int.random(in: 0..<3, using: &random))/renamed\(step)c.mp3"
                try FileManager.default.createDirectory(at: folder.appending(path: renamed).deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: folder.appending(path: names[index]), to: folder.appending(path: renamed))
                names[index] = renamed
            default:
                break
            }
            if step.isMultiple(of: 10) { try? await Task.sleep(for: .milliseconds(30)) }
        }

        await settle(library, [folder])
        await quiet(library, [folder])
    }

    @Test func aSubtreeCreatedAndDeletedWhileRunning() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Keep/keeper.mp3")
        let library = library([folder])
        await settle(library, [folder])

        try put(folder, "Drop/One/dropone.mp3")
        try put(folder, "Drop/Two/droptwo.mp3")
        await settle(library, [folder])

        try FileManager.default.removeItem(at: folder.appending(path: "Drop"))
        await settle(library, [folder])
        #expect(Cache(folder)!.search(["dropone"]).isEmpty)
    }

    @Test func aFileThatBecomesUnreadableWhileRunning() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/broken.mp3")
        try put(folder, "Album/healthy.mp3")
        let library = library([folder])
        await settle(library, [folder])

        try Data(repeating: 0, count: 128).write(to: folder.appending(path: "Album/broken.mp3"))
        let clock = ContinuousClock()
        let end = clock.now + .seconds(30)
        while clock.now < end, loaded(library).contains(folder.path + "/Album/broken.mp3") || library.scanning {
            try? await Task.sleep(for: .milliseconds(50))
        }

        #expect(loaded(library) == [folder.path + "/Album/healthy.mp3"])
        #expect(stored(folder) == [folder.path + "/Album/healthy.mp3"])
        #expect(Cache(folder)!.search(["broken"]).isEmpty)
        #expect(consistent(folder))
    }

    @Test func theCacheDeletedWhileRunningIsBuiltAgain() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/survivor.mp3")
        try put(folder, "Album/witness.mp3")
        let library = library([folder])
        await settle(library, [folder])

        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: folder.appending(path: Cache.name + suffix)) }
        await settle(library, [folder])
        await quiet(library, [folder])
    }

    @Test func aCorruptCacheIsRepairedByTheNextScan() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/resilient.mp3")
        let library = library([folder])
        await settle(library, [folder])

        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(at: folder.appending(path: Cache.name + suffix)) }
        try Data(repeating: 0x5A, count: 65_536).write(to: folder.appending(path: Cache.name))
        try put(folder, "Album/trigger.mp3")
        await settle(library, [folder])
    }

    @Test func aFolderAddedWhileRunningIsScannedAtOnce() async throws {
        let first = try folder()
        let second = try folder()
        defer { clean(first, second) }
        try put(first, "A/firstsong.mp3")
        try put(second, "B/secondsong.mp3")
        let library = library([first])
        await settle(library, [first])

        library.add([second])
        await settle(library, [first, second])
        await quiet(library, [first, second])
    }

    @Test func aFolderTakenOffTheList() async throws {
        let first = try folder()
        let second = try folder()
        defer { clean(first, second) }
        try put(first, "A/staying.mp3")
        try put(second, "B/going.mp3")
        let library = library([first, second])
        await settle(library, [first, second])

        library.folders = [first]
        await settle(library, [first])
        #expect(!loaded(library).contains(second.path + "/B/going.mp3"))
    }

    @Test func theSearchFollowsTheFilesystem() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/zebra.mp3")
        try put(folder, "Album/zebra with many other words in the title.mp3")
        let library = library([folder])
        await settle(library, [folder])

        library.query = "zebra"
        #expect(library.tracks.map(\.url.path) == [folder.path + "/Album/zebra.mp3", folder.path + "/Album/zebra with many other words in the title.mp3"])

        try FileManager.default.removeItem(at: folder.appending(path: "Album/zebra.mp3"))
        library.query = ""
        await settle(library, [folder])
        library.query = "zebra"
        #expect(library.tracks.map(\.url.path) == [folder.path + "/Album/zebra with many other words in the title.mp3"])

        try put(folder, "Album/zebra.mp3", date: 9_000_000)
        library.query = ""
        await settle(library, [folder])
        library.query = "zebra"
        #expect(library.tracks.first?.url.path == folder.path + "/Album/zebra.mp3")
        library.query = ""
    }

    @Test func theRandomPickFollowsTheLibrary() async throws {
        let folder = try folder()
        defer { clean(folder) }
        for name in ["one", "two", "three"] { try put(folder, "Album/\(name).mp3") }
        let library = library([folder])
        await settle(library, [folder])
        let all = Set(loaded(library))

        #expect(library.total == 3)
        #expect(library.random(10).isEmpty, "a pick of more songs than the library has gives nothing")
        #expect(Set(library.random(3).map(\.url.path)) == all, "every song comes once, in any order")
        #expect(Set(library.random(1).map(\.url.path)).isSubset(of: all))

        library.query = "one"
        #expect(Set(library.random(3).map(\.url.path)) == all, "the pick reads the library, not the search results")
        library.query = ""

        try FileManager.default.removeItem(at: folder.appending(path: "Album/three.mp3"))
        await settle(library, [folder])
        #expect(library.total == 2)
        #expect(library.random(3).isEmpty)
    }

    @Test func theCountsFollowTheSongsThatPlay() async throws {
        let folder = try folder()
        let moved = folder.deletingLastPathComponent().appending(path: "OverdriveCounts-\(UUID().uuidString)")
        defer { clean(folder, moved) }
        for name in ["one", "two", "three"] { try put(folder, "Album/\(name).mp3") }
        let library = library([folder])
        await settle(library, [folder])
        let plays = library.plays

        #expect(library.total == 3)
        #expect(library.neverPlayed == 3)
        #expect(library.unplayed(4).isEmpty, "more unplayed songs than the library has never played gives nothing")

        let song = library.unplayed(1)[0]
        plays.bump(song)
        #expect(plays.count(song) == 1, "the count is in the memory at once")
        #expect(library.neverPlayed == 2, "a song that played leaves the never-played pool without a scan")
        #expect(library.unplayed(3).isEmpty)
        #expect(library.unplayed(2).allSatisfy { $0 != song }, "the pool holds only the songs you have not played")
        #expect(library.rows(library.tracks.map(\.url.path)).map(\.plays).sorted() == [0, 0, 1], "every row carries its count")

        plays.flush()
        Persist.flush()
        #expect(Persist.read([String: Int].self, from: Plays.file(in: folder))?.count == 1, "one file at the root of the music folder")

        try FileManager.default.moveItem(at: folder, to: moved)
        library.folders = [moved]
        await settle(library, [moved])

        #expect(library.tracks.map { plays.count($0) }.sorted() == [0, 0, 1], "the counts travel with the moved folder, with no path in the key")
        #expect(library.neverPlayed == 2)
        #expect(plays.missing == false)
    }

    @Test func theSongsOfAnArtistAreIndexedOncePerScan() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/one.mp3")
        try put(folder, "Album/two.mp3")
        try put(folder, "Other/three.mp3")
        let library = library([folder])
        await settle(library, [folder])

        let all = library.albums.flatMap(\.tracks)
        let artist = all[0].artist
        let folded = Fuzzy.fold(artist)
        let expected = all.filter { Fuzzy.fold($0.artist) == folded }
        guard !expected.isEmpty else {
            Issue.record("the fixtures give no artist to look up")
            return
        }

        #expect(library.songs(by: artist) == expected, "the songs of one artist, in library order")
        #expect(library.songs(by: artist.uppercased()) == expected, "the lookup folds the name, so an accent or a case change still finds it")
        #expect(library.songs(by: "Nobody At All") == [])

        try put(folder, "Album/four.mp3")
        await settle(library, [folder])
        let grown = library.albums.flatMap(\.tracks).filter { Fuzzy.fold($0.artist) == folded }

        #expect(library.songs(by: artist).count == grown.count, "the index follows every scan")
    }

    @Test func thePlayedBandsFollowTheCounts() async throws {
        let folder = try folder()
        defer { clean(folder) }
        for name in ["one", "two", "three"] { try put(folder, "Album/\(name).mp3") }
        let library = library([folder])
        await settle(library, [folder])
        let plays = library.plays
        let all = library.albums.flatMap(\.tracks)
        let artist = all[0].artist

        #expect(library.bands == 0, "a library nobody played has no band to name")
        #expect(library.topBands(1).isEmpty)

        plays.bump(all[0])
        #expect(library.bands == 1, "a first play opens a band without a scan")
        let bands = library.topBands(1)
        #expect(bands.map(\.name) == [artist])
        #expect(bands[0].songs.count == all.count, "the band carries every song the library has of it, played or not")
        #expect(library.topBands(5).count == 1, "more bands than the library has gives what there is")

        plays.bump(all[1])
        plays.bump(all[2])
        #expect(library.bands == 1, "the same band twice is still one band")
        #expect(library.topBands(1)[0].songs.count == all.count)

        try FileManager.default.removeItem(at: folder.appending(path: "Album/three.mp3"))
        await settle(library, [folder])
        #expect(library.bands == 1)
        #expect(library.topBands(1)[0].songs.count == 2, "the songs of a band follow every scan")
    }

    @Test func theBootIsLazyAndStartsFromTheCache() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/cached.mp3")
        try put(folder, "Album/deleted.mp3")
        _ = await Library.load([folder], [:])
        try FileManager.default.removeItem(at: folder.appending(path: "Album/deleted.mp3"))
        try put(folder, "Album/added.mp3")

        let box = Box()
        let clock = ContinuousClock()
        let start = clock.now
        let library = library([folder])
        let created = clock.now - start
        library.loaded = { [unowned library] _ in
            if box.first == nil { box.first = Set(library.albums.flatMap(\.tracks).map(\.url.path)) }
        }

        #expect(library.scanning)
        #expect(library.albums.isEmpty)
        #expect(created < .seconds(1))
        await settle(library, [folder])
        #expect(box.first == [folder.path + "/Album/cached.mp3", folder.path + "/Album/deleted.mp3"])
    }

    @Test func aSyncWithoutChangesDrawsNothing() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/one.mp3")
        let library = library([folder])
        await settle(library, [folder])
        while library.scanning { try? await Task.sleep(for: .milliseconds(50)) }
        let scans = library.scans
        let loads = Counter()
        library.loaded = { _ in loads.value += 1 }

        library.scan("menu")
        while library.scanning { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(loads.value == 1, "the sync ran")
        #expect(library.scans == scans, "a sync that finds no change must not redraw the library")

        try put(folder, "Album/two.mp3", "vbr.mp3")
        library.scan("menu")
        await settle(library, [folder])
        #expect(library.scans > scans, "a sync that finds a change shows it")
    }

    @Test func anUnlikeInTheLibraryFolderDoesNotScan() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/stays.mp3")
        let library = library([folder])
        await settle(library, [folder])
        try? await Task.sleep(for: .seconds(5))

        let likes = Likes(file: { Likes.file(in: folder) }, folder: { folder })
        let track = library.albums.flatMap(\.tracks).first!

        let scans = Counter()
        library.loaded = { _ in scans.value += 1 }

        likes.add([track])
        likes.remove([track])

        try? await Task.sleep(for: .seconds(5))
        #expect(scans.value == 0)
        #expect(!library.scanning)
    }

    @Test func lyricWritesInTheLibraryFolderDoNotScan() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/stays.mp3")
        let library = library([folder])
        await settle(library, [folder])
        try? await Task.sleep(for: .seconds(5))

        let scans = Counter()
        library.loaded = { _ in scans.value += 1 }

        try Data("lyrics".utf8).write(to: folder.appending(path: "Album/stays.lyrics"))
        try Data("lyrics".utf8).write(to: folder.appending(path: "Album/stays.lyrics.tmp"))
        try? FileManager.default.removeItem(at: folder.appending(path: "Album/stays.lyrics.tmp"))

        try? await Task.sleep(for: .seconds(5))
        #expect(scans.value == 0)
        #expect(!library.scanning)
    }

    @Test func theBootFindsOfflineChanges() async throws {
        let folder = try folder()
        defer { clean(folder) }
        for number in 0..<40 { try put(folder, "Album \(number / 10)/offline\(number)o.mp3", samples[number % samples.count]) }
        _ = await Library.load([folder], [:])

        for number in stride(from: 0, to: 40, by: 3) { try FileManager.default.removeItem(at: folder.appending(path: "Album \(number / 10)/offline\(number)o.mp3")) }
        for number in 40..<70 { try put(folder, "Album \(number / 10)/offline\(number)o.mp3", samples[number % samples.count]) }
        try put(folder, "Album 1/offline11o.mp3", "vbr-mono.mp3", date: 3_000_000)
        try FileManager.default.moveItem(at: folder.appending(path: "Album 2/offline22o.mp3"), to: folder.appending(path: "Album 2/offlinemovedo.mp3"))

        let library = library([folder])
        await settle(library, [folder])
        await quiet(library, [folder])
    }

    @Test func theBootWithoutACache() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/fresh.mp3")
        _ = await Library.load([folder], [:])
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: folder.appending(path: Cache.name + suffix)) }

        let library = library([folder])
        await settle(library, [folder])
    }

    @Test func theBootWithACorruptCache() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/sturdy.mp3")
        _ = await Library.load([folder], [:])
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(at: folder.appending(path: Cache.name + suffix)) }
        try Data(repeating: 0x5A, count: 65_536).write(to: folder.appending(path: Cache.name))

        let library = library([folder])
        await settle(library, [folder])
    }

    @Test func anUnchangedBootWritesNothing() async throws {
        let folder = try folder()
        defer { clean(folder) }
        for number in 0..<20 { try put(folder, "Album/still\(number)s.mp3") }
        let first = library([folder])
        await settle(first, [folder])
        await quiet(first, [folder])

        let library = library([folder])
        await quiet(library, [folder])
    }

    @Test func aBootFollowedByAChange() async throws {
        let folder = try folder()
        defer { clean(folder) }
        try put(folder, "Album/before.mp3")
        _ = await Library.load([folder], [:])

        let library = library([folder])
        await settle(library, [folder])
        try put(folder, "Album/after.mp3")
        await settle(library, [folder])
        await quiet(library, [folder])
    }

    private func copy(_ folder: URL) throws -> URL {
        let target = FileManager.default.temporaryDirectory.appending(path: "OverdriveHarnessCopy-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: folder, to: target)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: target.appending(path: Cache.name + suffix)) }
        return target
    }
}
