import AppKit
import Foundation
import Testing
@testable import Overdrive

struct ViewStructureTests {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try String(contentsOf: root.appending(path: "Sources/Overdrive/Views.swift"), encoding: .utf8)
    }

    private func region(_ source: String, from marker: String) -> String {
        guard let start = source.range(of: marker) else { return "" }

        let rest = source[start.upperBound...]
        let end = rest.range(of: "\nstruct ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test func theSpectrumDrawsOverTheContentWithNoAreaOfItsOwn() throws {
        let source = try source()
        let bar = region(source, from: "struct SpectrumBar: View {")

        #expect(source.contains(".overlay(alignment: .bottom) {\n                if player.showsSpectrum { SpectrumBar().allowsHitTesting(false) }\n            }"), "the spectrum must draw over the bottom of the content, full width, and never take a click")
        #expect(source.contains("            Divider()\n            Controls(open: reveal)\n                .background(.bar)"), "the bottom bar must hold only the controls")
        #expect(!bar.contains(".padding("), "the spectrum must take the full width")
    }

    @Test func theSpectrumFadesOutWhenThePlayerStops() throws {
        let source = try source()
        let bar = region(source, from: "struct SpectrumBar: View {")

        #expect(bar.contains(".opacity(player.playing ? 1 : 0)"), "with nothing playing the spectrum must fade out instead of vanishing at once")
        #expect(bar.contains(".animation(.easeOut(duration: 0.4), value: player.playing)"), "the disappearance must be smooth, not abrupt")
    }

    @Test func theSongsTableIsRebuiltWhenTheQueryChanges() throws {
        let source = try source()

        #expect(source.contains("SongTable(tracks: library.tracks).id(\"\\(library.query)\\u{1F}\\(library.members)\\u{1F}\\(library.edits)\")"), "a SwiftUI Table that diffs from a few rows to the whole library hangs the main thread, also after a scan that adds or removes songs")
        #expect(!source.contains(".id(library.version)"), "a scan must not rebuild the screens")
    }

    @Test func theLyricsSaveWhenTheAppLosesTheFocusOrTheWindowCloses() throws {
        let source = try source()

        #expect(source.contains("NSApplication.didResignActiveNotification)) { _ in\n            Log.lyrics.debug(\"flush\", metadata: [\"reason\": \"resign active\"])\n            lyrics.flush()"))
        #expect(source.contains("            monitor = nil\n            lyrics.flush()\n        }"), "closing the window then quitting at once lost the last edit")
    }

    @Test func theLyricsHaveNoSaveButton() throws {
        let panel = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/LyricsPanel.swift"), encoding: .utf8)
        for text in [try source(), panel] {
            #expect(!text.contains("square.and.arrow.down"), "edits save by themselves; the save button was removed")
        }
    }

    @Test func onlyAnEditableTextKeepsTheTypedKeys() throws {
        #expect(!(try source().contains("firstResponder is NSText")), "the selectable lyrics are an NSText; use Focus.typing")
    }

    @Test func theSearchResultsShowTheMatchedAlbums() throws {
        let source = try source()
        let strip = region(source, from: "struct AlbumStrip: View {")

        #expect(source.contains("AlbumStrip(albums: library.filtered)"), "the results must show the albums above the songs")
        #expect(source.contains("AlbumStrip(albums: library.filtered).id(\"\\(library.query)"), "each query must build the strip again from its first album, or a strip kept across queries can show an older list above songs that already changed")
        #expect(strip.contains("player.play(album)\n                                go(.playing(album.tracks[0]))"), "playing an album from the results must open it on the playing song")
        #expect(strip.contains(".onTapGesture { go(.album(album)) }"), "a click on an album must open it")
        #expect(!strip.contains(".overlay"), "a button over another button loses the click")
        #expect(strip.contains(".fixedSize(horizontal: false, vertical: true)"), "the albums row must take only its own height, not half of the page")
    }

    @Test func theAlbumHeaderHasNoPlayButtonsAndSitsOnTheCoverBottom() throws {
        let album = region(try source(), from: "struct AlbumView: View {")
        let header = String(album[..<(try #require(album.range(of: "LazyVStack")).lowerBound)])

        #expect(header.contains("HStack(alignment: .bottom, spacing: 20)"), "the album text must align with the bottom of the cover")
        #expect(!header.contains("Button(\"Play\""), "the play controls below already play the album")
        #expect(!header.contains("Button(\"Shuffle\""), "the play controls below already shuffle")
    }

    @Test func anotherPageClearsTheSearch() throws {
        let text = try source()
        let start = try #require(text.range(of: "private struct QueryFocus: ViewModifier {"))
        let rest = text[start.lowerBound...]
        let focus = String(rest[..<(try #require(rest.range(of: "\n}\n")).lowerBound)])

        #expect(focus.contains("""
                    .onChange(of: navigation.page) {
                        guard !navigation.searching else { return }

                        search = ""
                        library.query = ""
                    }
        """), "a page change must clear the search, except the page the search opens")
        #expect(text.contains(".modifier(QueryFocus(navigation: $navigation, lyrics: lyrics, tracker: tracker, placed: placed, remember: remember, search: $search))"), "the window installs the search rules")
        #expect(try source().contains("navigation.filter(.section(.albums), to: text, leaving: tracker.position)"), "a click on an artist name must keep its search")
    }

    @Test func typedKeysGoToTheSearchWhileItHasText() throws {
        let source = try source()

        #expect(source.contains("Focus.types(character, into: search)"), "a space after a letter must go to the search, not pause the song")
        #expect(source.contains("let typing = !search.isEmpty"), "Space, Delete, and the arrows act only when the search field has no text")
        #expect(source.contains("window.makeFirstResponder(field)"), "the search field must take the focus for real")
    }

    @Test func commandASelectsAllSongsFromAnyFocus() throws {
        let source = try source()
        let press = source.components(separatedBy: "    private func press(_ event: NSEvent) -> Bool {").last ?? ""
        let guardLine = "guard sidebar || focus == .search || !Focus.typing(window.firstResponder) else { return false }"
        let rule = "if flags == .command, event.keyCode == 0 {\n            NotificationCenter.default.post(name: .key, object: Key.all)"

        #expect(press.contains(rule), "Command-A selects every song of the top screen also from the search field and the sidebar")
        #expect(press.range(of: guardLine).map { $0.lowerBound < press.range(of: rule)!.lowerBound } == true, "only the lyrics editor keeps Command-A for its own text")
    }

    @Test func theUpNextPageEditsThePlayerQueue() throws {
        let source = try source()
        let list = region(source, from: "struct UpNextView: View {")

        #expect(source.contains("row(\"Up Next\", \"list.bullet\", .upNext)"))
        #expect(list.contains("player.move(Set(ids.compactMap { Int($0) }).subtracting([player.index]), to: max(player.head + index, player.index + 1))"), "a drag reorders the list it shows, and never moves a song ahead of the one that plays")
        #expect(list.contains("player.queue.indices.dropFirst(player.head)"), "Up Next shows the head and the songs after it, so a song the user clicked past keeps its place")
        #expect(list.contains("delete: { remove(selection) }"), "Delete must remove the selected songs")
    }

    /// An `.environment(x)` applied in the body of a view does NOT reach the
    /// modifiers applied in that same body: they sit outside it. A helper that
    /// reads such an object traps on the first render, with no compiler error and
    /// no test failing until the window opens. This is the check for that.
    @Test func noHelperOfTheWindowReadsWhatTheWindowOwns() throws {
        let text = try source()
        let body = region(text, from: "struct ContentView: View {")

        // the objects the window owns as its own state and injects in its body
        let owned = Set(["lyrics", "navigation", "tracker", "search", "memo", "panel", "saved", "swipe", "navigator", "name", "deleting", "clearing", "monitor", "focus"])
        var injected: Set<String> = []

        for match in body.matches(of: /\.environment\(([^)\s]+)\)/) {
            injected.insert(String(match.output.1))
        }

        #expect(injected.contains("lyrics"), "the window injects its own lyrics object in its body")

        let helpers = Set(body.matches(of: /\.modifier\(([A-Z][A-Za-z]*)\(/).map { String($0.output.1) })
        #expect(!helpers.isEmpty, "the window installs helpers of its own")

        for helper in helpers.sorted() {
            let start = try #require(text.range(of: "struct \(helper): "))
            let rest = text[start.lowerBound...]
            let decl = String(rest[..<(try #require(rest.range(of: "\n}\n")).lowerBound)])

            for match in decl.matches(of: /@Environment\(([A-Z][A-Za-z]*)\.self\)/) {
                let type = String(match.output.1)
                let name = type.prefix(1).lowercased() + type.dropFirst()
                #expect(!injected.contains(lower(name)) || !owned.contains(name),
                        "\(helper) reads \(type) from the environment, but the window injects it in its own body: pass it in instead")
            }
        }

        #expect(body.contains("QueryFocus(navigation: $navigation, lyrics: lyrics, tracker: tracker"),
                "the search helper receives the lyrics and the tracker of the window by hand")
        let focus = region(text, from: "private struct QueryFocus: ViewModifier {")

        #expect(!focus.contains("@Environment(Lyrics.self)"), "and never from the environment of the window itself")
        #expect(focus.contains("let lyrics: Lyrics"), "the helper holds what it is given")
    }

    private func lower(_ text: String) -> String { text }

    /// A symbol that this macOS does not know renders as nothing, with no log
    /// and no error: the row just looks empty. So every name the app draws is
    /// asked of the system, before it is ever seen.
    @Test @MainActor func everySymbolNameShowsOnThisMac() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var names: Set<String> = []
        let rows = try Regex(#"row\("[^"]*", "([^"]+)""#)
        let systems = try Regex(#"system(?:Image|Name): "([^"]+)""#)

        for file in ["Views.swift", "LyricsPanel.swift", "Overdrive.swift"] {
            let text = try String(contentsOf: root.appending(path: "Sources/Overdrive/\(file)"), encoding: .utf8)
            for match in text.matches(of: rows) { if let symbol = match.output[1].substring { names.insert(String(symbol)) } }
            for match in text.matches(of: systems) { if let symbol = match.output[1].substring { names.insert(String(symbol)) } }
        }

        for section in Section.allCases { names.insert(section.symbol) }

        #expect(names.count > 15, "the scan finds the symbols of the app, got \(names.count)")
        for name in names.sorted() {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is not a symbol of this macOS")
        }
    }

    @Test func theAddictedListOpensAlwaysCurrent() throws {
        let source = try source()
        let list = region(source, from: "struct AddictedView: View {")

        #expect(source.contains("row(\"Addicted\", \"flame.fill\", .addicted)"), "the sidebar carries the flame row")
        #expect(source.contains("case .addicted: AddictedView()"), "the row opens its own page")
        #expect(list.contains("let paths = library.addicted(Library.topPlayed)"), "every pass reads the counts again, so the list a click opens is the order of that moment")
        #expect(list.contains(".onChange(of: paths) { selection = [] }"), "a reshuffle does not leave the selection on another song")
        #expect(!list.contains("go(.playing"), "a double-click plays the row and opens no album")
        #expect(source.contains("case .liked, .addicted, .banned, .playlist, .upNext:"), "at launch the page opens on its list, like Liked Songs")
    }

    @Test func theLyricsPanelHasTwoTabsOnlyWithAnAccount() throws {
        let source = try source()
        let panel = region(source, from: "struct LyricsView: View {")
        let row = region(source, from: "private struct SimilarArtistRow: View {")

        #expect(panel.contains("let tabs = !lastFM.user.isEmpty"), "the tabs only exist while a Last.fm account is connected")
        #expect(panel.contains("Button { similar.select(value) }"), "the tabs are buttons of the panel")
        #expect(panel.contains("PressableButtonStyle(isProminent: similar.tab == value)"), "the chosen tab takes the accent pill and answers the press")
        #expect(!panel.contains("Picker("), "the native segmented picker did not feel alive inside the panel")
        #expect(panel.contains("if showing {\n                    SimilarArtists()"), "the similar tab lists the artists natively, with no web view")
        #expect(source.contains("similar.show(lyrics.track)"), "the panel follows the song it shows")
        #expect(row.contains("onTapGesture { similar.open(artist) }"), "a click opens the artist page")
        #expect(row.contains("Button(\"Copy Name\") { similar.copyName(artist) }"), "the right button copies the name")
        #expect(!panel.contains("WKWebView") && !row.contains("WKWebView"), "the list is never a web view")
    }

    @Test func theLyricsButtonHidesTheLyrics() throws {
        let source = try source()

        #expect(source.contains("{ player.lyrics.toggle() }"), "the toolbar must show and hide the lyrics")
        #expect(source.contains("player.lyrics && (player.current != nil || lyrics.selected)"), "hidden lyrics never show")
        #expect(source.contains("lyrics.enabled = player.lyrics"), "hidden lyrics stop all work")
    }

    @Test func clearingUpNextAsksFirst() throws {
        let source = try source()
        let list = region(source, from: "struct UpNextView: View {")

        #expect(source.contains("Button(\"Clear Up Next\", systemImage: \"trash\") { clearing = true }"), "the Up Next page must show a clear button that asks first")
        #expect(source.contains("Button(\"Clear Up Next\", role: .destructive, action: player.clear)"), "only the confirmation clears the list")
        #expect(!list.contains("player.clear"), "the Up Next page never clears without the confirmation")
    }

    @Test func theFindShortcutFocusesTheSearchWithItsTextSelected() throws {
        let source = try source()

        #expect(source.contains(".modifier(Find { window in focusSearch(window, selecting: true) })"), "the global shortcut must put the cursor in the search")
        #expect(source.contains("if selecting { (window.firstResponder as? NSTextView)?.selectAll(nil) }"), "the old query must be selected so typing replaces it")
        #expect(!source.contains("event.keyCode == 3 {"), "the global shortcut is the only shortcut to the search")
    }

    @Test func thePushedScreenKeepsARouteIdentity() throws {
        #expect(try source().contains(".id(\"\\(route.key)\\u{1F}\\(library.edits)\")"), "each pushed route must build a fresh screen, and again after a tag edit")
    }

    @Test func onlyTheSongsListOpensAnAlbumOnPlay() throws {
        let source = try source()

        #expect(region(source, from: "struct SongTable").contains("go(.playing"), "the songs list (and the search results) open the album of the played song")
        #expect(!region(source, from: "struct PlaylistView").contains("go(.playing"), "a playlist only plays the row")
        #expect(!region(source, from: "struct LikedView").contains("go(.playing"), "the liked songs only play the row")
    }

    @Test func noPageUsesASwiftUINavigationStack() throws {
        let source = try source()

        #expect(!source.contains("NavigationStack"), "a NavigationSplitView detail links only one stack, so a push on one page goes to another page")
        #expect(!source.contains("NavigationLink"), "a NavigationLink pushes into the stack SwiftUI picks, not the stack of its page")
        #expect(!source.contains("navigationDestination"), "each page draws its own pushed screens")
    }

    @Test func onlyTheTopScreenIsActive() throws {
        let source = try source()

        #expect(source.contains("let top = current && index == path.count - 1"), "only the last pushed screen of the current page reacts to keys")
        #expect(source.contains("screen(current && path.isEmpty"), "the root reacts only when nothing is pushed")
    }

    @Test func theAlbumOnlyPlaysTheRow() throws {
        #expect(!region(try source(), from: "struct AlbumView").contains("go(.playing"), "playing a song in an open album stays on that album")
    }

    @Test func theArrowsMoveTheSidebarWhenItHasTheFocus() throws {
        #expect(try source().contains("case (123...126, true): return false"), "the sidebar keeps its own arrow keys")
    }

    @Test func escapeFollowsItsOrderFromAnyFocus() throws {
        let source = try source()
        let escape = region(source, from: "private func escape(")

        #expect(source.contains("if event.keyCode == 53, event.modifierFlags.isDisjoint(with: [.command, .option, .control]) { return escape(window, sidebar: sidebar) }\n        guard sidebar || focus == .search || !Focus.typing(window.firstResponder)"), "Escape runs before the editable text guard, so it closes the video and goes back also from the lyrics editor")
        let order = ["youTube.close()", "goBack()", "focus = .search", "library.query = \"\""].compactMap { escape.range(of: $0)?.lowerBound }
        #expect(order.count == 4 && order == order.sorted(), "close the video, go back, leave the lyrics editor, clear the search")
    }

    @Test func hiddenScreensDoNotReact() throws {
        let source = try source()

        #expect(source.contains(".onDeleteCommand { if active { remove(selection) } }"), "Delete must not remove songs from a hidden queue")
        #expect(source.contains("if active { removing = rows.filter { selection.contains($0.id) } }"))
        #expect(source.contains("guard active, let point = notification.object as? CGPoint, list.rect.contains(point)"), "a right-click must not change a hidden album")
        #expect(source.contains("reachable(table, in: content)"), "Control-Return opens the menu of the table that shows")
    }

    @Test func onlyTheListThatShowsTakesADrop() throws {
        let source = try source()
        let queue = region(source, from: "struct UpNextView: View {")
        let playlist = region(source, from: "struct PlaylistView: View {")

        for body in [queue, playlist] {
            let rows = body.components(separatedBy: "} rows: {").last ?? ""
            #expect(rows.contains("if active {\n") && rows.contains("} else {\n") && rows.contains("ForEach(rows) { TableRow($0) }"), "a hidden table is still an AppKit drag destination: a drag on a playlist moved the songs of the hidden Up Next")
            #expect(source.components(separatedBy: ".dropDestination(for: String.self)").count == 3, "every row drop is behind its list's active flag")
        }
    }

    @Test func thePlaylistMenuPlaysAndOpensThePlaylist() throws {
        let source = try source()
        let play = region(source, from: "    private func play(_ name: String) {")

        #expect(source.contains(".contextMenu {\n                                        Button(\"Play\") { play(name) }"), "the sidebar menu of a playlist plays it")
        #expect(source.contains("Button(\"Delete Playlist\", role: .destructive) { deleting = name }"), "deleting still asks first")
        #expect(play.contains("library.tracks(at: playlists.paths[name] ?? [])"), "the whole playlist plays, not the search results")
        #expect(play.contains("player.play(tracks)"))
        #expect(play.contains("navigation.open(.playlist(name)"), "and the playlist page opens")
    }

    @Test func emptyListsClearTheSelectedSong() throws {
        let source = try source()

        #expect(source.components(separatedBy: ".modifier(Selected(tracks: []").count - 1 == 5, "an empty queue, playlist, liked songs, addicted, or never-picked list shows the lyrics of the song that plays")
    }

    @Test func aDoubleClickAndEnterDoTheSame() throws {
        let source = try source()

        #expect(!source.contains("ids.first"), "a Set has no order: play the first selected row as shown")
        #expect(source.components(separatedBy: "player.start(").count - 1 >= 6, "a double-click and Enter both start the row")
    }

    @Test func typingKeepsTheFirstCharacter() throws {
        #expect(try source().contains("moveToEndOfDocument"), "the search field selects its text when it takes the focus, so the next key would replace the first one")
    }

    @Test func theLyricsLoadForEverySongAndShowOnlyWithASong() throws {
        let source = try source()

        #expect(source.contains("if let current = player.current { lyrics.show(current) }"), "every new current song starts its lyrics lookup")
        #expect(source.contains("(player.current != nil || lyrics.selected) && lyrics.track != nil && navigation.lyrics"), "the docked lyrics need a current or a selected song, and a song list")
    }

    @Test func theLyricsFollowThePlayingSong() throws {
        let selected = region(try source(), from: "struct Selected")

        #expect(selected.contains("let picked = album == nil && tracks.count == 1 ? tracks[0] : nil"), "one selected song is picked")
        #expect(selected.contains("if let track = player.current ?? picked { lyrics.show(track) }"), "the song that plays keeps the lyrics, whatever the selection is; a selected song shows only while nothing plays")
        #expect(selected.contains("lyrics.selected = picked != nil"), "the top screen tells if one song is selected")
    }

    @Test func theDisabledSpectrumConsumesNothing() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let player = try String(contentsOf: root.appending(path: "Sources/Overdrive/Player.swift"), encoding: .utf8)

        #expect(try source().contains("if player.showsSpectrum { SpectrumBar().allowsHitTesting(false) }"), "a disabled spectrum draws no view, so no timeline and no FFT")
        #expect(player.contains("parameters.audioTapProcessor = showsSpectrum ? spectrum.tap() : nil"), "a disabled spectrum installs no tap on the audio thread")
        #expect(player.contains("guard normalize || showsSpectrum else {\n            item.audioMix = nil"), "a song with no gain and no spectrum keeps no mix, so the old tap leaves with it")
        #expect(player.contains("spectrum.listening = false\n            spectrum.clear()"), "turning the spectrum off stops the samples and empties the ring")
        #expect(player.contains("spectrum.listening = showsSpectrum"), "the spectrum starts in the saved state")
    }

    @Test func theSpectrumSettingIsInThePreferences() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let player = try String(contentsOf: root.appending(path: "Sources/Overdrive/Player.swift"), encoding: .utf8)
        let source = try source()
        let settings = region(source, from: "struct SettingsView: View {")

        #expect(settings.contains("@Environment(Player.self) private var player"))
        #expect(settings.contains("Toggle(\"Show Spectrum\", isOn: $player.showsSpectrum)"), "Settings offers the spectrum switch")
        let app = try String(contentsOf: root.appending(path: "Sources/Overdrive/Overdrive.swift"), encoding: .utf8)
        #expect(app.contains("SettingsView()\n                .environment(library)\n                .environment(player)"), "the settings window gets the player")
        #expect(player.contains(#"Spectrum.enabled(UserDefaults.standard.object(forKey: "spectrum"))"#), "the switch reads the saved state at launch")
        #expect(player.contains(#"UserDefaults.standard.set(showsSpectrum, forKey: "spectrum")"#), "every change of the switch is persisted")
    }

    @Test func theFloatingLyricsBringTheAppBack() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let panel = try String(contentsOf: root.appending(path: "Sources/Overdrive/LyricsPanel.swift"), encoding: .utf8)

        #expect(panel.contains("Button(\"Show Overdrive\", systemImage: \"macwindow\", action: open)"), "the panel has a button that shows the main window")
        #expect(panel.contains(".onTapGesture(count: 2, perform: open)"), "a double-click on the song shows the main window")
        #expect(panel.contains("lyrics.floating = false\n            NSApp.activate()"), "going back to the app docks the lyrics in the main window")
        #expect(panel.contains("NSApp.activate()"), "the panel does not activate the app by itself")
        #expect(panel.contains(".nonactivatingPanel"), "a click on the panel must not take the focus")
        #expect(try source().contains("LyricsPanel(lyrics: lyrics, player: player) { openWindow(id: \"main\") }"), "the main window opens again when it was closed")
    }
}
