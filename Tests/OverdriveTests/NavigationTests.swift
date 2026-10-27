import Testing
@testable import Overdrive

struct NavigationTests {
    private static func album(_ id: String, _ title: String = "Title") -> Album {
        Album(id: id, title: title, artist: "Artist", year: 2000, tracks: [])
    }

    private let albums = Page.section(.albums)
    private let songs = Page.section(.songs)
    private let mix = Page.playlist("Mix")

    @Test func startsWithoutHistory() {
        let navigation = Navigation(page: songs)

        #expect(navigation.page == songs)
        #expect(navigation.path.isEmpty)
        #expect(navigation.back.isEmpty)
        #expect(navigation.forward.isEmpty)
    }

    @Test func goesBackAndForwardAcrossPagesAndPaths() {
        var moved = false
        let one = Self.album("one")
        var navigation = Navigation(page: albums)
        navigation.show([.album(one)])
        navigation.open(songs)
        navigation.show([.artist("Artist")])

        moved = navigation.goBack()
        #expect(moved)
        #expect(navigation.place == Place(page: songs, path: []))
        moved = navigation.goBack()
        #expect(moved)
        #expect(navigation.place == Place(page: albums, path: [.album(one)]))
        moved = navigation.goBack()
        #expect(moved)
        #expect(navigation.place == Place(page: albums, path: []))
        moved = navigation.goBack()
        #expect(!moved)
        #expect(navigation.place == Place(page: albums, path: []))

        moved = navigation.goForward()
        #expect(moved)
        moved = navigation.goForward()
        #expect(moved)
        moved = navigation.goForward()
        #expect(moved)
        #expect(navigation.place == Place(page: songs, path: [.artist("Artist")]))
        moved = navigation.goForward()
        #expect(!moved)
        #expect(navigation.back.count == 3)
    }

    @Test func goingBackThenShowingAnotherAlbumReplacesThePath() {
        var navigation = Navigation(page: songs)
        navigation.show([.album(Self.album("one"))])
        navigation.goBack()
        navigation.show([.album(Self.album("two"))])

        #expect(navigation.path == [.album(Self.album("two"))])
        #expect(navigation.back == [Place(page: songs, path: [])])
    }

    @Test func showingTheAlbumThatIsOpenKeepsTheHistory() {
        let one = Self.album("one")
        var navigation = Navigation(page: songs)
        navigation.show([.album(one)])
        navigation.show([.album(one)])

        #expect(navigation.path == [.album(one)])
        #expect(navigation.back == [Place(page: songs, path: [])])
        #expect(navigation.forward.isEmpty)
    }

    @Test func newVisitClearsForward() {
        var navigation = Navigation(page: albums)
        navigation.open(songs)
        navigation.goBack()
        navigation.open(.liked)

        #expect(navigation.forward.isEmpty)
        #expect(navigation.back == [Place(page: albums, path: [])])
    }

    @Test func ignoresVisitToTheSamePlace() {
        var navigation = Navigation(page: albums)
        navigation.open(albums)
        navigation.show([])

        #expect(navigation.back.isEmpty)
    }

    @Test func openingTheCurrentPageGoesToItsRoot() {
        var navigation = Navigation(page: albums)
        navigation.show([.album(Self.album("one"))])
        navigation.open(albums)

        #expect(navigation.path.isEmpty)
        #expect(navigation.back.count == 2)
    }

    @Test func goingBackThenForwardKeepsBothStacks() {
        var navigation = Navigation(page: albums)
        navigation.open(songs)
        navigation.open(.liked)
        navigation.goBack()

        #expect(navigation.back == [Place(page: albums, path: [])])
        #expect(navigation.forward == [Place(page: .liked, path: [])])
        navigation.goBack()
        navigation.goForward()
        #expect(navigation.page == songs)
        #expect(navigation.forward == [Place(page: .liked, path: [])])
    }

    @Test func restoresOnlyAnEmptyPathWithoutHistory() {
        let one = Self.album("one")
        var navigation = Navigation(page: albums)
        navigation.restore([.album(one)], on: albums)

        #expect(navigation.path == [.album(one)])
        #expect(navigation.back.isEmpty)

        navigation.restore([.artist("Other")], on: albums)
        #expect(navigation.path == [.album(one)])
    }

