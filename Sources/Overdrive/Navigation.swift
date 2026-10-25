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
    case queue
    case about

    init?(key: String) {
        if key.hasPrefix("playlist:") {
            self = .playlist(String(key.dropFirst(9)))
        } else if key == "liked" {
            self = .liked
        } else if key == "queue" {
            self = .queue
        } else if key == "about" {
            self = .about
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
        case .queue: "queue"
        case .about: "about"
        }
    }

    var title: String {
        switch self {
        case .section(let section): section.rawValue
        case .playlist(let name): name
        case .liked: "Liked Songs"
        case .queue: "Queue"
        case .about: "About"
        }
    }
}

nonisolated enum Route: Hashable {
    case album(Album)
    case artist(String)

    static func == (lhs: Route, rhs: Route) -> Bool {
        lhs.key == rhs.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }

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
    var query = ""

    static func == (lhs: Place, rhs: Place) -> Bool {
        lhs.page == rhs.page && lhs.path == rhs.path
    }

    func resolved(_ albums: [String: Album], _ artists: Set<String>) -> Place {
        Place(page: page, path: Self.resolve(path, albums, artists), position: position, query: query)
    }

    static func resolve(_ path: [Route], _ albums: [String: Album], _ artists: Set<String>) -> [Route] {
        var routes: [Route] = []
        for route in path {
            switch route {
            case .album(let album):
                guard let current = albums[album.id] else { return routes }
                routes.append(.album(current))
            case .artist(let name):
                guard artists.contains(name) else { return routes }
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
    private(set) var searching = false
    private(set) var query: String
    private var quiet = false
    private var paths: [Page: [Route]] = [:]

    init(page: Page, path: [Route] = [], query: String = "") {
        place = Place(page: page, path: path, query: query)
        pages = [page]
        self.query = query
    }

    var page: Page { place.page }
    var path: [Route] { place.path }
    var canGoBack: Bool { !back.isEmpty || !place.path.isEmpty }

    var lyrics: Bool {
        switch (place.path.last, place.page) {
        case (.album, _): true
        case (.artist, _), (nil, .section(.albums)), (nil, .section(.artists)), (_, .about): false
        case (nil, .section(.songs)), (nil, .liked), (nil, .playlist), (nil, .queue): true
        }
    }

    func path(of page: Page) -> [Route] {
        page == place.page ? place.path : paths[page] ?? []
    }

    mutating func open(_ page: Page, leaving position: Position = Position()) {
        visit(Place(page: page, path: []), leaving: position)
    }

    mutating func filter(_ page: Page, to text: String, leaving position: Position = Position()) {
        open(page, leaving: position)
        searching = true
        quiet = text != query
    }

    mutating func show(_ path: [Route], leaving position: Position = Position()) {
        visit(Place(page: place.page, path: path), leaving: position)
    }

    @discardableResult
    mutating func push(_ route: Route, leaving position: Position = Position()) -> Bool {
        guard place.path.last != route else { return false }

        show(place.path + [route], leaving: position)
        return true
    }

    mutating func played(_ album: Album, leaving position: Position = Position()) {
        guard case .section = place.page else { return }

        show([.album(album)], leaving: position)
    }

    mutating func searched(from old: String, to new: String, leaving position: Position = Position()) {
        defer { query = new }

        if quiet {
            quiet = false
            return
        }

        guard !new.isEmpty, new != old else { return }

        open(.section(.songs), leaving: position)
        searching = true
    }

    mutating func restore(_ path: [Route], on page: Page) {
        guard place.page == page, place.path.isEmpty, back.isEmpty, forward.isEmpty else { return }

        place = Place(page: place.page, path: path, query: query)
    }

    @discardableResult
    mutating func pop(leaving position: Position = Position()) -> Bool {
        guard back.isEmpty, !place.path.isEmpty else { return false }

        forward.append(left(position))
        move(to: Place(page: place.page, path: Array(place.path.dropLast()), query: query))
        return true
    }

    mutating func prune(_ names: [String], fallback: Page) {
        let names = Set(names)
        for page in Set(pages + back.map(\.page) + forward.map(\.page) + [place.page]) {
            if case .playlist(let name) = page, !names.contains(name) { remove(page, fallback: fallback) }
        }
    }

    @discardableResult
    mutating func goBack(leaving position: Position = Position()) -> Bool {
        guard let previous = back.popLast() else { return false }

        forward.append(left(position))
        move(to: previous)
        arrive()
        return true
    }

    @discardableResult
    mutating func goForward(leaving position: Position = Position()) -> Bool {
        guard let next = forward.popLast() else { return false }

        back.append(left(position))
        move(to: next)
        arrive()
        return true
    }

    mutating func remove(_ page: Page, fallback: Page) {
        searching = false
        quiet = false
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
        let artists = Set(albums.map(\.artist))
        place = place.resolved(index, artists)
        back = back.map { $0.resolved(index, artists) }
        forward = forward.map { $0.resolved(index, artists) }
        paths = paths.mapValues { Place.resolve($0, index, artists) }
        collapse()
    }

    private mutating func visit(_ new: Place, leaving position: Position) {
        guard new != place else { return }

        back.append(left(position))
        forward.removeAll()
        move(to: new)
    }

    private mutating func arrive() {
        if !place.query.isEmpty || place.query != query { searching = true }
        if place.query != query { quiet = true }
    }

    private mutating func move(to new: Place) {
        searching = false
        quiet = false
        if new.page != place.page {
            paths[place.page] = place.path
            if !pages.contains(new.page) { pages.append(new.page) }
        }
        place = new
    }

    private func left(_ position: Position) -> Place {
        var old = place
        old.position = position
        old.query = query
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
