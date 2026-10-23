import Foundation
import SQLite3
import Testing
@testable import Overdrive

private let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")
private let samples = ["cbr.mp3", "vbr.mp3", "abr.mp3", "cbr-320.mp3", "vbr-mono.mp3", "cbr-mono.mp3"]

@Suite struct SyncTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OverdriveSync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(filePath: url.path.withCString { String(cString: realpath($0, nil)) })
    }

    private func put(_ folder: URL, _ path: String, _ sample: String = "cbr.mp3", date: Double = 1_000_000) throws {
        let target = folder.appending(path: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: fixtures.appending(path: sample), to: target)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: target.path)
    }

    private func remove(_ folder: URL, _ path: String) throws {
        try FileManager.default.removeItem(at: folder.appending(path: path))
    }

    private func move(_ folder: URL, _ from: String, _ to: String) throws {
        let target = folder.appending(path: to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: folder.appending(path: from), to: target)
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
        Set(Cache(folder)!.entries().values.map(\.track.url.path))
    }

    private func consistent(_ folder: URL) -> Bool {
        var db: OpaquePointer?
        sqlite3_open(folder.appending(path: Cache.name).path, &db)
        defer { sqlite3_close(db) }
        return sqlite3_exec(db, "INSERT INTO search(search, rank) VALUES ('integrity-check', 1)", nil, nil, nil) == SQLITE_OK
    }

    private func search(_ folder: URL, _ text: String) -> [String] {
        Cache(folder)!.search(text.split(separator: " ").map { Fuzzy.fold(String($0)) })
    }

    private func verify(_ folders: [URL], _ result: Library.Snapshot, gone: [String] = [], sourceLocation: SourceLocation = #_sourceLocation) {
        let files = audio(folders)
        let loaded = Set(result.albums.flatMap(\.tracks).map(\.url.path))
        #expect(loaded == files, sourceLocation: sourceLocation)

        for folder in folders {
            let inside = files.filter { $0.hasPrefix(folder.path + "/") }
            #expect(stored(folder) == inside, sourceLocation: sourceLocation)
            #expect(consistent(folder), sourceLocation: sourceLocation)

            for file in inside {
                let title = URL(filePath: file).deletingPathExtension().lastPathComponent
                guard Fuzzy.fold(title).count >= 3 else { continue }
                #expect(search(folder, title).contains(file), "\(title) not found", sourceLocation: sourceLocation)
            }

            for word in gone where Fuzzy.fold(word).count >= 3 {
                #expect(search(folder, word).allSatisfy { files.contains($0) }, "\(word) still found", sourceLocation: sourceLocation)
            }
        }
    }

    private func load(_ folders: URL...) async -> Library.Snapshot {
        await Library.load(folders, [:])
    }

    @Test func anEmptyFolder() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = await load(folder)

        #expect(result.albums.isEmpty)
        verify([folder], result)
    }

    @Test func oneFile() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/lonely.mp3")

        verify([folder], await load(folder))
    }

    @Test func manyFiles() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for number in 0..<120 {
            try put(folder, "Album \(number % 7)/song\(number)x.mp3", samples[number % samples.count])
        }

        verify([folder], await load(folder))
    }

    @Test func deeplyNestedFiles() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "a/b/c/d/e/f/g/deepest.mp3")
        try put(folder, "a/b/shallow.mp3")

        verify([folder], await load(folder))
    }

    @Test func addingOneFile() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/first.mp3")
        _ = await load(folder)

        try put(folder, "Album/second.mp3", "vbr.mp3")

        verify([folder], await load(folder))
    }

    @Test func addingManyFilesAtOnce() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/first.mp3")
        _ = await load(folder)

        for number in 0..<300 {
            try put(folder, "Bulk \(number / 50)/bulk\(number)y.mp3", samples[number % samples.count])
        }

        verify([folder], await load(folder))
    }

    @Test func removingOneFile() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/stays.mp3")
        try put(folder, "Album/leaves.mp3")
        _ = await load(folder)

        try remove(folder, "Album/leaves.mp3")

        verify([folder], await load(folder), gone: ["leaves"])
    }

    @Test func removingEveryFile() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/alpha.mp3")
        try put(folder, "Other/bravo.mp3")
        _ = await load(folder)

        try remove(folder, "Album")
        try remove(folder, "Other")
        let result = await load(folder)

        #expect(result.albums.isEmpty)
        #expect(Cache(folder)!.covers().isEmpty)
        verify([folder], result, gone: ["alpha", "bravo", "Album", "Other"])
    }

    @Test func removingASubtree() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Keep/keeper.mp3")
        try put(folder, "Drop/One/dropone.mp3")
        try put(folder, "Drop/Two/droptwo.mp3")
        _ = await load(folder)

        try remove(folder, "Drop")

        verify([folder], await load(folder), gone: ["dropone", "droptwo"])
    }

    @Test func renamingAFile() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/oldname.mp3")
        _ = await load(folder)

        try move(folder, "Album/oldname.mp3", "Album/newname.mp3")

        verify([folder], await load(folder), gone: ["oldname"])
    }

    @Test func renamingAFolder() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Oldalbum/track.mp3")
        _ = await load(folder)

        try move(folder, "Oldalbum", "Newalbum")
        let result = await load(folder)

        #expect(result.albums.map(\.title) == ["Newalbum"])
        #expect(search(folder, "newalbum") == [folder.path + "/Newalbum/track.mp3"])
        verify([folder], result, gone: ["oldalbum"])
    }

    @Test func movingAFileBetweenFolders() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "From/traveler.mp3")
        try put(folder, "To/resident.mp3")
        _ = await load(folder)

        try move(folder, "From/traveler.mp3", "To/traveler.mp3")
        let result = await load(folder)

        #expect(search(folder, "traveler") == [folder.path + "/To/traveler.mp3"])
        verify([folder], result)
    }

    @Test func swappingTwoNames() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/left.mp3", "cbr.mp3")
        try put(folder, "Album/right.mp3", "vbr-mono.mp3")
        _ = await load(folder)

        try move(folder, "Album/left.mp3", "Album/temp.mp3")
        try move(folder, "Album/right.mp3", "Album/left.mp3")
        try move(folder, "Album/temp.mp3", "Album/right.mp3")
        let result = await load(folder)
        let fresh = await load(try copy(folder))

        let durations = Dictionary(result.albums.flatMap(\.tracks).map { ($0.url.lastPathComponent, $0.duration) }) { a, _ in a }
        let expected = Dictionary(fresh.albums.flatMap(\.tracks).map { ($0.url.lastPathComponent, $0.duration) }) { a, _ in a }
        #expect(durations == expected)
        verify([folder], result)
    }

    @Test func replacingTheContent() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/changing.mp3", "cbr.mp3")
        _ = await load(folder)

        try put(folder, "Album/changing.mp3", "vbr-mono.mp3", date: 2_000_000)
        let result = await load(folder)
        let fresh = await load(try copy(folder))

        #expect(result.albums.flatMap(\.tracks).map(\.duration) == fresh.albums.flatMap(\.tracks).map(\.duration))
        verify([folder], result)
    }

    @Test func sameSizeWithNewBytes() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/flipped.mp3")
        _ = await load(folder)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000_000)], ofItemAtPath: folder.appending(path: "Album/flipped.mp3").path)
        _ = await load(folder)

        let file = folder.appending(path: "Album/flipped.mp3")
        var data = try Data(contentsOf: file)
        data[data.count - 1] ^= 0xFF
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 4_000_000)], ofItemAtPath: file.path)

        verify([folder], await load(folder))
        #expect(Cache(folder)!.entries()["Album/flipped.mp3"]?.hash == Library.hash(file))
    }

    @Test func touchingWithoutChanges() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/touched.mp3")
        _ = await load(folder)

        for date in [5_000_000.0, 6_000_000, 7_000_000] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: folder.appending(path: "Album/touched.mp3").path)
            let result = await load(folder)
            #expect(Cache(folder)!.entries()["Album/touched.mp3"]?.modified == Date(timeIntervalSince1970: date).timeIntervalSinceReferenceDate)
            verify([folder], result)
        }
    }

    @Test func aFileBecomesUnreadable() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/broken.mp3")
        try put(folder, "Album/healthy.mp3")
        _ = await load(folder)

        try Data(repeating: 0, count: 128).write(to: folder.appending(path: "Album/broken.mp3"))
        let result = await load(folder)

        #expect(!stored(folder).contains(folder.path + "/Album/broken.mp3"))
        #expect(search(folder, "broken").isEmpty)
        #expect(Set(result.albums.flatMap(\.tracks).map(\.url.path)) == [folder.path + "/Album/healthy.mp3"])
        #expect(consistent(folder))
    }

    @Test func aFileBecomesReadableAgain() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 0, count: 128).write(to: folder.appending(path: "phoenix.mp3"))
        _ = await load(folder)
        #expect(stored(folder).isEmpty)

        try put(folder, "phoenix.mp3", date: 8_000_000)

        verify([folder], await load(folder))
    }

    @Test func addingAndRemovingBetweenScansIsANoOp() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/constant.mp3")
        _ = await load(folder)

        try put(folder, "Album/ghost.mp3")
        try remove(folder, "Album/ghost.mp3")

        verify([folder], await load(folder), gone: ["ghost"])
    }

    @Test func aDeletedCache() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/survivor.mp3")
        _ = await load(folder)

        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: folder.appending(path: Cache.name + suffix)) }

        verify([folder], await load(folder))
    }

    @Test func aCorruptCache() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/resilient.mp3")
        _ = await load(folder)

        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(at: folder.appending(path: Cache.name + suffix)) }
        try Data(repeating: 0x5A, count: 65_536).write(to: folder.appending(path: Cache.name))

        verify([folder], await load(folder))
    }

    @Test func aCacheWithRowsForFilesThatNeverExisted() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/real.mp3")
        let fake = Track(url: folder.appending(path: "Album/phantom.mp3"), title: "phantom", artist: "Nobody", album: "Album", number: 0, disc: 0, albumArtist: "", year: 0, duration: 1, albumID: "fake")
        Cache(folder)!.save([Cache.Change(path: "Album/phantom.mp3", modified: 1, size: 1, track: fake)], removed: [], covers: ["fake": Data([1])])

        let result = await load(folder)

        #expect(Cache(folder)!.covers()["fake"] == nil)
        verify([folder], result, gone: ["phantom"])
    }

    @Test func aCacheWithWrongTagsForAnUnchangedFile() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/honest.mp3")
        _ = await load(folder)

        var db: OpaquePointer?
        sqlite3_open(folder.appending(path: Cache.name).path, &db)
        sqlite3_exec(db, "UPDATE tracks SET size = size + 99", nil, nil, nil)
        sqlite3_close(db)

        verify([folder], await load(folder))
    }

    @Test func aScanStoppedAtEachStepThenAFullScan() async throws {
        for stop in 1...4 {
            let folder = try folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            for number in 0..<100 {
                try put(folder, "Old/old\(number)z.mp3")
            }
            _ = await load(folder)
            for number in stride(from: 0, to: 100, by: 2) {
                try remove(folder, "Old/old\(number)z.mp3")
            }
            for number in 0..<600 {
                try put(folder, "New \(number / 100)/new\(number)w.mp3", samples[number % samples.count])
            }

            final class Count: @unchecked Sendable { var value = 0 }
            let count = Count()
            _ = await Library.load([folder], [:]) { _ in
                count.value += 1
                return count.value < stop
            }
            #expect(consistent(folder), "stop \(stop)")
            #expect(stored(folder).isSubset(of: audio([folder])) || stop == 1, "stop \(stop)")

            verify([folder], await load(folder))
        }
    }

    @Test func twoFoldersChangeIndependently() async throws {
        let first = try folder()
        let second = try folder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try put(first, "A/firstone.mp3")
        try put(second, "B/secondone.mp3")
        _ = await load(first, second)

        try remove(first, "A/firstone.mp3")
        try put(second, "B/secondtwo.mp3")
        let result = await load(first, second)

        #expect(search(second, "firstone").isEmpty)
        #expect(search(first, "secondtwo").isEmpty)
        verify([first, second], result, gone: ["firstone"])
    }

    @Test func aFolderLeavesTheList() async throws {
        let first = try folder()
        let second = try folder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try put(first, "A/staying.mp3")
        try put(second, "B/going.mp3")
        _ = await load(first, second)

        let result = await load(first)

        #expect(Set(result.albums.flatMap(\.tracks).map(\.url.path)) == [first.path + "/A/staying.mp3"])
        verify([first], result)
        #expect(stored(second) == [second.path + "/B/going.mp3"])
    }

    @Test func aFolderOpenedThroughASymlink() async throws {
        let folder = try folder()
        let link = FileManager.default.temporaryDirectory.appending(path: "OverdriveLink-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        try put(folder, "Album/linked.mp3")

        let result = await Library.load([link], [:])

        #expect(Array(Cache(link)!.entries().keys) == ["Album/linked.mp3"])
        #expect(Cache(link)!.search(["linked"]) == result.albums.flatMap(\.tracks).map(\.url.path))
        #expect(consistent(folder))
    }

    @Test func namesWithAccents() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Motörhead/Ação Pública.mp3")
        let result = await load(folder)

        #expect(search(folder, "motor") == [folder.path + "/Motörhead/Ação Pública.mp3"])
        #expect(search(folder, "acao publica") == [folder.path + "/Motörhead/Ação Pública.mp3"])
        verify([folder], result)
    }

    @Test func namesWithSearchSyntax() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/say \"hello\" AND NOT (now)*.mp3")
        try put(folder, "Album/plain.mp3")
        let result = await load(folder)

        #expect(search(folder, "\"hello\"") == [folder.path + "/Album/say \"hello\" AND NOT (now)*.mp3"])
        #expect(search(folder, "(now)*") == [folder.path + "/Album/say \"hello\" AND NOT (now)*.mp3"])
        #expect(search(folder, "AND NOT").allSatisfy { audio([folder]).contains($0) })
        verify([folder], result)
    }

    @Test func longNamesAndSpaces() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = String(repeating: "verylongtitle ", count: 12).trimmingCharacters(in: .whitespaces)
        try put(folder, "Album With   Spaces/\(name).mp3")

        verify([folder], await load(folder))
    }

    @Test func caseDoesNotMatter() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/MiXeDcAsE.mp3")
        _ = await load(folder)

        #expect(search(folder, "mixedcase").count == 1)
        #expect(search(folder, "MIXEDCASE").count == 1)
    }

    @Test func hiddenAndOtherFilesAreIgnored() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/visible.mp3")
        try put(folder, "Album/.invisible.mp3")
        try put(folder, ".Hidden/secret.mp3")
        try Data("notes".utf8).write(to: folder.appending(path: "Album/readme.txt"))
        let result = await load(folder)

        #expect(Set(result.albums.flatMap(\.tracks).map(\.url.path)) == [folder.path + "/Album/visible.mp3"])
        #expect(search(folder, "invisible").isEmpty)
        #expect(search(folder, "secret").isEmpty)
        verify([folder], result)
    }

    @Test func bm25RanksTheClosestMatchFirst() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/zebra.mp3")
        try put(folder, "Album/zebra with a very long title and many other words around it.mp3")
        _ = await load(folder)

        let results = search(folder, "zebra")

        #expect(results.count == 2)
        #expect(results.first == folder.path + "/Album/zebra.mp3")
    }

    @Test func shortWordsUseOnlyTheFuzzySearch() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Album/ok.mp3")
        _ = await load(folder)

        #expect(search(folder, "ok").isEmpty)
        #expect(search(folder, "album").count == 1)
    }

    @Test func everyWordMustMatch() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try put(folder, "Rock/thunder.mp3")
        try put(folder, "Jazz/thunder.mp3")
        _ = await load(folder)

        #expect(search(folder, "thunder rock") == [folder.path + "/Rock/thunder.mp3"])
        #expect(search(folder, "thunder jazz") == [folder.path + "/Jazz/thunder.mp3"])
        #expect(search(folder, "thunder blues").isEmpty)
    }

    @Test func manyRoundsOfRandomChangesInTwoFolders() async throws {
        let first = try folder()
        let second = try folder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        var random = SystemRandomNumberGenerator()
        var files: [(URL, String)] = []
        var gone: [String] = []
        var counter = 0

        for round in 0..<30 {
            for _ in 0..<Int.random(in: 1...4, using: &random) {
                let folder = Bool.random(using: &random) ? first : second
                switch Int.random(in: 0..<5, using: &random) {
                case 0, 1:
                    let name = "Album \(Int.random(in: 0..<3, using: &random))/round\(round)n\(counter)q.mp3"
                    counter += 1
                    try put(folder, name, samples.randomElement(using: &random)!, date: Double(round))
                    files.append((folder, name))
                case 2 where !files.isEmpty:
                    let (folder, name) = files.remove(at: Int.random(in: 0..<files.count, using: &random))
                    try remove(folder, name)
                    gone.append(URL(filePath: name).deletingPathExtension().lastPathComponent)
                case 3 where !files.isEmpty:
                    let index = Int.random(in: 0..<files.count, using: &random)
                    let (folder, name) = files[index]
                    let renamed = "Album \(Int.random(in: 0..<3, using: &random))/moved\(round)r\(counter)k.mp3"
                    counter += 1
                    try move(folder, name, renamed)
                    files[index] = (folder, renamed)
                    gone.append(URL(filePath: name).deletingPathExtension().lastPathComponent)
                case 4 where !files.isEmpty:
                    let (folder, name) = files.randomElement(using: &random)!
                    try put(folder, name, samples.randomElement(using: &random)!, date: Double(100_000 + round))
                default:
                    break
                }
            }

            verify([first, second], await load(first, second), gone: gone)
        }
    }

    private func copy(_ folder: URL) throws -> URL {
        let target = FileManager.default.temporaryDirectory.appending(path: "OverdriveSyncCopy-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: folder, to: target)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(at: target.appending(path: Cache.name + suffix)) }
        return target
    }
}