    @Test func deletingTheCurrentPlaylistOpensTheFallback() {
        var navigation = Navigation(page: albums)
        navigation.open(mix)
        navigation.remove(mix, fallback: albums)

        #expect(navigation.place == Place(page: albums, path: []))
        #expect(navigation.back.isEmpty)
        #expect(navigation.forward.isEmpty)
    }

    @Test func deletingAPlaylistMergesTheScreensAroundIt() {
        var navigation = Navigation(page: albums)
        navigation.open(mix)
        navigation.open(albums)
        navigation.open(mix)
        navigation.open(songs)
        navigation.remove(mix, fallback: albums)

        #expect(navigation.back == [Place(page: albums, path: [])])
        #expect(navigation.page == songs)
    }

    @Test func deletingAPlaylistDropsNeighborsEqualToTheCurrentScreen() {
        var moved = false
        var navigation = Navigation(page: songs)
        navigation.open(mix)
        navigation.open(songs)
        navigation.open(mix)
        navigation.open(songs)
        navigation.goBack()
        navigation.goBack()
        navigation.remove(mix, fallback: albums)

        #expect(navigation.page == songs)
        #expect(navigation.back.isEmpty)
        #expect(navigation.forward.isEmpty)
        moved = navigation.goBack()
        #expect(!moved)
        moved = navigation.goForward()
        #expect(!moved)
    }

    @Test func deletingAnotherPlaylistKeepsTheCurrentScreen() {
        var navigation = Navigation(page: albums)
        navigation.open(.playlist("Other"))
        navigation.open(songs)
        navigation.remove(mix, fallback: albums)

        #expect(navigation.page == songs)
        #expect(navigation.back.count == 2)
    }

    @Test func refreshReplacesStaleAlbums() {
        let old = Self.album("one", "Old")
        let new = Self.album("one", "New")
        var navigation = Navigation(page: albums)
        navigation.show([.album(old)])
        navigation.open(songs)
        navigation.goBack()
        navigation.refresh([new])

        guard case .album(let shown) = navigation.path.first else {
            Issue.record("no album")
            return
        }
        #expect(shown.title == "New")
        #expect(navigation.forward == [Place(page: songs, path: [])])
    }

    @Test func refreshCutsPathsAtMissingAlbums() {
        let one = Self.album("one")
        let two = Self.album("two")
        var navigation = Navigation(page: albums)
        navigation.show([.artist("Artist"), .album(one)])
        navigation.open(songs)
        navigation.show([.album(two)])
        navigation.refresh([two])

        #expect(navigation.back == [Place(page: albums, path: []), Place(page: albums, path: [.artist("Artist")]), Place(page: songs, path: [])])
        #expect(navigation.path == [.album(two)])
    }

    @Test func refreshMergesPlacesThatBecomeEqual() {
        let one = Self.album("one")
        let two = Self.album("two")
        var navigation = Navigation(page: albums)
        navigation.show([.album(one)])
        navigation.show([])
        navigation.show([.album(two)])
        navigation.refresh([])

        #expect(navigation.place == Place(page: albums, path: []))
        #expect(navigation.back.isEmpty)
    }

    @Test func refreshKeepsTheFirstOfRepeatedAlbumIDs() {
        let first = Self.album("one", "First")
        var navigation = Navigation(page: albums)
        navigation.show([.album(Self.album("one"))])
        navigation.refresh([first, Self.album("one", "Second")])

        #expect(navigation.path == [.album(first)])
    }

    @Test func keepsThePositionOfEachScreen() {
        let top = Position(offset: 1, selection: ["b"])
        let next = Position(offset: 2)
        let last = Position(selection: ["d"])
        var navigation = Navigation(page: albums)
        navigation.open(songs, leaving: top)
        navigation.show([.artist("Artist")], leaving: next)

        navigation.goBack(leaving: last)
        #expect(navigation.place.position == next)
        navigation.goBack(leaving: next)
        #expect(navigation.place.position == top)
        navigation.goForward(leaving: Position(offset: 3))
        #expect(navigation.place.position == next)
        navigation.goForward()
        #expect(navigation.place.position == last)
        #expect(navigation.back.map(\.position) == [Position(offset: 3), Position()])
    }

    @Test func aNewScreenStartsWithoutPosition() {
        var navigation = Navigation(page: albums)
        navigation.open(songs, leaving: Position(offset: 4))

        #expect(navigation.place.position == Position())
    }

