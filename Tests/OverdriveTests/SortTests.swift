import Foundation
import Testing
@testable import Overdrive

struct SortTests {
    private func track(_ title: String, _ artist: String = "A", _ duration: Double = 100) -> Track {
        Track(url: URL(filePath: "/m/\(title)-\(artist)-\(duration).mp3"), title: title, artist: artist, album: "Album", number: 1, disc: 1, albumArtist: "", year: 2000, duration: duration, albumID: "x")
    }

    private func album(_ title: String, _ artist: String, _ year: Int) -> Album {
        Album(id: "\(artist)/\(title)", title: title, artist: artist, year: year, tracks: [])
    }

    @Test func theSortIsSavedAsText() {
        #expect(Sort(.title).rawValue == "title")
        #expect(Sort(.time, ascending: false).rawValue == "-time")
        #expect(Sort().rawValue == "")
        #expect(Sort(rawValue: "-artist") == Sort(.artist, ascending: false))
        #expect(Sort(rawValue: "") == Sort())
        #expect(Sort(rawValue: "junk") == Sort())
    }

    @Test func noSortKeepsTheOrder() {
        let tracks = [track("b"), track("a")]
        #expect(Sort().apply(tracks).map(\.title) == ["b", "a"], "the queue and the playlists keep their own order")
    }

    @Test func aColumnSortsUpAndDown() {
        let tracks = [track("Song 10"), track("song 2"), track("Song 1")]
        #expect(Sort(.title).apply(tracks).map(\.title) == ["Song 1", "song 2", "Song 10"], "the order is the Finder order")
        #expect(Sort(.title, ascending: false).apply(tracks).map(\.title) == ["Song 10", "song 2", "Song 1"])
    }

    @Test func timeSortsAsANumber() {
        let tracks = [track("a", "A", 600), track("b", "A", 70), track("c", "A", 300)]
        #expect(Sort(.time).apply(tracks).map(\.title) == ["b", "c", "a"])
    }

    @Test func equalValuesKeepTheirOrder() {
        let tracks = [track("x", "B"), track("y", "A"), track("z", "B")]
        #expect(Sort(.artist).apply(tracks).map(\.title) == ["y", "x", "z"])
        #expect(Sort(.artist, ascending: false).apply(tracks).map(\.title) == ["x", "z", "y"])
    }

    @Test func rowsSortByTheirSong() {
        let rows = [Row(id: 0, track: track("b")), Row(id: 1, track: track("a"))]
        #expect(Sort(.title).apply(rows).map(\.id) == [1, 0], "a row keeps its id, so actions reach the right song")
    }

    @Test func aThirdClickRestoresTheOrder() {
        let up = Sort().next(Sort(.title))
        let down = up.next(Sort(.title, ascending: false))
        #expect(up == Sort(.title))
        #expect(down == Sort(.title, ascending: false))
        #expect(down.next(Sort(.title)) == Sort(), "up, down, then the own order of the list")
        #expect(down.next(Sort(.artist)) == Sort(.artist), "another column starts up")
    }

    @Test func theTableComparatorsMatchTheSort() {
        for column in Column.allCases {
            for ascending in [true, false] {
                let sort = Sort(column, ascending: ascending)
                let tracks: [KeyPathComparator<Track>] = sort.comparators()
                let rows: [KeyPathComparator<Row>] = sort.comparators()
                #expect(Sort(tracks) == sort)
                #expect(Sort(rows) == sort)
            }
        }
        #expect(Sort([KeyPathComparator<Track>]()) == Sort())
    }

    @Test func sortingTheWholeLibraryIsFast() {
        let tracks = (0..<20_000).map { track("Song \($0 % 997)", "Artist \($0 % 311)", Double($0 % 500)) }
        let start = ContinuousClock.now
        for column in Column.allCases { _ = Sort(column).apply(tracks) }
        #expect(ContinuousClock.now - start < .seconds(5), "a sort by artist of every song hung the app")
    }

    @Test @MainActor func theSortRunsOnlyWhenTheSortOrTheListChanges() {
        let cache = Sorted<Track>()
        let tracks = [track("b"), track("a")]

        #expect(cache.apply(Sort(.title), tracks).map(\.title) == ["a", "b"])
        _ = cache.apply(Sort(.title), tracks)
        _ = cache.apply(Sort(.title), tracks)
        #expect(cache.runs == 1, "a redraw, such as a click on a row, must not sort again")

        #expect(cache.apply(Sort(.title, ascending: false), tracks).map(\.title) == ["b", "a"])
        #expect(cache.apply(Sort(.title, ascending: false), tracks + [track("c")]).map(\.title) == ["c", "b", "a"])
        #expect(cache.runs == 3)
    }

    @Test @MainActor func aMovedRowSortsAgain() {
        let cache = Sorted<Row>()
        let song = track("a")
        _ = cache.apply(Sort(.title), [Row(id: 0, track: song), Row(id: 1, track: song)])
        #expect(cache.apply(Sort(.title), [Row(id: 1, track: song), Row(id: 0, track: song)]).map(\.id) == [1, 0], "the same song at another position is another row")
    }

    @Test func theSearchSortsOnlyWhatItFinds() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/Library.swift"), encoding: .utf8)

        #expect(source.contains("byYear = Library.chronological(snapshot.albums)"), "all the albums sort once per scan, not once per key")
        #expect(source.contains("filtered = byYear\n"), "an empty search uses the sorted albums")
        #expect(source.components(separatedBy: "Library.chronological(").count - 1 == 2, "only the found albums sort on a key")
        #expect(source.contains("byArtist = Dictionary(grouping: byYear, by: \\.artist)"), "the albums of each artist come from the sorted list")
    }

    @Test func albumsGoFromTheOldestToTheNewest() {
        let albums = [album("Late", "A", 2010), album("Unknown", "A", 0), album("Early", "B", 1990), album("Same B", "B", 2000), album("Same A", "A", 2000)]
        #expect(Library.chronological(albums).map(\.title) == ["Early", "Same A", "Same B", "Late", "Unknown"], "a year ties by artist, and an album without a year goes last")
    }

    @Test func everyListWithAHeaderSorts() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appending(path: "Sources/Overdrive/Views.swift"), encoding: .utf8)

        let tables = try Regex(#"\bTable\("#)
        #expect(source.matches(of: tables).count == 4)
        #expect(source.matches(of: tables).count == source.components(separatedBy: "sortOrder: order($sort").count - 1, "every table sorts")
        #expect(source.components(separatedBy: "TableColumn(\"").count == source.components(separatedBy: "\", value: \\.").count, "every column sorts")
        #expect(source.components(separatedBy: "guard sort.column == nil else { return Log.navigation.debug(\"drop ignored\"").count - 1 == 2, "a drag reorders the queue and a playlist only in their own order")
        #expect(source.contains("AlbumGrid(albums: library.albums(by: name))"), "the albums of an artist go by year")
        #expect(source.components(separatedBy: "@State private var sort = Sort()").count - 1 == 4, "the sort is not saved")
        #expect(source.components(separatedBy: ".onChange(of: active) { if !active { sort = Sort() } }").count - 1 == 4, "a list that leaves goes back to its own order")
        #expect(!source.contains("@AppStorage(\"sort."), "the sort is not saved")
        #expect(source.components(separatedBy: "{ if !active { sort = Sort() } }\n").count - 1 == source.components(separatedBy: ".id(sort)").count - 1, "a SwiftUI Table that diffs a new order of the whole library hangs the main thread; a new sort builds a new table")
        #expect(source.components(separatedBy: "sorted.apply(sort, ").count - 1 == 4, "the sorted rows are kept between redraws")
    }
}
