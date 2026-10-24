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
    static func comparator(_ column: Column, _ order: SortOrder) -> KeyPathComparator<Self>
}

nonisolated extension Track: Sortable {
    var song: Track { self }

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

    static func comparator(_ column: Column, _ order: SortOrder) -> KeyPathComparator<Row> {
        switch column {
        case .title: KeyPathComparator(\.track.title, order: order)
        case .artist: KeyPathComparator(\.track.artist, order: order)
        case .album: KeyPathComparator(\.track.album, order: order)
        case .time: KeyPathComparator(\.track.duration, order: order)
        }
    }
}

nonisolated struct Sort: Equatable, RawRepresentable {
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

func order<T: Sortable>(_ sort: Binding<Sort>, _ list: String) -> Binding<[KeyPathComparator<T>]> {
    Binding {
        sort.wrappedValue.comparators()
    } set: { picked in
        sort.wrappedValue = sort.wrappedValue.next(Sort(picked))
        Log.navigation.info("sort", metadata: ["list": "\(list)", "sort": "\(sort.wrappedValue.rawValue)"])
    }
}