    @Test func positionDoesNotMakeAnotherScreen() {
        var navigation = Navigation(page: albums)
        navigation.open(albums, leaving: Position(offset: 4))

        #expect(navigation.back.isEmpty)
        #expect(Place(page: albums, path: [], position: Position(offset: 4)) == Place(page: albums, path: []))
    }

    @Test func refreshKeepsPositions() {
        let one = Self.album("one")
        var navigation = Navigation(page: albums)
        navigation.show([.album(one)], leaving: Position(offset: 5))
        navigation.refresh([one])

        #expect(navigation.back.first?.position == Position(offset: 5))
    }

    @Test func keepsEachVisitedPageWithItsPath() {
        let one = Self.album("one")
        var navigation = Navigation(page: albums)
        navigation.show([.album(one)])
        navigation.open(songs)
        navigation.open(.liked)

        #expect(navigation.pages == [albums, songs, .liked])
        #expect(navigation.path(of: albums) == [.album(one)])
        #expect(navigation.path(of: songs).isEmpty)
        #expect(navigation.path(of: mix).isEmpty)

        navigation.open(albums)
        #expect(navigation.pages == [albums, songs, .liked])
        #expect(navigation.path(of: albums).isEmpty)
        navigation.goBack()
        #expect(navigation.page == .liked)
        #expect(navigation.path(of: albums).isEmpty)
        navigation.goBack()
        navigation.goBack()
        #expect(navigation.place == Place(page: albums, path: [.album(one)]))
    }

    @Test func playingOnSongsOpensTheAlbum() {
        let one = Self.album("one")
        let two = Self.album("two")
        var navigation = Navigation(page: songs)

        navigation.played(one)
        #expect(navigation.place == Place(page: songs, path: [.album(one)]))

        navigation.played(two)
        #expect(navigation.place == Place(page: songs, path: [.album(two)]))
        navigation.goBack()
        #expect(navigation.place == Place(page: songs, path: [.album(one)]))
        navigation.goBack()
        #expect(navigation.place == Place(page: songs, path: []))
    }

    @Test func playingTheOpenAlbumKeepsTheHistory() {
        let one = Self.album("one")
        var navigation = Navigation(page: songs)
        navigation.played(one)
        navigation.played(one)

        #expect(navigation.back.count == 1)
        #expect(navigation.path == [.album(one)])
    }

    @Test func playingOnLikedOrAPlaylistStaysOnTheList() {
        let one = Self.album("one")
        for page in [Page.liked, mix] {
            var navigation = Navigation(page: page)
            navigation.played(one)

            #expect(navigation.place == Place(page: page, path: []))
            #expect(navigation.back.isEmpty)
        }
    }

    @Test func playingOnLikedAfterVisitingAnAlbumStaysOnLiked() {
        let one = Self.album("one")
        let two = Self.album("two")
        var navigation = Navigation(page: albums)
        navigation.show([.album(one)])
        navigation.open(.liked)

        navigation.played(two)

        #expect(navigation.place == Place(page: .liked, path: []))
        #expect(navigation.path(of: albums) == [.album(one)])
    }

    @Test func anAlbumOrArtistFromAListOpensOnItsSection() {
        let one = Self.album("one")
        for page in [Page.upNext, .liked, mix, .about] {
            var navigation = Navigation(page: page)
            navigation.push(.album(one))
            #expect(navigation.place == Place(page: albums, path: [.album(one)]), "the sidebar must mark the page that shows")
            navigation.push(.artist("Artist"))
            #expect(navigation.place == Place(page: albums, path: [.album(one), .artist("Artist")]))
            navigation.goBack()
            navigation.goBack()
            #expect(navigation.place == Place(page: page, path: []))

            var artist = Navigation(page: page)
            artist.push(.artist("Artist"))
            #expect(artist.place == Place(page: .section(.artists), path: [.artist("Artist")]))
        }
    }

    @Test func searchingFromLikedOrAPlaylistOpensTheSongs() {
        for page in [Page.liked, mix] {
            var navigation = Navigation(page: page)
            navigation.searched(from: "", to: "a")

            #expect(navigation.place == Place(page: songs, path: []))
            navigation.goBack()
            #expect(navigation.page == page)
        }
    }

    @Test func aNewSearchFromAnOpenScreenShowsTheResults() {
        let one = Self.album("one")
        for path in [[Route.album(one)], [.artist("Artist")], [.artist("Artist"), .album(one)]] {
            var navigation = Navigation(page: albums)
            navigation.show(path)

            navigation.searched(from: "", to: "a")
            #expect(navigation.place == Place(page: songs, path: []))
            navigation.goBack()
            #expect(navigation.place == Place(page: albums, path: path))
        }
    }

