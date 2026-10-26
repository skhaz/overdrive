import Foundation
import Testing

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

    @Test func theSongsTableIsRebuiltWhenTheQueryChanges() throws {
        let source = try source()

        #expect(source.contains("SongTable(tracks: library.tracks).id(\"\\(library.query)\\u{1F}\\(library.members)\\u{1F}\\(library.edits)\")"), "a SwiftUI Table that diffs from a few rows to the whole library hangs the main thread, also after a scan that adds or removes songs")
        #expect(!source.contains(".id(library.version)"), "a scan must not rebuild the screens")
    }

    @Test func onlyAnEditableTextKeepsTheTypedKeys() throws {
        #expect(!(try source().contains("firstResponder is NSText")), "the selectable lyrics are an NSText; use Focus.typing")
    }

    @Test func theSearchResultsShowTheMatchedAlbums() throws {
        let source = try source()
        let strip = region(source, from: "struct AlbumStrip: View {")

        #expect(source.contains("AlbumStrip(albums: library.filtered)"), "the results must show the albums above the songs")
        #expect(strip.contains("player.play(album)\n                                go(.playing(album.tracks[0]))"), "playing an album from the results must open it on the playing song")
        #expect(strip.contains(".onTapGesture { go(.album(album)) }"), "a click on an album must open it")
        #expect(!strip.contains(".overlay"), "a button over another button loses the click")
        #expect(strip.contains(".fixedSize(horizontal: false, vertical: true)"), "the albums row must take only its own height, not half of the page")
    }

    @Test func anotherPageClearsTheSearch() throws {
        #expect(try source().contains("""
                .onChange(of: navigation.page) {
                    guard !navigation.searching else { return }

                    search = ""
                    library.query = ""
                }
        """), "a page change must clear the search, except the page the search opens")
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

    @Test func theQueueEditsThePlayerQueue() throws {
        let source = try source()
        let queue = region(source, from: "struct QueueView: View {")

        #expect(source.contains("row(\"Queue\", \"list.bullet\", .queue)"))
        #expect(queue.contains("player.move(Set(ids.compactMap { Int($0) }).subtracting([player.index]), to: player.index + max(index, 1))"), "a drag must reorder only the songs after the one that plays")
        #expect(queue.contains("player.queue.indices.dropFirst(player.index)"), "the queue shows the song that plays and the songs that follow, not the played ones")
        #expect(queue.contains("delete: { remove(selection) }"), "Delete must remove the selected songs")
    }

    @Test func theLyricsButtonHidesTheLyrics() throws {
        let source = try source()

        #expect(source.contains("{ player.lyrics.toggle() }"), "the toolbar must show and hide the lyrics")
        #expect(source.contains("player.lyrics && (player.current != nil || lyrics.selected)"), "hidden lyrics never show")
        #expect(source.contains("lyrics.enabled = player.lyrics"), "hidden lyrics stop all work")
    }

    @Test func clearingTheQueueAsksFirst() throws {
        let source = try source()
        let queue = region(source, from: "struct QueueView: View {")

        #expect(source.contains("Button(\"Clear Queue\", systemImage: \"trash\") { clearing = true }"), "the Queue page must show a clear button that asks first")
        #expect(source.contains("Button(\"Clear Queue\", role: .destructive, action: player.clear)"), "only the confirmation clears the queue")
        #expect(!queue.contains("player.clear"), "the Queue page never clears without the confirmation")
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

    @Test func emptyListsClearTheSelectedSong() throws {
        let source = try source()

        #expect(source.components(separatedBy: ".modifier(Selected(tracks: []").count - 1 == 3, "an empty queue, playlist, or Liked Songs shows the lyrics of the song that plays")
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

    @Test func theLyricsFollowTheSelectedSong() throws {
        let selected = region(try source(), from: "struct Selected")

        #expect(selected.contains("let picked = album == nil && tracks.count == 1 ? tracks[0] : nil"), "one selected song shows its lyrics")
        #expect(selected.contains("if let track = picked ?? player.current { lyrics.show(track) }"), "without one selected song the lyrics show the current song")
        #expect(selected.contains("lyrics.selected = picked != nil"), "the top screen tells if one song is selected")
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
