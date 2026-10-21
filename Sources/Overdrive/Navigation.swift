nonisolated enum Section: String, CaseIterable, Identifiable {
    case albums = "Albums", artists = "Artists", songs = "Songs"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .albums: "square.stack"
        case .artists: "music.microphone"
        case .songs: "music.note"
        }
    }
}

nonisolated enum Page: Hashable {
    case section(Section)
    case playlist(String)
    case liked

    init?(key: String) {
        if key.hasPrefix("playlist:") {
            self = .playlist(String(key.dropFirst(9)))
        } else if key == "liked" {
            self = .liked
        } else if let section = Section(rawValue: key) {
            self = .section(section)
        } else {
            return nil
        }
    }

    var key: String {
        switch self {
        case .section(let section): section.rawValue
        case .playlist(let name): "playlist:" + name
        case .liked: "liked"
        }
    }

    var title: String {
        switch self {
        case .section(let section): section.rawValue
        case .playlist(let name): name
        case .liked: "Liked Songs"
        }
    }
}

nonisolated enum Route: Hashable {
    case album(Album)
    case artist(String)

    init?(key: String, albums: [Album]) {
        if key.hasPrefix("artist:") {
            self = .artist(String(key.dropFirst(7)))
        } else if key.hasPrefix("album:"), let album = albums.first(where: { $0.id == StoredPath.normalizeID(String(key.dropFirst(6))) }) {
            self = .album(album)
        } else {
            return nil
        }
    }

    var key: String {
        switch self {
        case .album(let album): "album:" + album.id
        case .artist(let name): "artist:" + name
        }
    }
}

nonisolated struct Place: Equatable {
    let page: Page
    let path: [Route]

    func resolved(_ albums: [String: Album]) -> Place {
        var routes: [Route] = []
        for route in path {
            switch route {
            case .album(let album):
                guard let current = albums[album.id] else { return Place(page: page, path: routes) }
                routes.append(.album(current))
            case .artist:
                routes.append(route)
            }
        }
        return Place(page: page, path: routes)
    }
}

nonisolated struct Navigation {
    private(set) var place: Place
    private(set) var back: [Place] = []
    private(set) var forward: [Place] = []

    init(page: Page, path: [Route] = []) {
        place = Place(page: page, path: path)
    }

    var page: Page { place.page }
    var path: [Route] { place.path }

    mutating func open(_ page: Page) {
        visit(Place(page: page, path: []))
    }

    mutating func show(_ path: [Route]) {
        visit(Place(page: place.page, path: path))
    }

    mutating func restore(_ path: [Route]) {
        guard place.path.isEmpty else { return }

        place = Place(page: place.page, path: path)
    }

    @discardableResult
    mutating func goBack() -> Bool {
        guard let previous = back.popLast() else { return false }

        forward.append(place)
        place = previous
        return true
    }

    @discardableResult
    mutating func goForward() -> Bool {
        guard let next = forward.popLast() else { return false }

        back.append(place)
        place = next
        return true
    }

    mutating func remove(_ page: Page, fallback: Page) {
        back.removeAll { $0.page == page }
        forward.removeAll { $0.page == page }
        if place.page == page { place = Place(page: fallback, path: []) }
        collapse()
    }

    mutating func refresh(_ albums: [Album]) {
        let index = Dictionary(albums.map { ($0.id, $0) }) { first, _ in first }
        place = place.resolved(index)
        back = back.map { $0.resolved(index) }
        forward = forward.map { $0.resolved(index) }
        collapse()
    }

    private mutating func visit(_ new: Place) {
        guard new != place else { return }

        back.append(place)
        forward.removeAll()
        place = new
    }

    private mutating func collapse() {
        back = Self.distinct(back)
        forward = Self.distinct(forward)
        while back.last == place { back.removeLast() }
        while forward.last == place { forward.removeLast() }
    }

    private static func distinct(_ places: [Place]) -> [Place] {
        var result: [Place] = []
        result.reserveCapacity(places.count)
        for place in places where place != result.last {
            result.append(place)
        }
        return result
    }
}

nonisolated enum Step {
    case up, down, left, right, extendUp, extendDown

    func index(first: Int?, last: Int?, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }

        switch self {
        case .up: return first.map { max($0 - columns, 0) } ?? count - 1
        case .down: return last.map { min($0 + columns, count - 1) } ?? 0
        case .left: return columns > 1 ? first.map { max($0 - 1, 0) } ?? count - 1 : nil
        case .right: return columns > 1 ? last.map { min($0 + 1, count - 1) } ?? 0 : nil
        case .extendUp: return first.flatMap { $0 > 0 ? $0 - 1 : nil }
        case .extendDown: return last.flatMap { $0 < count - 1 ? $0 + 1 : nil }
        }
    }
}