    @Test func onlyTheSearchOpensAPageThatKeepsTheQuery() {
        let one = Self.album("one")
        var navigation = Navigation(page: .liked)
        navigation.searched(from: "", to: "a")
        #expect(navigation.page == songs)
        #expect(navigation.searching)

        navigation.show([.album(one)])
        #expect(!navigation.searching)

        navigation.searched(from: "", to: "a")
        navigation.open(.liked)
        #expect(!navigation.searching)
        navigation.searched(from: "a", to: "")

        navigation.goBack()
        #expect(navigation.searching, "the old screen had the query a, so going back keeps it")

        navigation.searched(from: "", to: "a")
        navigation.remove(.liked, fallback: albums)
        #expect(!navigation.searching)
        navigation.filter(albums, to: "Artist")
        #expect(navigation.place == Place(page: albums, path: []))
        #expect(navigation.searching)
    }

    @Test func everySearchGoesToTheResults() {
        let one = Self.album("one")
        var navigation = Navigation(page: songs)
        navigation.searched(from: "", to: "black")
        navigation.show([.album(one)])

        navigation.searched(from: "black", to: "wintermoon")
        #expect(navigation.place == Place(page: songs, path: []), "a new query typed over the old one on an open album must show the results")
        navigation.goBack()
        #expect(navigation.place == Place(page: songs, path: [.album(one)]))

        for page in [albums, .section(.artists), .liked, mix] {
            var other = Navigation(page: page)
            other.searched(from: "a", to: "ab")
            #expect(other.place == Place(page: songs, path: []))
        }

        var results = Navigation(page: songs)
        results.searched(from: "a", to: "ab")
        #expect(results.place == Place(page: songs, path: []))
        #expect(results.back.isEmpty)
    }

    @Test func clearingTheSearchStaysOnThePage() {
        let one = Self.album("one")
        var navigation = Navigation(page: albums, path: [.album(one)])
        navigation.searched(from: "a", to: "")
        navigation.searched(from: "a", to: "a")

        #expect(navigation.place == Place(page: albums, path: [.album(one)]))
    }

    @Test func anArtistLinkKeepsItsFilteredAlbums() {
        let one = Self.album("one")
        var navigation = Navigation(page: songs, path: [.album(one)])
        navigation.filter(albums, to: "Artist")
        navigation.searched(from: "", to: "Artist")
        #expect(navigation.place == Place(page: albums, path: []))

        navigation.searched(from: "Artist", to: "Artist x")
        #expect(navigation.place == Place(page: songs, path: []), "a query typed after the link goes to the results")
    }

    @Test func showsTheLyricsOnlyOnSongLists() {
        let one = Self.album("one")

        #expect(!Navigation(page: albums).lyrics)
        #expect(!Navigation(page: .section(.artists)).lyrics)
        #expect(Navigation(page: songs).lyrics)
        #expect(Navigation(page: .liked).lyrics)
        #expect(Navigation(page: mix).lyrics)
        #expect(Navigation(page: albums, path: [.album(one)]).lyrics)
        #expect(!Navigation(page: .section(.artists), path: [.artist("Artist")]).lyrics)
        #expect(Navigation(page: .section(.artists), path: [.artist("Artist"), .album(one)]).lyrics)
        #expect(Navigation(page: songs, path: [.album(one)]).lyrics)
    }

    @Test func deletingAPlaylistClosesItsPage() {
        let one = Self.album("one")
        var navigation = Navigation(page: albums)
        navigation.show([.album(one)])
        navigation.open(mix)
        navigation.remove(mix, fallback: albums)

        #expect(navigation.pages == [albums])
        #expect(navigation.path == [.album(one)])
        #expect(navigation.path(of: mix).isEmpty)
    }

    @Test func deletingTheCurrentPlaylistOpensANewFallbackPage() {
        var navigation = Navigation(page: mix)
        navigation.remove(mix, fallback: albums)

        #expect(navigation.pages == [albums])
        #expect(navigation.place == Place(page: albums, path: []))
    }

    @Test func refreshUpdatesThePathsOfHiddenPages() {
        let old = Self.album("one", "Old")
        let new = Self.album("one", "New")
        var navigation = Navigation(page: albums)
        navigation.show([.album(old)])
        navigation.open(songs)
        navigation.refresh([new])

        #expect(navigation.path(of: albums) == [.album(new)])
        navigation.refresh([])
        #expect(navigation.path(of: albums).isEmpty)
    }

