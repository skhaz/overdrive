import SwiftUI

nonisolated enum Column: String, CaseIterable {
    case title, artist, album, plays, time

    var text: KeyPath<Track, String>? {
        switch self {
        case .title: \.title
        case .artist: \.artist
        case .album: \.album
        case .plays, .time: nil
        }
    }
}

nonisolated protocol Sortable {
    var song: Track { get }
    var plays: Int { get }
    func same(_ other: Self) -> Bool
    static func comparator(_ column: Column, _ order: SortOrder) -> KeyPathComparator<Self>
}

nonisolated extension Row: Sortable {
    var song: Track { track }

    func same(_ other: Row) -> Bool { id == other.id && track.same(other.track) && plays == other.plays }

    static func comparator(_ column: Column, _ order: SortOrder) -> KeyPathComparator<Row> {
        switch column {
        case .title: KeyPathComparator(\.track.title, order: order)
        case .artist: KeyPathComparator(\.track.artist, order: order)
        case .album: KeyPathComparator(\.track.album, order: order)
        case .plays: KeyPathComparator(\.plays, order: order)
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
            let result: ComparisonResult
            if let text = column.text {
                let one = items[first].song[keyPath: text], two = items[second].song[keyPath: text]
                result = one.localizedStandardCompare(two)
            } else if column == .plays {
                let one = items[first].plays, two = items[second].plays
                result = one == two ? .orderedSame : one < two ? .orderedAscending : .orderedDescending
            } else {
                let one = items[first].song.duration, two = items[second].song.duration
                result = one == two ? .orderedSame : one < two ? .orderedAscending : .orderedDescending
            }
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
    private var token: AnyHashable?
    private(set) var runs = 0

    func apply(_ sort: Sort, token: AnyHashable, _ build: () -> [T]) -> [T] {
        if sort == self.sort, token == self.token { return result }

        self.token = token
        self.sort = sort
        source = build()
        result = sort.apply(source)
        runs += 1
        return result
    }

    func apply(_ sort: Sort, _ items: [T]) -> [T] {
        if sort == self.sort, items.count == source.count, items.elementsEqual(source, by: { $0.same($1) }) { return result }

        token = nil
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
