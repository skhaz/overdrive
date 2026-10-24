import SwiftUI

nonisolated enum Column: String, CaseIterable {
    case title, artist, album, time

    var text: KeyPath<Track, String>? {
        switch self {
        case .title: \.title
        case .artist: \.artist
        case .album: \.album
        case .time: nil
        }
    }
}

nonisolated protocol Sortable {
    var song: Track { get }
    func same(_ other: Self) -> Bool
    static func comparator(_ column: Column, _ order: SortOrder) -> KeyPathComparator<Self>
}

nonisolated extension Track: Sortable {
    var song: Track { self }

    func same(_ other: Track) -> Bool { self == other }

    static func comparator(_ column: Column, _ order: SortOrder) -> KeyPathComparator<Track> {
        switch column {
        case .title: KeyPathComparator(\.title, order: order)
        case .artist: KeyPathComparator(\.artist, order: order)
        case .album: KeyPathComparator(\.album, order: order)
        case .time: KeyPathComparator(\.duration, order: order)
        }
    }
}

nonisolated extension Row: Sortable {
    var song: Track { track }

    func same(_ other: Row) -> Bool { id == other.id && track == other.track }

    static func comparator(_ column: Column, _ order: SortOrder) -> KeyPathComparator<Row> {
        switch column {
        case .title: KeyPathComparator(\.track.title, order: order)
        case .artist: KeyPathComparator(\.track.artist, order: order)
        case .album: KeyPathComparator(\.track.album, order: order)
        case .time: KeyPathComparator(\.track.duration, order: order)
        }
    }
}

nonisolated struct Sort: Hashable, RawRepresentable {
    var column: Column?
    var ascending = true

    init(_ column: Column? = nil, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }

    init(rawValue: String) {
        let descending = rawValue.hasPrefix("-")
        self.init(Column(rawValue: descending ? String(rawValue.dropFirst()) : rawValue), ascending: !descending)
    }

    var rawValue: String {
        column.map { (ascending ? "" : "-") + $0.rawValue } ?? ""
    }

    init<T: Sortable>(_ comparators: [KeyPathComparator<T>]) {
        guard let first = comparators.first, let column = Column.allCases.first(where: { T.comparator($0, .forward).keyPath == first.keyPath }) else {
            self.init()
            return
        }

        self.init(column, ascending: first.order == .forward)
    }

    func comparators<T: Sortable>() -> [KeyPathComparator<T>] {
        column.map { [T.comparator($0, ascending ? .forward : .reverse)] } ?? []
    }

    func next(_ picked: Sort) -> Sort {
        picked.column == column && !ascending && picked.ascending ? Sort() : picked
    }

    func apply<T: Sortable>(_ items: [T]) -> [T] {
        guard let column else { return items }

        let order = items.indices.sorted { first, second in
            let one = items[first].song, two = items[second].song
            let result = column.text.map { one[keyPath: $0].localizedStandardCompare(two[keyPath: $0]) }
                ?? (one.duration == two.duration ? .orderedSame : one.duration < two.duration ? .orderedAscending : .orderedDescending)
            guard result != .orderedSame else { return first < second }

            return (result == .orderedAscending) == ascending
        }
        return order.map { items[$0] }
    }
}

final class Sorted<T: Sortable> {
    private var sort = Sort()
    private var source: [T] = []
    private var result: [T] = []
    private(set) var runs = 0

    func apply(_ sort: Sort, _ items: [T]) -> [T] {
        if sort == self.sort, items.count == source.count, items.elementsEqual(source, by: { $0.same($1) }) { return result }

        self.sort = sort
        source = items
        result = sort.apply(items)
        runs += 1
        return result
    }
}

func order<T: Sortable>(_ sort: Binding<Sort>, _ list: String) -> Binding<[KeyPathComparator<T>]> {
    Binding {
        sort.wrappedValue.comparators()
    } set: { picked in
        sort.wrappedValue = sort.wrappedValue.next(Sort(picked))
        Log.navigation.info("sort", metadata: ["list": "\(list)", "sort": "\(sort.wrappedValue.rawValue)"])
    }
}