    @Test func pagesRoundTripTheirKeys() {
        for page in [albums, songs, .section(.artists), .liked, mix, .playlist("")] {
            #expect(Page(key: page.key) == page)
        }
        #expect(Page(key: "unknown") == nil)
        #expect(albums.title == "Albums")
        #expect(mix.title == "Mix")
        #expect(Page.liked.title == "Liked Songs")
        #expect(Section.allCases.map(\.symbol) == ["square.stack", "music.microphone", "music.note"])
        #expect(Section.songs.id == .songs)
    }

    @Test func routesRoundTripTheirKeys() {
        let one = Self.album("/Music/one")

        #expect(Route(key: Route.album(one).key, albums: [one]) == .album(one))
        #expect(Route(key: Route.artist("Artist").key, albums: []) == .artist("Artist"))
        #expect(Route(key: "album:missing", albums: [one]) == nil)
        #expect(Route(key: "unknown", albums: [one]) == nil)
    }

    @Test func stepsInList() {
        #expect(Step.down.index(first: nil, last: nil, count: 5, columns: 1) == 0)
        #expect(Step.up.index(first: nil, last: nil, count: 5, columns: 1) == 4)
        #expect(Step.down.index(first: 4, last: 4, count: 5, columns: 1) == 4)
        #expect(Step.up.index(first: 0, last: 0, count: 5, columns: 1) == 0)
        #expect(Step.down.index(first: 1, last: 3, count: 5, columns: 1) == 4)
        #expect(Step.up.index(first: 1, last: 3, count: 5, columns: 1) == 0)
        #expect(Step.left.index(first: 2, last: 2, count: 5, columns: 1) == nil)
        #expect(Step.down.index(first: nil, last: nil, count: 0, columns: 1) == nil)
    }

    @Test func stepsInGrid() {
        #expect(Step.down.index(first: 1, last: 1, count: 10, columns: 4) == 5)
        #expect(Step.down.index(first: 8, last: 8, count: 10, columns: 4) == 9)
        #expect(Step.up.index(first: 5, last: 5, count: 10, columns: 4) == 1)
        #expect(Step.up.index(first: 2, last: 2, count: 10, columns: 4) == 0)
        #expect(Step.left.index(first: 5, last: 5, count: 10, columns: 4) == 4)
        #expect(Step.right.index(first: 9, last: 9, count: 10, columns: 4) == 9)
        #expect(Step.left.index(first: nil, last: nil, count: 10, columns: 4) == 9)
        #expect(Step.right.index(first: nil, last: nil, count: 10, columns: 4) == 0)
        #expect(Step.right.index(first: 2, last: 2, count: 5, columns: 1) == nil)
    }

    @Test func extendsSelection() {
        #expect(Step.extendDown.index(first: 1, last: 2, count: 5, columns: 1) == 3)
        #expect(Step.extendUp.index(first: 1, last: 2, count: 5, columns: 1) == 0)
        #expect(Step.extendUp.index(first: 0, last: 2, count: 5, columns: 1) == nil)
        #expect(Step.extendDown.index(first: 0, last: 4, count: 5, columns: 1) == nil)
        #expect(Step.extendDown.index(first: nil, last: nil, count: 5, columns: 1) == nil)
    }

    @Test func anArtistLinkWithTheSameQueryDoesNotSwallowTheNextSearch() {
        let one = Self.album("one")
        var navigation = Navigation(page: songs, query: "Artist")
        navigation.show([.album(one)])
        navigation.filter(albums, to: "Artist")
        #expect(navigation.place == Place(page: albums, path: []))

        navigation.searched(from: "Artist", to: "Artist x")
        #expect(navigation.place == Place(page: songs, path: []), "the query did not change for the link, so the next change must open the results")
    }

    @Test func clearingAfterAnArtistLinkDoesNotSwallowTheNextSearch() {
        var navigation = Navigation(page: songs)
        navigation.filter(albums, to: "Artist")
        navigation.searched(from: "", to: "Artist")
        navigation.searched(from: "Artist", to: "")
        navigation.searched(from: "", to: "abc")

        #expect(navigation.place == Place(page: songs, path: []))
    }

