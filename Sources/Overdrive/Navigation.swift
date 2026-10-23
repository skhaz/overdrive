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
        } else if key.hasPrefix("album:"), let album = albums.first(where: { $0.id == String(key.dropFirst(6)) }) {
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

nonisolated struct Position: Equatable {
    var offset: Double?
    var selection: [String] = []
}

nonisolated struct Place: Equatable {
    let page: Page
    let path: [Route]
    var position = Position()

    static func == (lhs: Place, rhs: Place) -> Bool {
        lhs.page == rhs.page && lhs.path == rhs.path
    }

    func resolved(_ albums: [String: Album]) -> Place {
        Place(page: page, path: Self.resolve(path, albums), position: position)
    }

    static func resolve(_ path: [Route], _ albums: [String: Album]) -> [Route] {
        var routes: [Route] = []
        for route in path {
            switch route {
            case .album(let album):
                guard let current = albums[album.id] else { return routes }
                routes.append(.album(current))
            case .artist:
                routes.append(route)
            }
        }
        return routes
    }
}

nonisolated struct Navigation {
    private(set) var place: Place
    private(set) var back: [Place] = []
    private(set) var forward: [Place] = []
    private(set) var pages: [Page]
    private var paths: [Page: [Route]] = [:]

    init(page: Page, path: [Route] = []) {
        place = Place(page: page, path: path)
        pages = [page]
    }

    var page: Page { place.page }
    var path: [Route] { place.path }

    func path(of page: Page) -> [Route] {
        page == place.page ? place.path : paths[page] ?? []
    }

    mutating func open(_ page: Page, leaving position: Position = Position()) {
        visit(Place(page: page, path: []), leaving: position)
    }

    mutating func show(_ path: [Route], leaving position: Position = Position()) {
        visit(Place(page: place.page, path: path), leaving: position)
    }

    mutating func write(_ path: [Route], on page: Page, leaving position: Position = Position()) {
        guard page == place.page, path != place.path else { return }

        show(path, leaving: position)
    }

    mutating func played(_ album: Album, leaving position: Position = Position()) {
        guard case .section = place.page else { return }

        show([.album(album)], leaving: position)
    }

    mutating func searched(from old: String, to new: String, leaving position: Position = Position()) {
        guard old.isEmpty, !new.isEmpty else { return }

        switch place.page {
        case .liked, .playlist: open(.section(.songs), leaving: position)
        case .section: break
        }
    }

    mutating func restore(_ path: [Route]) {
        guard place.path.isEmpty else { return }

        place = Place(page: place.page, path: path)
    }

    @discardableResult
    mutating func goBack(leaving position: Position = Position()) -> Bool {
        guard let previous = back.popLast() else { return false }

        forward.append(left(position))
        move(to: previous)
        return true
    }

    @discardableResult
    mutating func goForward(leaving position: Position = Position()) -> Bool {
        guard let next = forward.popLast() else { return false }

        back.append(left(position))
        move(to: next)
        return true
    }

    mutating func remove(_ page: Page, fallback: Page) {
        back.removeAll { $0.page == page }
        forward.removeAll { $0.page == page }
        pages.removeAll { $0 == page }
        paths[page] = nil
        if place.page == page {
            place = Place(page: fallback, path: paths[fallback] ?? [])
            if !pages.contains(fallback) { pages.append(fallback) }
        }
        collapse()
    }

    mutating func refresh(_ albums: [Album]) {
        let index = Dictionary(albums.map { ($0.id, $0) }) { first, _ in first }
        place = place.resolved(index)
        back = back.map { $0.resolved(index) }
        forward = forward.map { $0.resolved(index) }
        paths = paths.mapValues { Place.resolve($0, index) }
        collapse()
    }

    private mutating func visit(_ new: Place, leaving position: Position) {
        guard new != place else { return }

        back.append(left(position))
        forward.removeAll()
        move(to: new)
    }

    private mutating func move(to new: Place) {
        if new.page != place.page {
            paths[place.page] = place.path
            if !pages.contains(new.page) { pages.append(new.page) }
        }
        place = new
    }

    private func left(_ position: Position) -> Place {
        var old = place
        old.position = position
        return old
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
