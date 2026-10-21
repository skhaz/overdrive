import CoreServices
import Foundation
import SQLite3
import Testing
@testable import Overdrive

private let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")
private let samples = ["cbr.mp3", "vbr.mp3", "abr.mp3", "cbr-320.mp3", "vbr-mono.mp3", "cbr-mono.mp3"]

@Suite struct LibraryCacheTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OverdriveLibrary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(filePath: url.path.withCString { String(cString: realpath($0, nil)) })
    }

    private func add(_ sample: String, to folder: URL, as path: String, modified: Date = Date(timeIntervalSince1970: 1_000_000)) throws {
        let target = folder.appending(path: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: fixtures.appending(path: sample), to: target)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
    }

    private func paths(_ result: (albums: [Album], index: Index, covers: [String: Data])) -> Set<String> {
        Set(result.albums.flatMap(\.tracks).map(\.url.path))
    }

    private func audio(_ folder: URL) -> Set<String> {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return Set(files.filter { $0.pathExtension == "mp3" }.map(\.path))
    }

    private func stored(_ folder: URL) -> Set<String> {
        Set(Cache(folder)!.entries().values.map(\.track.url.path))
    }

    private func consistent(_ folder: URL) -> Bool {
        var db: OpaquePointer?
        sqlite3_open(folder.appending(path: Cache.name).path, &db)
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, "INSERT INTO search(search, rank) VALUES ('integrity-check', 1)", nil, nil, nil) == SQLITE_OK
    }

    private func execute(_ folder: URL, _ sql: String) {
        var db: OpaquePointer?
        sqlite3_open(folder.appending(path: Cache.name).path, &db)
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
    }

    private func title(_ result: (albums: [Album], index: Index, covers: [String: Data]), _ path: String) -> String? {
        result.albums.flatMap(\.tracks).first { $0.url.path == path }?.title
    }

    @Test func firstLoadStoresEveryFile() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "A/one.mp3")
        try add("vbr.mp3", to: folder, as: "B/two.mp3")

        let result = await Library.load([folder], [:])

        #expect(paths(result) == audio(folder))
        #expect(stored(folder) == audio(folder))
    }

    @Test func unchangedFilesComeFromTheCache() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        _ = await Library.load([folder], [:])

        execute(folder, "UPDATE tracks SET title = 'From Cache'")
        let result = await Library.load([folder], [:])

        #expect(title(result, folder.path + "/one.mp3") == "From Cache")
    }

    @Test func aNewDateReadsTheFileAgain() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        let first = await Library.load([folder], [:])
        let original = title(first, folder.path + "/one.mp3")

        execute(folder, "UPDATE tracks SET title = 'Stale'")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: folder.appending(path: "one.mp3").path)
        let result = await Library.load([folder], [:])

        #expect(title(result, folder.path + "/one.mp3") == original)
        #expect(Cache(folder)!.entries()["one.mp3"]?.track.title == original)
    }

    @Test func aNewSizeReadsTheFileAgain() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        _ = await Library.load([folder], [:])

        execute(folder, "UPDATE tracks SET title = 'Stale', size = size + 1")
        let result = await Library.load([folder], [:])

        #expect(title(result, folder.path + "/one.mp3") != "Stale")
    }

    @Test func replacedContentIsReadAgain() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        _ = await Library.load([folder], [:])

        try add("vbr-mono.mp3", to: folder, as: "one.mp3", modified: Date(timeIntervalSince1970: 3_000_000))
        let result = await Library.load([folder], [:])
        let fresh = await Library.load([try copy(folder)], [:])

        let duration = result.albums.flatMap(\.tracks).first?.duration
        #expect(duration == fresh.albums.flatMap(\.tracks).first?.duration)
    }

    @Test func addedFilesAppear() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        _ = await Library.load([folder], [:])

        try add("vbr.mp3", to: folder, as: "Deep/Nested/two.mp3")
        let result = await Library.load([folder], [:])

        #expect(paths(result) == audio(folder))
        #expect(stored(folder) == audio(folder))
    }

    @Test func removedFilesDisappear() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        try add("vbr.mp3", to: folder, as: "two.mp3")
        _ = await Library.load([folder], [:])

        try FileManager.default.removeItem(at: folder.appending(path: "one.mp3"))
        let result = await Library.load([folder], [:])

        #expect(paths(result) == [folder.path + "/two.mp3"])
        #expect(stored(folder) == [folder.path + "/two.mp3"])
    }

    @Test func renamedFilesMove() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "old.mp3")
        _ = await Library.load([folder], [:])

        try FileManager.default.moveItem(at: folder.appending(path: "old.mp3"), to: folder.appending(path: "Moved/new.mp3").deletingLastPathComponent().appending(path: "new.mp3").creatingDirectory())
        let result = await Library.load([folder], [:])

        #expect(paths(result) == [folder.path + "/Moved/new.mp3"])
        #expect(stored(folder) == [folder.path + "/Moved/new.mp3"])
    }

    @Test func unreadableFilesAreNotStored() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "good.mp3")
        try Data(repeating: 0, count: 64).write(to: folder.appending(path: "bad.mp3"))

        let result = await Library.load([folder], [:])

        #expect(!paths(result).contains(folder.path + "/bad.mp3"))
        #expect(!stored(folder).contains(folder.path + "/bad.mp3"))
        #expect(stored(folder).contains(folder.path + "/good.mp3"))
    }

    @Test func aFileThatBecomesUnreadableLeavesTheCache() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        _ = await Library.load([folder], [:])

        try Data(repeating: 0, count: 64).write(to: folder.appending(path: "one.mp3"))
        let result = await Library.load([folder], [:])

        #expect(paths(result).isEmpty)
        #expect(stored(folder).isEmpty)
    }

    @Test func anEmptyFolderEmptiesTheCache() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "A/one.mp3")
        _ = await Library.load([folder], [:])

        try FileManager.default.removeItem(at: folder.appending(path: "A"))
        let result = await Library.load([folder], [:])

        #expect(result.albums.isEmpty)
        #expect(stored(folder).isEmpty)
        #expect(Cache(folder)!.covers().isEmpty)
    }

    @Test func eachFolderHasItsOwnCache() async throws {
        let first = try folder()
        let second = try folder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try add("cbr.mp3", to: first, as: "one.mp3")
        try add("vbr.mp3", to: second, as: "two.mp3")

        let result = await Library.load([first, second], [:])

        #expect(paths(result) == audio(first).union(audio(second)))
        #expect(stored(first) == audio(first))
        #expect(stored(second) == audio(second))
    }

    @Test func storesRelativePaths() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "A/one.mp3")

        _ = await Library.load([folder], [:])

        #expect(Array(Cache(folder)!.entries().keys) == ["A/one.mp3"])
    }

    @Test func ignoresItsOwnFilesAndOtherFiles() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        try Data("text".utf8).write(to: folder.appending(path: "notes.txt"))

        _ = await Library.load([folder], [:])
        let result = await Library.load([folder], [:])

        #expect(paths(result) == [folder.path + "/one.mp3"])
    }

    @Test func aCachedLoadEqualsAFreshLoad() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (number, sample) in samples.enumerated() {
            try add(sample, to: folder, as: "Album \(number % 2)/\(number).mp3")
        }

        let fresh = await Library.load([folder], [:])
        let cached = await Library.load([folder], [:])

        #expect(fresh.albums.map(\.id) == cached.albums.map(\.id))
        #expect(fresh.albums.map(\.title) == cached.albums.map(\.title))
        #expect(fresh.albums.map(\.artist) == cached.albums.map(\.artist))
        #expect(fresh.albums.map(\.year) == cached.albums.map(\.year))

        for (old, new) in zip(fresh.albums.flatMap(\.tracks), cached.albums.flatMap(\.tracks)) {
            #expect(old.url == new.url)
            #expect(old.title == new.title)
            #expect(old.artist == new.artist)
            #expect(old.album == new.album)
            #expect(old.number == new.number)
            #expect(old.disc == new.disc)
            #expect(old.albumArtist == new.albumArtist)
            #expect(old.year == new.year)
            #expect(old.duration == new.duration)
            #expect(old.albumID == new.albumID)
        }

        #expect(fresh.index.bytes == cached.index.bytes)
        #expect(fresh.index.albums == cached.index.albums)
    }

    @Test func storesAndReusesCovers() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "A/one.mp3")

        let first = await Library.load([folder], [:])
        #expect(Set(Cache(folder)!.covers().keys) == Set(first.covers.keys))

        execute(folder, "UPDATE covers SET data = x'01'")
        let second = await Library.load([folder], [:])

        #expect(second.covers.values.allSatisfy { $0 == Data([1]) })
    }

    @Test func staysEqualToTheFilesystemAfterRandomChanges() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var random = SystemRandomNumberGenerator()
        var names: [String] = []

        for round in 0..<40 {
            switch Int.random(in: 0..<4, using: &random) {
            case 0, 1:
                let name = "Album \(Int.random(in: 0..<3, using: &random))/\(round).mp3"
                try add(samples.randomElement(using: &random)!, to: folder, as: name, modified: Date(timeIntervalSince1970: Double(round)))
                names.append(name)
            case 2 where !names.isEmpty:
                let name = names.remove(at: Int.random(in: 0..<names.count, using: &random))
                try FileManager.default.removeItem(at: folder.appending(path: name))
            case 3 where !names.isEmpty:
                let name = names.randomElement(using: &random)!
                try add(samples.randomElement(using: &random)!, to: folder, as: name, modified: Date(timeIntervalSince1970: Double(10_000 + round)))
            default:
                break
            }

            let steps = Steps()
            let result = await load(folder, steps)

            #expect(paths(result) == audio(folder), "round \(round)")
            #expect(stored(folder) == audio(folder), "round \(round)")
            #expect(consistent(folder), "round \(round)")
            #expect(steps.synced.dropFirst().allSatisfy { $0 }, "round \(round)")

            let fresh = await Library.load([try copy(folder)], [:])
            #expect(result.albums.flatMap(\.tracks).map(\.duration).sorted() == fresh.albums.flatMap(\.tracks).map(\.duration).sorted(), "round \(round)")
        }
    }

    private func touch(_ folder: URL, _ path: String, _ seconds: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: folder.appending(path: path).path)
    }

    @Test func newFilesHaveNoHash() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")

        _ = await Library.load([folder], [:])

        #expect(Cache(folder)!.entries()["one.mp3"]?.hash == nil)
    }

    @Test func sameSizeAndContentKeepTheCachedTags() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        _ = await Library.load([folder], [:])
        try touch(folder, "one.mp3", 5_000_000)
        _ = await Library.load([folder], [:])
        #expect(Cache(folder)!.entries()["one.mp3"]?.hash == Library.hash(folder.appending(path: "one.mp3")))

        execute(folder, "UPDATE tracks SET title = 'Kept'")
        try touch(folder, "one.mp3", 6_000_000)
        let result = await Library.load([folder], [:])

        #expect(title(result, folder.path + "/one.mp3") == "Kept")
        #expect(Cache(folder)!.entries()["one.mp3"]?.modified == Date(timeIntervalSince1970: 6_000_000).timeIntervalSinceReferenceDate)
    }

    @Test func sameSizeWithNewContentIsReadAgain() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        let first = await Library.load([folder], [:])
        try touch(folder, "one.mp3", 5_000_000)
        _ = await Library.load([folder], [:])
        let before = Cache(folder)!.entries()["one.mp3"]?.hash

        execute(folder, "UPDATE tracks SET title = 'Stale'")
        let file = folder.appending(path: "one.mp3")
        var data = try Data(contentsOf: file)
        data[data.count - 1] ^= 0xFF
        try data.write(to: file)
        try touch(folder, "one.mp3", 7_000_000)
        let result = await Library.load([folder], [:])

        #expect(title(result, file.path) == title(first, file.path))
        #expect(Cache(folder)!.entries()["one.mp3"]?.hash != before)
        #expect(Cache(folder)!.entries()["one.mp3"]?.hash == Library.hash(file))
    }

    @Test func aNewSizeIsReadAgainWithoutAHash() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        let first = await Library.load([folder], [:])

        execute(folder, "UPDATE tracks SET title = 'Stale', size = size + 1, hash = x'00'")
        let result = await Library.load([folder], [:])

        #expect(title(result, folder.path + "/one.mp3") == title(first, folder.path + "/one.mp3"))
        #expect(Cache(folder)!.entries()["one.mp3"]?.hash == nil)
    }

    @Test func neverWritesTheMusicFiles() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for (number, sample) in samples.enumerated() {
            try add(sample, to: folder, as: "Album/\(number).mp3")
        }
        let files = audio(folder).sorted()
        func snapshot() throws -> [(Data, Date, Int)] {
            try files.map { path in
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                return (try Data(contentsOf: URL(filePath: path)), attributes[.modificationDate] as! Date, attributes[.size] as! Int)
            }
        }
        let before = try snapshot()

        _ = await Library.load([folder], [:])
        try touch(folder, "Album/0.mp3", 9_000_000)
        let touched = try snapshot()
        _ = await Library.load([folder], [:])
        _ = await Library.load([folder], [:])
        let after = try snapshot()

        #expect(before.map(\.0) == after.map(\.0))
        #expect(touched.map(\.1) == after.map(\.1))
        #expect(before.map(\.2) == after.map(\.2))
    }

    private final class Steps: @unchecked Sendable {
        var counts: [Int] = []
        var titles: [[String]] = []
        var synced: [Bool] = []
        let stop: Int?

        init(stop: Int? = nil) {
            self.stop = stop
        }
    }

    private func load(_ folder: URL, _ steps: Steps) async -> Library.Snapshot {
        await Library.load([folder], [:]) { snapshot in
            steps.counts.append(snapshot.albums.reduce(0) { $0 + $1.tracks.count })
            steps.titles.append(snapshot.albums.flatMap(\.tracks).map(\.title))
            steps.synced.append(Set(snapshot.albums.flatMap(\.tracks).map(\.url.path)) == stored(folder) && consistent(folder))
            return steps.stop.map { steps.counts.count < $0 } ?? true
        }
    }

    @Test func everyStepAfterTheWalkMatchesTheCache() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for number in 0..<300 {
            try add(samples[number % samples.count], to: folder, as: "Album \(number / 20)/\(number).mp3")
        }
        _ = await Library.load([folder], [:])
        for number in stride(from: 0, to: 300, by: 3) {
            try FileManager.default.removeItem(at: folder.appending(path: "Album \(number / 20)/\(number).mp3"))
        }
        for number in 300..<600 {
            try add(samples[number % samples.count], to: folder, as: "Album \(number / 20)/\(number).mp3")
        }

        let steps = Steps()
        let result = await load(folder, steps)

        #expect(steps.synced.count >= 3)
        #expect(steps.synced.dropFirst().allSatisfy { $0 })
        #expect(paths(result) == audio(folder))
        #expect(stored(folder) == audio(folder))
        #expect(consistent(folder))
    }

    @Test func aScanStoppedAfterTheWalkKeepsItsRemovals() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        _ = await Library.load([folder], [:])

        try add("vbr.mp3", to: folder, as: "two.mp3")
        try FileManager.default.removeItem(at: folder.appending(path: "one.mp3"))
        _ = await load(folder, Steps(stop: 2))

        #expect(stored(folder).isEmpty)
        #expect(consistent(folder))
    }

    @Test func aDeletedCacheIsBuiltAgain() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        try add("vbr.mp3", to: folder, as: "two.mp3")
        _ = await Library.load([folder], [:])

        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: folder.appending(path: Cache.name + suffix))
        }
        let result = await Library.load([folder], [:])

        #expect(paths(result) == audio(folder))
        #expect(stored(folder) == audio(folder))
        #expect(consistent(folder))
    }

    @Test func rescansOnlyForRelevantEvents() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        let removed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
        let renamed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        let cache = folder.path + "/" + Cache.name

        #expect(Library.relevant([(folder.path + "/Album/one.mp3", modified)]))
        #expect(Library.relevant([(folder.path + "/Album", removed)]))
        #expect(!Library.relevant([(folder.path + "/.hidden/one.mp3", modified)]))
        #expect(!Library.relevant([(folder.path + "/Album/one.lrc", modified)]))
        #expect(!Library.relevant([]))

        #expect(Library.relevant([(cache, modified)]))
        _ = Cache(folder)
        #expect(!Library.relevant([(cache, modified)]))
        #expect(!Library.relevant([(cache + "-wal", modified), (cache + "-shm", removed)]))
        #expect(Library.relevant([(cache, removed)]))
        #expect(Library.relevant([(cache, renamed)]))
        #expect(Library.relevant([(cache + "-wal", modified), (folder.path + "/Album/one.mp3", modified)]))
        #expect(!Library.relevant([(folder.path + "/Likes.plist", modified)], folders: [folder]))
        #expect(!Library.relevant([(folder.path + "/Playlists", removed)], folders: [folder]))
        #expect(!Library.relevant([(folder.path + "/Playlists/mix.plist", modified)], folders: [folder]))
    }

    @Test func showsTheCacheFirstAndTheFilesystemLast() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "gone.mp3")
        try add("vbr.mp3", to: folder, as: "kept.mp3")
        _ = await Library.load([folder], [:])

        try FileManager.default.removeItem(at: folder.appending(path: "gone.mp3"))
        try add("abr.mp3", to: folder, as: "new.mp3")
        let steps = Steps()
        let result = await load(folder, steps)

        #expect(steps.counts.first == 2)
        #expect(paths(result) == audio(folder))
        #expect(stored(folder) == audio(folder))
    }

    @Test func anUnchangedLibrarySendsOnlyTheCache() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        _ = await Library.load([folder], [:])

        let steps = Steps()
        _ = await load(folder, steps)

        #expect(steps.counts == [1])
    }

    @Test func aChangedSongKeepsItsOldTagsUntilItIsRead() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        let first = await Library.load([folder], [:])

        execute(folder, "UPDATE tracks SET title = 'Old', size = size + 1")
        let steps = Steps()
        let result = await load(folder, steps)

        #expect(steps.titles.first == ["Old"])
        #expect(steps.titles.dropFirst().first == ["Old"])
        #expect(title(result, folder.path + "/one.mp3") == title(first, folder.path + "/one.mp3"))
    }

    @Test func newFilesArriveInBatches() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for number in 0..<300 {
            try add(samples[number % samples.count], to: folder, as: "Album \(number / 20)/\(number).mp3")
        }

        let steps = Steps()
        let result = await load(folder, steps)

        #expect(steps.counts.count >= 2)
        #expect(steps.counts == steps.counts.sorted())
        #expect(steps.counts.last! < 300)
        #expect(paths(result).count == 300)
        #expect(stored(folder).count == 300)
    }

    @Test func aScanStoppedAtTheCacheSavesNothing() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try add("cbr.mp3", to: folder, as: "one.mp3")
        _ = await Library.load([folder], [:])

        try add("vbr.mp3", to: folder, as: "two.mp3")
        try FileManager.default.removeItem(at: folder.appending(path: "one.mp3"))
        _ = await load(folder, Steps(stop: 1))

        #expect(stored(folder) == [folder.path + "/one.mp3"])

        _ = await Library.load([folder], [:])
        #expect(stored(folder) == audio(folder))
    }

    private func copy(_ folder: URL) throws -> URL {
        let target = FileManager.default.temporaryDirectory.appending(path: "OverdriveCopy-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: folder, to: target)
        try? FileManager.default.removeItem(at: target.appending(path: Cache.name))
        try? FileManager.default.removeItem(at: target.appending(path: Cache.name + "-wal"))
        try? FileManager.default.removeItem(at: target.appending(path: Cache.name + "-shm"))
        return target
    }
}

private extension URL {
    func creatingDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