    @Test func backWithoutHistoryClosesTheScreenAndCanGoForward() {
        let one = Self.album("one")
        var navigation = Navigation(page: albums, path: [.album(one)])
        #expect(navigation.canGoBack, "a restored album can close with Back")

        let went = navigation.goBack()
        let popped = navigation.pop()
        #expect(!went)
        #expect(popped)
        #expect(navigation.place == Place(page: albums, path: []))
        #expect(navigation.back.isEmpty, "closing a restored album must not add it to the back history")
        #expect(!navigation.canGoBack)

        navigation.goForward()
        #expect(navigation.place == Place(page: albums, path: [.album(one)]))
    }

    @Test func theSavedPathGoesOnlyToTheSavedPage() {
        let one = Self.album("one")
        var navigation = Navigation(page: albums)
        navigation.open(songs)
        navigation.restore([.album(one)], on: albums)
        #expect(navigation.place == Place(page: songs, path: []), "the user moved to another page before the library loaded")

        var other = Navigation(page: albums)
        other.open(songs)
        other.goBack()
        other.restore([.album(one)], on: albums)
        #expect(other.path.isEmpty, "a page with history keeps what the user did")
    }

    @Test func aDeletedPlaylistLeavesTheHistory() {
        var navigation = Navigation(page: mix)
        navigation.open(albums)
        navigation.open(.playlist("Other"))
        navigation.prune(["Other"], fallback: albums)

        #expect(navigation.page == .playlist("Other"))
        #expect(!navigation.back.contains { $0.page == mix })

        var gone = Navigation(page: mix)
        gone.prune([], fallback: albums)
        #expect(gone.page == albums, "a playlist file removed while the app was closed must not stay open")
    }

    @Test func aChangedAlbumKeepsItsScreen() {
        let old = Album(id: "one", title: "T", artist: "A", year: 2000, tracks: [])
        let new = Album(id: "one", title: "T", artist: "A", year: 2001, tracks: [])
        #expect(Route.album(old) == Route.album(new), "a scan that changes the songs of an open album must not rebuild its screen")
        #expect(Route.album(old).hashValue == Route.album(new).hashValue)
    }

    @Test func refreshCutsArtistsThatAreGone() {
        var navigation = Navigation(page: albums)
        navigation.show([.artist("Gone")])
        navigation.refresh([Self.album("one")])

        #expect(navigation.path.isEmpty)
    }

    @Test func backRestoresTheQueryOfTheOldScreen() {
        let one = Self.album("one")
        var navigation = Navigation(page: albums)
        navigation.show([.album(one)])
        navigation.filter(albums, to: "Artist")
        navigation.searched(from: "", to: "Artist")
        #expect(navigation.query == "Artist")

        navigation.goBack()
        #expect(navigation.place == Place(page: albums, path: [.album(one)]))
        #expect(navigation.place.query == "", "the album was open without a query")
        #expect(navigation.searching, "the page change must not clear the query before it goes back")

        navigation.searched(from: "Artist", to: "")
        #expect(navigation.place == Place(page: albums, path: [.album(one)]), "putting back the old query does not open the results")

        navigation.goForward()
        #expect(navigation.place.query == "Artist")
        navigation.searched(from: "", to: "Artist")
        #expect(navigation.place == Place(page: albums, path: []))
    }

    @Test func openingTheOpenAlbumAgainAddsNothing() {
        let one = Self.album("one")
        var navigation = Navigation(page: albums)

        let opened = navigation.push(.album(one))
        #expect(opened)
        let again = navigation.push(.album(one))
        #expect(!again, "the second click of a double-click must not stack the same album")
        #expect(navigation.path == [.album(one)])
        #expect(navigation.back == [Place(page: albums, path: [])], "one Back closes the album")

        let artist = navigation.push(.artist("Artist"))
        let twice = navigation.push(.artist("Artist"))
        #expect(artist && !twice)
        #expect(navigation.path == [.album(one), .artist("Artist")])
    }

    @Test func backAfterAnArtistLinkWithTheSameQueryKeepsTheSearch() {
        let one = Self.album("one")
        var navigation = Navigation(page: albums)
        navigation.searched(from: "", to: "Artist")
        navigation.show([.album(one)])
        navigation.filter(albums, to: "Artist")
        #expect(navigation.page == albums)

        navigation.goBack()
        #expect(navigation.place == Place(page: songs, path: [.album(one)]))
        #expect(navigation.searching, "the page changes back to Songs with the same query; it must not clear it")

        navigation.goForward()
        #expect(navigation.searching)
    }
}
