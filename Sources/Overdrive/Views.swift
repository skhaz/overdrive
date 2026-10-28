import SwiftUI
import UniformTypeIdentifiers


enum Focus {
    case search, sidebar

    static func typing(_ responder: NSResponder?) -> Bool {
        (responder as? NSText)?.isEditable == true
    }

    static func types(_ character: Character, into query: String) -> Bool {
        character.isLetter || character.isNumber || (!query.isEmpty && (character == " " || character.isPunctuation || character.isSymbol))
    }

    static func field(in window: NSWindow) -> NSSearchField? {
        if let field = window.toolbar?.items.lazy.compactMap({ ($0 as? NSSearchToolbarItem)?.searchField }).first { return field }

        var views = [window.contentView?.superview].compactMap(\.self)
        while let view = views.popLast() {
            if let field = view as? NSSearchField { return field }
            views += view.subviews
        }
        return nil
    }
}

enum Destination {
    case album(Album)
    case artist(String)
    case search(String)
    case playing(Track)

    var key: String {
        switch self {
        case .album(let album): "album:" + album.id
        case .artist(let name): "artist:" + name
        case .search(let text): "search:" + text
        case .playing(let track): "playing:" + track.url.path
        }
    }
}

struct GoAction: Equatable {
    let action: (Destination) -> Void

    func callAsFunction(_ destination: Destination) {
        action(destination)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        true
    }
}

extension EnvironmentValues {
    @Entry var go = GoAction { _ in }
}

struct Selection {
    let tracks: [Track]
    let album: Album?
    let playlist: String?
    let remove: (() -> Void)?
    let go: GoAction
}

extension FocusedValues {
    @Entry var selection: Selection?
}

struct Selected: ViewModifier {
    static let delay = Duration.milliseconds(150)

    let tracks: [Track]
    var album: Album?
    var playlist: String?
    var remove: (() -> Void)?
    @Environment(\.active) private var active
    @Environment(\.go) private var go
    @Environment(Lyrics.self) private var lyrics
    @Environment(Player.self) private var player

    func body(content: Content) -> some View {
        let picked = album == nil && tracks.count == 1 ? tracks[0] : nil

        content.focusedSceneValue(\.selection, active && !tracks.isEmpty ? Selection(tracks: tracks, album: album, playlist: playlist, remove: remove, go: go) : nil)
            .task(id: picked) {
                guard (try? await Task.sleep(for: Selected.delay)) != nil else { return }

                follow(picked)
            }
            .onChange(of: active, initial: true) { follow(picked) }
    }

    private func follow(_ picked: Track?) {
        guard active else { return }

        lyrics.selected = picked != nil
        if let track = player.current ?? picked { lyrics.show(track) }
    }
}

// MARK: - Button Styles

struct PressableButtonStyle: ButtonStyle {
    var isProminent = false
    var isDestructive = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : (isProminent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Group {
                    if isProminent {
                        Color.accentColor
                    } else if isDestructive {
                        Color.red.opacity(configuration.isPressed ? 0.3 : 0.15)
                    } else {
                        Color(nsColor: .controlBackgroundColor)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .shadow(color: .black.opacity(configuration.isPressed ? 0.05 : 0.1), radius: configuration.isPressed ? 1 : 2, x: 0, y: configuration.isPressed ? 1 : 2)
    }
}

struct IconButtonStyle: ButtonStyle {
    var isActive = false
    var isDestructive = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isDestructive ? AnyShapeStyle(.red) : (isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)))
            .frame(width: 28, height: 28)
            .background(
                Circle()
                    .fill(configuration.isPressed ? Color.primary.opacity(0.15) : (isActive ? Color.accentColor.opacity(0.12) : Color.clear))
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.7), value: configuration.isPressed)
            .contentTransition(.symbolEffect(.replace))
    }
}

struct ToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.1) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct SidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.12) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.15, dampingFraction: 0.8), value: configuration.isPressed)
    }
}


struct SongMenu: View {
    @FocusedValue(\.selection) private var selection

    var body: some View {
        if let selection {
            Group {
                TrackMenu(tracks: selection.tracks, exclude: selection.playlist)

                if let remove = selection.remove {
                    Button("Remove from Playlist", action: remove)
                        .keyboardShortcut(.delete)
                    Divider()
                }

                if selection.tracks.count == 1 {
                    GoMenu(track: selection.tracks[0])
                }

                CopyMenu(tracks: selection.tracks, album: selection.album)
                FileMenu(urls: selection.tracks.map(\.url))
            }
            .environment(\.go, selection.go)
        } else {
            Button("No Song Selected") {}
                .disabled(true)
        }
    }
}

struct DiscoveryMenu: View {
    @Environment(Library.self) private var library
    @Environment(Discovery.self) private var discovery
    @Environment(Infinity.self) private var infinity

    var body: some View {
        Menu("Songs (\(library.total))") { values(library.total) { discovery.pick(.songs, $0) } }
            .disabled(library.total < Library.randomCounts[0])

        Menu("Never Played (\(library.neverPlayed))") { values(library.neverPlayed) { discovery.pick(.unplayed, $0) } }
            .disabled(library.neverPlayed < Library.randomCounts[0])

        Menu("Most Played (\(library.played))") { values(library.played) { discovery.pick(.played, $0) } }
            .disabled(library.played < Library.randomCounts[0])

        Divider()

        Menu("Last.fm Artists") { values(nil) { discovery.pick(.artists, $0) } }
            .disabled(!discovery.ready || discovery.work.running)

        Menu("Top Bands (\(library.bands))") { values(nil) { discovery.pick(.bands, $0) } }
            .disabled(!discovery.ready || discovery.work.running || library.bands == 0)

        Divider()

        Toggle("Infinity", systemImage: "infinity", isOn: Binding { infinity.on } set: { _ in infinity.toggle() })
            .disabled(!discovery.ready)
    }

    @ViewBuilder private func values(_ pool: Int?, _ action: @escaping @MainActor (Int) -> Void) -> some View {
        ForEach(Library.randomCounts, id: \.self) { number in
            Button("\(number) Song\(number == 1 ? "" : "s")") { action(number) }
                .disabled(pool.map { $0 < number } ?? false)
        }
    }
}

func count(_ number: Int, _ noun: String) -> String {
    "\(number) \(noun)\(number == 1 ? "" : "s")"
}

/// The rows a context menu acts on. A right-click inside the selection means the
/// whole selection; outside it, only the clicked row. SwiftUI hands the menu the
/// rows it has drawn, so a Select All arrives as the visible rows alone: the
/// selection itself is what the menu must read.
nonisolated func targets(_ ids: Set<Int>, _ selection: Set<Int>) -> Set<Int> {
    ids.isEmpty || !ids.isSubset(of: selection) ? ids : selection
}

func summary(_ tracks: some Collection<Track>) -> String {
    count(tracks.count, "song") + " · " + tracks.reduce(0) { $0 + $1.duration }.time
}

func summary(_ albums: [Album]) -> String {
    let (songs, seconds) = albums.reduce((0, 0.0)) { total, album in album.tracks.reduce((total.0 + album.tracks.count, total.1)) { ($0.0, $0.1 + $1.duration) } }
    return count(songs, "song") + " · " + seconds.time
}

extension Double {
    var time: String {
        guard isFinite, self > 0 else { return "0:00" }

        return Duration.seconds(self).formatted(.time(pattern: self >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

struct TrackMenu: View {
    let tracks: [Track]
    var exclude: String?
    @Environment(Player.self) private var player
    @Environment(Playlists.self) private var playlists
    @Environment(Likes.self) private var likes
    @Environment(Bans.self) private var bans
    @Environment(YouTube.self) private var youTube

    var body: some View {
        if !tracks.isEmpty {
            Button("Add to Up Next") { player.insert(tracks) }
                .keyboardShortcut(.return, modifiers: .command)

            let liked = tracks.allSatisfy(likes.contains)
            Button((liked ? "Unlike " : "Like ") + (tracks.count == 1 ? "Song" : "Songs"), systemImage: liked ? "heart.slash" : "heart") { likes.toggle(tracks) }
                .keyboardShortcut("l", modifiers: [.command, .shift])

            BanMenu(tracks: tracks)

            if tracks.count == 1 {
                Button("Watch Video on YouTube") { youTube.watch(tracks[0]) }
                    .keyboardShortcut("y", modifiers: [.command, .shift])
                    .disabled(youTube.searching)
            }

            Menu("Add to Playlist") {
                let names = playlists.names.filter { $0 != exclude }

                ForEach(names, id: \.self) { name in
                    Button(name) { playlists.add(tracks.map(\.url), to: name) }
                }

                if !names.isEmpty { Divider() }

                Button("New Playlist…") { playlists.naming = tracks.map(\.url) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            Divider()
        }
    }
}

struct FileMenu: View {
    static let mp3tag = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.mp3tag.Mp3tag")

    let urls: [URL]

    var body: some View {
        if urls.count == 1 {
            Menu("Information") {
                ForEach(FileInfo.lines(urls[0]), id: \.self) { line in
                    Button(line) { copy([String(line.split(separator: ": ", maxSplits: 1).last ?? "")]) }
                }
            }
        }

        if let app = Self.mp3tag {
            Button("Open in Mp3tag") {
                Log.app.info("open in mp3tag", metadata: Log.paths(urls.map(\.path)))
                NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: .init()) { _, error in
                    if let error { Log.app.error("open in mp3tag failed", metadata: ["error": "\(error)"]) }
                }
            }
        }

        Button("Show in Finder") {
            Log.app.info("show in finder", metadata: Log.paths(urls.map(\.path)))
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
            .keyboardShortcut("r", modifiers: [.command, .shift])
    }
}

func copy(_ values: [String]) {
    var seen: Set<String> = []
    let text = values.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
    Log.app.info("copy", metadata: ["values": "\(values.count)", "characters": "\(text.count)"])
    guard !text.isEmpty else { return }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

func copyText(_ tracks: [Track]) -> String {
    tracks.map { "\($0.title) — \($0.artist) — \($0.album)" }.joined(separator: "\n")
}

struct CopyMenu: View {
    let tracks: [Track]
    var album: Album?

    var body: some View {
        if !tracks.isEmpty {
            Menu("Copy") {
                if let album {
                    Button("Artist") { copy([album.artist]) }
                    Button("Album") { copy([album.title]) }
                } else {
                    Button(tracks.count == 1 ? "Song Name" : "Song Names") { copy(tracks.map(\.title)) }
                    Button("Artist") { copy(tracks.map(\.artist)) }
                    Button("Album") { copy(tracks.map(\.album)) }
                    Divider()
                    Button("Song, Artist, and Album") { copy([copyText(tracks)]) }
                    Button("Artist - Song Name") { copy(tracks.map { "\($0.artist) - \($0.title)" }) }
                }
            }

            Divider()
        }
    }
}

struct LyricsView: View {
    static let width: CGFloat = 320

    @Environment(Lyrics.self) private var lyrics
    @Environment(Player.self) private var player
    @State private var editing = false {
        didSet { if editing != oldValue { Log.lyrics.info("editing", metadata: ["on": "\(editing)"]) } }
    }
    @State private var asking = false
    @FocusState private var typing: Bool

    private func close() {
        guard editing else {
            editing = true
            return
        }
        guard lyrics.modified else {
            lyrics.flush()
            editing = false
            return
        }
        asking = true
    }

    var body: some View {
        if let track = lyrics.track {
            let lines = lyrics.synced
            let live = player.current == track
            let current = live ? LRC.index(at: player.position, in: lines) : nil

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading) {
                        Text(track.title).font(.headline).lineLimit(2)
                        Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if lyrics.loading {
                            ProgressView().controlSize(.small)
                        }
                        if !lyrics.hasLocalLyrics {
                            Button("Refresh", systemImage: "arrow.clockwise", action: lyrics.refresh)
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }
                        Button("Show in a Floating Window", systemImage: "macwindow") { lyrics.floating = true }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        if !lines.isEmpty {
                            Button(editing ? "Done" : "Edit", systemImage: editing ? "checkmark" : "pencil") { close() }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .alert("Save your lyric edit?", isPresented: $asking) {
                                    Button("Save") { lyrics.flush(); editing = false }
                                    Button("Discard", role: .destructive) { lyrics.discard(); editing = false }
                                    Button("Cancel", role: .cancel) {}
                                } message: {
                                    Text("The new text is not on the disk yet. Save it, or discard it and keep the lyrics the file has.")
                                }
                        }
                    }
                }

                Group {
                    if !editing, !lines.isEmpty {
                        SyncedLyrics(lines: lines, current: current, playing: live && player.playing) { player.seek($0) }
                    } else {
                        TextEditor(text: Binding { lyrics.text } set: { lyrics.edit($0) })
                            .focused($typing)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                    }
                }
                .background(Color(nsColor: NSColor.alternatingContentBackgroundColors[1]), in: RoundedRectangle(cornerRadius: 6))
                .alert("Replace local lyrics?", isPresented: Binding(
                    get: { lyrics.pendingReplace },
                    set: { if !$0 { lyrics.cancelReplace() } }
                )) {
                    Button("Replace", role: .destructive) { lyrics.confirmReplace() }
                    Button("Cancel", role: .cancel) { lyrics.cancelReplace() }
                } message: {
                    Text("New lyrics found online. Replace your local version?")
                }
            }
            .padding()
            .onChange(of: track) { editing = false }
            .onReceive(NotificationCenter.default.publisher(for: .editLyrics)) { _ in
                if !lines.isEmpty { editing = true }
                Task { typing = true }
            }
        }
    }
}

/// The search field and the query of the library, and what follows one another.
/// Its own view, because a `body` this wide stops the Swift type checker: the
/// rules are the same, they only live somewhere smaller.
private struct QueryFocus: ViewModifier {
    @Environment(Library.self) private var library
    @Environment(Playlists.self) private var playlists
    @Binding var navigation: Navigation
    /// The lyrics of the window, passed in by hand: the window owns them as its
    /// own state and injects them in its own body, which is inside every modifier
    /// of that body, so reading them from the environment here traps on the first
    /// render. `ViewStructureTests` keeps that rule.
    let lyrics: Lyrics
    let tracker: Tracker

    let placed: () -> Void
    let remember: () -> Void
    @Binding var search: String

    func body(content: Content) -> some View {
        content
            .onChange(of: navigation.place, placed)
            .onChange(of: playlists.names, initial: true) { lyrics.settle { navigation.prune(playlists.names, fallback: .section(.albums)) } }
            .onChange(of: navigation.page) {
                guard !navigation.searching else { return }

                search = ""
                library.query = ""
            }
            .onChange(of: library.query, initial: true) {
                if search != library.query { search = library.query }
            }
            .onChange(of: library.query) { old, new in
                Log.navigation.info("query", metadata: ["old": "\(old)", "new": "\(new)"])
                lyrics.settle { navigation.searched(from: old, to: new, leaving: tracker.position) }
                remember()
            }
    }
}

struct SyncedLyrics: NSViewRepresentable {
    let lines: [SyncedLine]
    let current: Int?
    let playing: Bool
    let seek: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let text = LyricsTextView(usingTextLayoutManager: false)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 8, height: 12)
        text.isVerticallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.autoresizingMask = .width
        text.textContainer?.widthTracksTextView = true
        text.click = context.coordinator.click

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = text
        context.coordinator.text = text
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.resize), name: NSView.frameDidChangeNotification, object: scroll)

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.seek = seek

        if coordinator.lines != lines {
            coordinator.load(lines, current: current)
            coordinator.center(animated: false)
        } else if coordinator.current != current {
            let glide = Coordinator.glides(coordinator.current, current, playing: playing)

            if !glide {
                Log.lyrics.debug("scroll instant", metadata: ["from": "\(coordinator.current.map { "\($0)" } ?? "none")", "to": "\(current.map { "\($0)" } ?? "none")", "lines": "\(lines.count)"])
            }

            coordinator.highlight(current)
            coordinator.center(animated: glide)
        }
    }

    final class Coordinator: NSObject {
        weak var text: NSTextView?
        var seek: (Double) -> Void = { _ in }
        private(set) var lines: [SyncedLine] = []
        private(set) var current: Int?
        private var ranges: [NSRange] = []

        func load(_ lines: [SyncedLine], current: Int?) {
            guard let storage = text?.textStorage else { return }

            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 4
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            var location = 0

            ranges = lines.map {
                let range = NSRange(location: location, length: ($0.text as NSString).length)
                location += range.length + 1
                return range
            }

            storage.setAttributedString(NSAttributedString(string: lines.map(\.text).joined(separator: "\n"), attributes: attributes))
            self.lines = lines
            self.current = nil
            highlight(current)
        }

        func highlight(_ index: Int?) {
            guard let storage = text?.textStorage else { return }

            if let old = current, ranges.indices.contains(old) {
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: ranges[old])
            }

            if let index, ranges.indices.contains(index) {
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: ranges[index])
            }

            current = index
        }

        /// Only the line that plays next in a song that plays glides. A restored
        /// session, a seek, a new song, and a repeat land where they belong at
        /// once, so the window never shows the lyrics travelling to the line that
        /// is already singing.
        nonisolated static func glides(_ from: Int?, _ to: Int?, playing: Bool) -> Bool {
            guard playing, let from, let to else { return false }

            return abs(from - to) == 1
        }

        func center(animated: Bool) {
            guard let text, let scroll = text.enclosingScrollView, let manager = text.layoutManager, let container = text.textContainer,
                  text.selectedRange().length == 0 else { return }

            var origin = NSPoint.zero
            if let current, ranges.indices.contains(current) {
                manager.ensureLayout(for: container)
                let glyphs = manager.glyphRange(forCharacterRange: ranges[current], actualCharacterRange: nil)
                let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                let visible = scroll.contentView.bounds.height
                origin.y = min(max(rect.midY + text.textContainerInset.height - visible / 2, 0), max(text.frame.height - visible, 0))
            }

            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    scroll.contentView.animator().setBoundsOrigin(origin)
                }
            } else {
                scroll.contentView.setBoundsOrigin(origin)
            }

            scroll.reflectScrolledClipView(scroll.contentView)
        }

        @objc func resize() {
            center(animated: false)
        }

        func click(_ index: Int) {
            guard let line = ranges.lastIndex(where: { $0.location <= index }) else { return }

            seek(lines[line].time)
        }
    }
}

final class LyricsTextView: NSTextView {
    var click: (Int) -> Void = { _ in }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0 else { return }

        click(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
    }
}

struct Marquee: View {
    private static let gap: CGFloat = 40
    private static let speed: CGFloat = 30
    private static let pause = 2.0

    let text: String
    @State private var width: CGFloat = 0
    @State private var visible: CGFloat = 0
    @State private var start = Date.now
    @Environment(\.controlActiveState) private var state

    var body: some View {
        let overflow = width > visible
        let cycle = width + Marquee.gap

        Text(text)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { visible = $0 }
            .overlay(alignment: .leading) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !overflow || state == .inactive)) { context in
                    let phase = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: Marquee.pause + cycle / Marquee.speed)
                    let offset = overflow ? -max(phase - Marquee.pause, 0) * Marquee.speed : 0

                    HStack(spacing: Marquee.gap) {
                        Text(text)
                        if overflow { Text(text) }
                    }
                    .fixedSize()
                    .offset(x: offset)
                }
            }
            .background {
                Text(text).fixedSize().hidden().onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
            }
            .clipped()
            .onChange(of: text) { start = .now }
    }
}

struct Stripe: ViewModifier {
    static let height: CGFloat = 32
    static let padding: CGFloat = 5

    let index: Int
    var selected = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(height: Stripe.height)
            .background(selected ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : index.isMultiple(of: 2) ? .clear : Color(nsColor: NSColor.alternatingContentBackgroundColors[1]), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

extension View {
    func stripe(_ index: Int, selected: Bool = false) -> some View {
        modifier(Stripe(index: index, selected: selected))
    }
}

struct Cover: View {
    let track: Track?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = track.flatMap(Artwork.image) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct AlbumStrip: View {
    static let minimum: CGFloat = 280
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 16

    let albums: [Album]
    @Environment(Player.self) private var player
    @Environment(\.go) private var go
    @State private var width: CGFloat = 0

    static func width(of count: Int, in available: CGFloat) -> CGFloat {
        guard count > 0 else { return minimum }

        let room = available - 2 * padding - spacing * CGFloat(count - 1)
        return max(minimum, room / CGFloat(count))
    }

    var body: some View {
        let card = Self.width(of: albums.count, in: width)

        ScrollView(.horizontal) {
            LazyHStack(spacing: Self.spacing) {
                ForEach(albums) { album in
                    HStack(alignment: .top, spacing: 12) {
                        Cover(track: album.tracks[0]).frame(width: 96).shadow(radius: 2, y: 1)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.title).font(.headline).lineLimit(2)
                            Text(album.artist).foregroundStyle(.secondary).lineLimit(1)
                            Text([album.year > 0 ? String(album.year) : nil, count(album.tracks.count, "song")].compactMap(\.self).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 4)
                            Button("Play", systemImage: "play.fill") {
                                player.play(album)
                                go(.playing(album.tracks[0]))
                            }
                            .controlSize(.small)
                            .accessibilityLabel("Play \(album.title)")
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(width: card, height: 116)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(.rect)
                    .onTapGesture { go(.album(album)) }
                    .accessibilityElement(children: .contain)
                    .accessibilityAction(named: "Open") { go(.album(album)) }
                    .contextMenu {
                        TrackMenu(tracks: album.tracks)
                        CopyMenu(tracks: album.tracks, album: album)
                        FileMenu(urls: album.tracks.map(\.url))
                    }
                }
            }
            .padding(Self.padding)
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

struct AlbumGrid: View {
    let albums: [Album]
    @Environment(\.go) private var go
    @State private var selected: Set<Album.ID> = []
    @State private var columns = 1
    @State private var frame = Frame()

    var body: some View {
        let picked = albums.filter { selected.contains($0.id) }

        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)], spacing: 24) {
                    ForEach(albums) { album in
                        Button { go(.album(album)) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Cover(track: album.tracks[0])
                                    .shadow(radius: 2, y: 1)
                                    .overlay {
                                        if selected.contains(album.id) {
                                            RoundedRectangle(cornerRadius: 6).stroke(.tint, lineWidth: 3)
                                        }
                                    }
                                    .onGeometryChange(for: CGRect?.self) { selected.contains(album.id) ? $0.frame(in: .global) : nil } action: { if let rect = $0 { frame.rect = rect } }
                                Text(album.title).lineLimit(1).padding(.top, 4)
                                Text(album.artist).lineLimit(1).foregroundStyle(.secondary)
                                Text(count(album.tracks.count, "song")).font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded { selected = [album.id] })
                        .contextMenu {
                            TrackMenu(tracks: album.tracks)
                            CopyMenu(tracks: album.tracks, album: album)
                            FileMenu(urls: album.tracks.map(\.url))
                        }
                    }
                }
                .padding(20)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columns = max(Int(($0 - 20) / 180), 1) }
            .modifier(Keys(count: albums.count, columns: columns, selected: { selected.contains(albums[$0].id) }, select: { index in
                selected = [albums[index].id]
                proxy.scrollTo(albums[index].id)
            }, enter: { go(.album(albums[$0])) }, point: { _ in CGPoint(x: frame.rect.midX, y: frame.rect.midY) }, extend: { index in
                selected.insert(albums[index].id)
                proxy.scrollTo(albums[index].id)
            }, selectAll: { selected = Set(albums.map(\.id)) }))
            .modifier(Selected(tracks: picked.flatMap(\.tracks), album: picked.count == 1 ? picked[0] : nil))
            .modifier(Remember(selection: picked.map(\.id)) { selected = Set($0) })
        }
    }
}

extension Notification.Name {
    static let rightClick = Notification.Name("rightClick")
    static let key = Notification.Name("key")
    static let reveal = Notification.Name("reveal")
    static let editLyrics = Notification.Name("editLyrics")
    static let saveLyrics = Notification.Name("saveLyrics")
    static let floatLyrics = Notification.Name("floatLyrics")
    static let clearUpNext = Notification.Name("clearUpNext")
    static let banSongs = Notification.Name("banSongs")
    static let discovery = Notification.Name("discovery")
    static let find = Notification.Name("find")
}

enum Key {
    case step(Step), enter, menu, delete, all
}

func reachable(_ table: NSTableView, in content: NSView) -> Bool {
    guard let frame = content.superview else { return false }

    let point = table.convert(NSPoint(x: table.visibleRect.midX, y: table.visibleRect.midY), to: nil)
    return frame.hitTest(frame.convert(point, from: nil))?.isDescendant(of: table) == true
}

func showMenu(at point: CGPoint? = nil, in table: NSTableView? = nil) {
    guard let window = NSApp.keyWindow, let content = window.contentView else { return }

    let location: CGPoint
    if let point {
        location = content.convert(point, to: nil)
    } else {
        var tables: [NSTableView] = []
        var views = [content]
        while table == nil, let view = views.popLast() {
            if let table = view as? NSTableView, !table.isHiddenOrHasHiddenAncestor, table.selectedRow >= 0, reachable(table, in: content) { tables.append(table) } else { views += view.subviews }
        }

        guard let table = table ?? tables.max(by: { $0.convert(CGPoint.zero, to: nil).x < $1.convert(CGPoint.zero, to: nil).x }), table.selectedRow >= 0 else { return }

        let rect = table.rect(ofRow: table.selectedRow)
        table.scrollRowToVisible(table.selectedRow)
        location = table.convert(CGPoint(x: rect.minX + 40, y: rect.midY), to: nil)
    }

    guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
          let frame = content.superview, let view = frame.hitTest(frame.convert(location, from: nil)) else { return }

    view.rightMouseDown(with: event)
}

extension EnvironmentValues {
    @Entry var active = true
    @Entry var restore = Position()
    @Entry var tracker = Tracker()
}

final class Memo<Value> {
    private var token: AnyHashable?
    private var stored: Value?

    func value(_ token: AnyHashable, _ make: () -> Value) -> Value {
        if token == self.token, let stored { return stored }

        let value = make()
        self.token = token
        stored = value
        return value
    }
}

final class Tracker {
    var position = Position()
    var target: Track.ID?
}

struct Remember: ViewModifier {
    let selection: [String]
    let select: ([String]) -> Void
    @State private var scroll = ScrollPosition()
    @State private var offset = 0.0
    @Environment(\.active) private var active
    @Environment(\.restore) private var restore
    @Environment(\.tracker) private var tracker

    func body(content: Content) -> some View {
        let position = Position(offset: offset, selection: selection)

        content
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: Double.self) { $0.contentOffset.y + $0.contentInsets.top } action: { offset = $1 }
            .onAppear {
                guard active, restore != Position() else { return }

                select(restore.selection)
                if let offset = restore.offset { scroll.scrollTo(y: offset) }
            }
            .onChange(of: position, initial: true) { if active { tracker.position = position } }
            .onChange(of: active) {
                guard active else { return }

                if restore != Position() {
                    select(restore.selection)
                    if let offset = restore.offset { scroll.scrollTo(y: offset) }
                }
                tracker.position = position
            }
    }
}

extension Player {
    func start(_ tracks: [Track], at index: Int) {
        if tracks[index] == current { toggle() } else { play(tracks, at: index) }
    }

    func play(_ album: Album) {
        shuffle = false
        play(album.tracks)
    }
}

struct Keys: ViewModifier {
    let count: Int
    var columns = 1
    let selected: (Int) -> Bool
    let select: (Int) -> Void
    let enter: (Int) -> Void
    var point: ((Int) -> CGPoint?)?
    var extend: ((Int) -> Void)?
    var delete: (() -> Void)?
    var selectAll: (() -> Void)?
    @Environment(\.active) private var active

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .key)) { notification in
            guard active, count > 0, let key = notification.object as? Key else { return }

            let first = (0..<count).first(where: selected)
            let last = (0..<count).last(where: selected)

            switch key {
            case .step(let step):
                guard let index = step.index(first: first, last: last, count: count, columns: columns) else { return }

                switch step {
                case .extendUp, .extendDown: extend?(index)
                default: select(index)
                }
            case .enter: if let first { enter(first) }
            case .menu: if let first { showMenu(at: point?(first)) }
            case .delete: if first != nil { delete?() }
            case .all: selectAll?()
            }
        }
    }
}

final class Frame {
    var rect = CGRect.zero
}

struct AlbumView: View {
    let album: Album
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(YouTube.self) private var youTube
    @Environment(Lyrics.self) private var lyrics
    @Environment(Likes.self) private var likes
    @Environment(\.go) private var go
    @Environment(\.active) private var active
    @Environment(\.tracker) private var tracker
    @State private var selection: Set<Track.ID> = []
    @State private var anchor: Int?
    @State private var list = Frame()
    @State private var revealed = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .bottom, spacing: 20) {
                        Cover(track: album.tracks[0]).frame(width: 220).shadow(radius: 4, y: 2)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(album.title).font(.largeTitle.bold()).lineLimit(2)
                            Button(album.artist) { go(.search(album.artist)) }
                                .buttonStyle(.plain)
                                .pointerStyle(.link)
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text([album.year > 0 ? String(album.year) : nil, count(album.tracks.count, "song"), album.tracks.reduce(0) { $0 + $1.duration }.time].compactMap(\.self).joined(separator: " · "))
                                .foregroundStyle(.secondary)

                            HStack {
                                Button("Play", systemImage: "play.fill") { player.play(album) }
                                Button("Shuffle", systemImage: "shuffle") { player.shuffle = true; player.play(album.tracks, at: .random(in: album.tracks.indices)) }
                            }
                            .controlSize(.large)
                            .padding(.top, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .padding(.bottom, 20)
                    .contextMenu {
                        TrackMenu(tracks: album.tracks)
                        CopyMenu(tracks: album.tracks, album: album)
                        FileMenu(urls: album.tracks.map(\.url))
                    }

                    LazyVStack(spacing: 0) {
                        ForEach(album.tracks.indices, id: \.self) { index in
                            let track = album.tracks[index]

                            HStack {
                                Group {
                                    if player.current == track {
                                        Image(systemName: player.playing ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.tint)
                                    } else {
                                        Text(track.number > 0 ? String(track.number) : "").foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 28, alignment: .trailing)

                                let now = track == youTube.showing ?? player.current
                                Text(track.title).foregroundStyle(now ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))

                                if likes.contains(track) {
                                    Image(systemName: "heart").font(.caption).foregroundStyle(now ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                }

                                if album.artist != track.artist {
                                    Text(track.artist).foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text("\(library.plays.count(track))").monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                                    .help("Times played")
                                Text(track.duration.time).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .stripe(index, selected: selection.contains(track.id))
                            .onTapGesture { select(index) }
                            .contextMenu {
                                let tracks = selection.contains(track.id) ? album.tracks.filter { selection.contains($0.id) } : [track]

                                TrackMenu(tracks: tracks)
                                CopyMenu(tracks: tracks)
                                FileMenu(urls: tracks.map(\.url))
                            }
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { list.rect = $0 }
                }
                .padding(20)
            }
            .task { reveal(proxy) }
            .modifier(Keys(count: album.tracks.count, selected: { selection.contains(album.tracks[$0].id) }, select: { index in
                selection = [album.tracks[index].id]
                anchor = index
                proxy.scrollTo(index)
            }, enter: { player.start(album.tracks, at: $0) }, point: { CGPoint(x: list.rect.minX + 40, y: list.rect.minY + (CGFloat($0) + 0.5) * Stripe.height) }, extend: { index in
                selection.insert(album.tracks[index].id)
                proxy.scrollTo(index)
            }, selectAll: {
                selection = Set(album.tracks.map(\.id))
                anchor = album.tracks.indices.first
            }))
            .modifier(Selected(tracks: album.tracks.filter { selection.contains($0.id) }))
            .modifier(Remember(selection: album.tracks.filter { selection.contains($0.id) }.map(\.url.path)) { paths in
                revealed = true
                let picked = album.tracks.indices.filter { paths.contains(album.tracks[$0].url.path) }
                selection = Set(picked.map { album.tracks[$0].id })
                anchor = picked.first
            })
        }
        .onReceive(NotificationCenter.default.publisher(for: .rightClick)) { notification in
            guard active, let point = notification.object as? CGPoint, list.rect.contains(point) else { return }

            let index = Int((point.y - list.rect.minY) / Stripe.height)
            guard album.tracks.indices.contains(index), !selection.contains(album.tracks[index].id) else { return }

            selection = [album.tracks[index].id]
            anchor = index
        }
        .onChange(of: youTube.showing ?? player.current) { _, track in
            guard let track, let index = album.tracks.firstIndex(of: track) else { return }

            selection = [track.id]
            anchor = index
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard !revealed else { return }
        revealed = true

        if let target = tracker.target, let index = album.tracks.firstIndex(where: { $0.id == target }) {
            tracker.target = nil
            selection = [target]
            anchor = index
            proxy.scrollTo(index, anchor: .center)
            return
        }

        let matches = album.tracks.indices.filter { library.matched(album.tracks[$0]) }

        if let first = matches.first {
            selection = Set(matches.map { album.tracks[$0].id })
            anchor = first
            proxy.scrollTo(first, anchor: .center)
            return
        }

        guard let track = youTube.showing ?? player.current, let index = album.tracks.firstIndex(of: track) else { return }

        selection = [track.id]
        anchor = index
    }

    private func select(_ index: Int) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        let id = album.tracks[index].id

        if event?.clickCount == 2 {
            selection = [id]
            player.play(album.tracks, at: index)
        } else if flags.contains(.shift), let anchor, album.tracks.indices.contains(anchor) {
            selection = Set(album.tracks[min(anchor, index)...max(anchor, index)].map(\.id))
        } else if flags.contains(.command) {
            if selection.remove(id) == nil { selection.insert(id) }
            anchor = index
        } else {
            selection = [id]
            anchor = index
        }
    }
}

struct ArtistList: View {
    let artists: [(name: String, albums: [Album])]
    @Environment(\.go) private var go
    @State private var selected: String?

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selected) {
                ForEach(artists.indices, id: \.self) { index in
                    let artist = artists[index]

                    Button { go(.artist(artist.name)) } label: {
                        HStack {
                            Cover(track: artist.albums[0].tracks[0]).frame(width: 40)
                            Text(artist.name)
                            Spacer()
                            Text(count(artist.albums.count, "album") + " · " + count(artist.albums.reduce(0) { $0 + $1.tracks.count }, "song")).foregroundStyle(.secondary)
                            Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Copy Artist") { copy([artist.name]) }
                    }
                    .tag(artist.name)
                }
            }
            .modifier(Keys(count: artists.count, selected: { artists[$0].name == selected }, select: { index in
                selected = artists[index].name
                proxy.scrollTo(index)
            }, enter: { go(.artist(artists[$0].name)) }))
        }
    }
}

struct GoMenu: View {
    let track: Track
    @Environment(Library.self) private var library
    @Environment(LastFM.self) private var lastFM
    @Environment(\.go) private var go

    var body: some View {
        if let album = library.album(track.albumID) {
            Button("Go to Album") { go(.album(album)) }
        }

        if !library.albums(by: track.artist).isEmpty {
            Button("Go to Artist") { go(.artist(track.artist)) }
        }

        Button("Go to Last.fm") { lastFM.openArtist(track.artist) }
            .disabled(lastFM.user.isEmpty)

        Divider()
    }
}

struct Cell: View {
    let text: String
    let playing: Bool
    var liked = false
    var added = false
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .foregroundStyle(playing && prominence != .increased ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))

            if added {
                Image(systemName: "text.badge.plus").font(.caption).foregroundStyle(.secondary).help("Added to Up Next")
            }

            if liked {
                Image(systemName: "heart").font(.caption).foregroundStyle(playing && prominence != .increased ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.vertical, Stripe.padding)
    }
}

struct SongTable: View {
    let tracks: [Track]
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(YouTube.self) private var youTube
    @Environment(Likes.self) private var likes
    @Environment(\.go) private var go
    @State private var selection: Set<Row.ID> = []
    @State private var sort = Sort()
    @State private var sorted = Sorted<Row>()
    @Environment(\.active) private var active

    var body: some View {
        let now = youTube.showing ?? player.current
        let plays = library.plays
        let rows = sorted.apply(sort, token: [library.scans, plays.revision]) {
            tracks.enumerated().map { Row(id: $0.offset, track: $0.element, plays: plays.count($0.element)) }
        }

        ScrollViewReader { proxy in
            Table(rows, selection: $selection, sortOrder: order($sort, "songs")) {
                TableColumn("Title", value: \.track.title) { Cell(text: $0.track.title, playing: $0.track == now, liked: likes.contains($0.track)) }
                TableColumn("Artist", value: \.track.artist) { Cell(text: $0.track.artist, playing: $0.track == now) }
                TableColumn("Album", value: \.track.album) { Cell(text: $0.track.album, playing: $0.track == now) }
                TableColumn("Plays", value: \.plays) { Cell(text: "\($0.plays)", playing: $0.track == now).monospacedDigit() }.width(70)
                TableColumn("Time", value: \.track.duration) { Cell(text: $0.track.duration.time, playing: $0.track == now).monospacedDigit() }.width(60)
            }
            .onChange(of: active) { if !active { sort = Sort() } }
            .id(sort)
            .contextMenu(forSelectionType: Row.ID.self) { ids in
                let picked = rows.filter { targets(ids, selection).contains($0.id) }

                if !picked.isEmpty {
                    TrackMenu(tracks: picked.map(\.track))

                    if picked.count == 1 {
                        GoMenu(track: picked[0].track)
                    }

                    CopyMenu(tracks: picked.map(\.track))
                    FileMenu(urls: picked.map(\.track.url))
                }
            } primaryAction: { ids in
                guard let index = rows.firstIndex(where: { ids.contains($0.id) }) else { return }

                player.start(rows.map(\.track), at: index)
                go(.playing(rows[index].track))
            }
            .onChange(of: youTube.showing ?? player.current, initial: true) { _, track in
                if let track, let row = rows.first(where: { $0.track == track }) { selection = [row.id] }
            }
            .modifier(Keys(count: rows.count, selected: { selection.contains(rows[$0].id) }, select: { index in
                selection = [rows[index].id]
                proxy.scrollTo(rows[index].id)
            }, enter: { index in
                player.start(rows.map(\.track), at: index)
                go(.playing(rows[index].track))
            }, extend: { index in
                selection.insert(rows[index].id)
                proxy.scrollTo(rows[index].id)
            }, selectAll: { selection = Set(rows.map(\.id)) }))
            .modifier(Selected(tracks: rows.filter { selection.contains($0.id) }.map(\.track)))

        }
    }
}

struct Find: ViewModifier {
    let action: (NSWindow) -> Void

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .find)) { _ in
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) { action(window) }
        }
    }
}

struct ClearUpNext: ViewModifier {
    @Binding var clearing: Bool
    @Environment(Player.self) private var player

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Clear Up Next?", isPresented: $clearing) {
                Button("Clear Up Next", role: .destructive, action: player.clear)
                Button("Cancel", role: .cancel) { Log.player.info("clear cancelled", metadata: ["count": "\(player.queue.count)"]) }
            } message: {
                Text("The song stops and Up Next becomes empty.")
            }
            .onReceive(NotificationCenter.default.publisher(for: .clearUpNext)) { _ in
                if !player.queue.isEmpty { clearing = true }
            }
    }
}

/// The one definition of the ban item. Every list that shows a song installs it,
/// so a song can be banned from anywhere the user can see it and no list can
/// forget it.
struct BanMenu: View {
    let tracks: [Track]
    @Environment(Bans.self) private var bans

    var body: some View {
        if !tracks.isEmpty {
            let banned = tracks.allSatisfy(bans.contains)

            Button(Bans.label(tracks.count, banned: banned), systemImage: banned ? "arrow.uturn.backward" : "nosign") {
                NotificationCenter.default.post(name: .banSongs, object: tracks)
            }
        }
    }
}

/// The ban of the user is never set by one click: the song menu asks first,
/// and the answer goes to `Bans`, which every discovery reads.
struct BanSongs: ViewModifier {
    @Environment(Bans.self) private var bans
    @State private var showing = false
    @State private var pending: [Track] = []

    private var banned: Bool { !pending.isEmpty && pending.allSatisfy(bans.contains) }
    private var label: String { Bans.label(pending.count, banned: banned) }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(label, isPresented: $showing) {
                Button(label, role: banned ? nil : .destructive) {
                    Log.bans.info("ban confirmed", metadata: ["songs": "\(pending.count)", "state": banned ? "unbanned" : "banned"])
                    banned ? bans.remove(pending) : bans.add(pending)
                    pending = []
                }
                Button("Cancel", role: .cancel) {
                    Log.bans.info("ban cancelled", metadata: ["songs": "\(pending.count)"])
                    pending = []
                }
            } message: {
                Text(banned
                     ? "The song goes back in every discovery of your library."
                     : "The song stays in your library, in every list, and plays when you choose it. No discovery and no Infinity picks it again.")
            }
            .onReceive(NotificationCenter.default.publisher(for: .banSongs)) { note in
                guard let tracks = note.object as? [Track], !tracks.isEmpty else {
                    return Log.bans.debug("ban ignored", metadata: ["reason": "no song"])
                }

                pending = tracks
                showing = true
            }
    }
}

struct UpNextView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(YouTube.self) private var youTube
    @Environment(Likes.self) private var likes
    @Environment(Discovery.self) private var discovery
    @State private var selection: Set<Row.ID> = []
    @State private var sort = Sort()
    @State private var sorted = Sorted<Row>()
    @Environment(\.active) private var active

    var body: some View {
        let rows = sorted.apply(sort, token: [player.revision, player.index, player.head, library.plays.revision]) { player.queue.indices.dropFirst(player.head).map { Row(id: $0, track: player.queue[$0], plays: library.plays.count(player.queue[$0])) } }
        let now = youTube.showing == nil ? player.index : nil

        ZStack {
            if rows.isEmpty {
                ContentUnavailableView("No Songs", systemImage: "list.bullet", description: Text("Play a song or an album to fill Up Next."))
                    .modifier(Selected(tracks: []))
            } else {
                ScrollViewReader { proxy in
                    Table(of: Row.self, selection: $selection, sortOrder: order($sort, "up-next")) {
                        TableColumn("Title", value: \.track.title) { Cell(text: $0.track.title, playing: $0.id == now, liked: likes.contains($0.track), added: added($0)) }
                        TableColumn("Artist", value: \.track.artist) { Cell(text: $0.track.artist, playing: $0.id == now) }
                        TableColumn("Album", value: \.track.album) { Cell(text: $0.track.album, playing: $0.id == now) }
                        TableColumn("Plays", value: \.plays) { Cell(text: "\($0.plays)", playing: $0.id == now).monospacedDigit() }.width(70)
                        TableColumn("Time", value: \.track.duration) { Cell(text: $0.track.duration.time, playing: $0.id == now).monospacedDigit() }.width(60)
                    } rows: {
                        ForEach(rows) { TableRow($0).draggable(String($0.id)) }
                            .dropDestination(for: String.self) { index, ids in
                                guard sort.column == nil else { return Log.navigation.debug("drop ignored", metadata: ["sorted": "\(sort.rawValue)"]) }

                                selection = []
                                player.move(Set(ids.compactMap { Int($0) }).subtracting([player.index]), to: max(player.head + index, player.index + 1))
                            }
                    }
                    .onDeleteCommand { if active { remove(selection) } }
                    .onChange(of: active) { if !active { sort = Sort() } }
                    .id("\(sort.rawValue)\u{1F}\(library.edits)")
                    .contextMenu(forSelectionType: Row.ID.self) { ids in
                        let target = targets(ids, selection)
                        let picked = rows.filter { target.contains($0.id) }

                        if !picked.isEmpty {
                            TrackMenu(tracks: picked.map(\.track))
                            Button("Remove from Up Next", role: .destructive) { remove(target) }
                                .keyboardShortcut(.delete)
                                .disabled(target == [player.index] && rows.count > 1)
                                .buttonStyle(PressableButtonStyle(isDestructive: true))
                            Button("Clear Up Next", role: .destructive) { NotificationCenter.default.post(name: .clearUpNext, object: nil) }
                                .buttonStyle(PressableButtonStyle(isDestructive: true))
                            Divider()

                            if picked.count == 1 {
                                GoMenu(track: picked[0].track)
                            }

                            CopyMenu(tracks: picked.map(\.track))
                            FileMenu(urls: picked.map(\.track.url))
                        }
                    } primaryAction: { ids in
                        if let row = rows.first(where: { ids.contains($0.id) }) { start(row.id) }
                    }
                    .onChange(of: player.index, initial: true) {
                        if player.queue.indices.contains(player.index) { selection = [player.index] }
                    }
                    .modifier(Keys(count: rows.count, selected: { selection.contains(rows[$0].id) }, select: { index in
                        selection = [rows[index].id]
                        proxy.scrollTo(rows[index].id)
                    }, enter: { start(rows[$0].id) }, extend: { index in
                        selection.insert(rows[index].id)
                        proxy.scrollTo(rows[index].id)
                    }, delete: { remove(selection) }, selectAll: { selection = Set(rows.map(\.id)) }))
                    .modifier(Selected(tracks: rows.filter { selection.contains($0.id) }.map(\.track)))
                }
            }

            if discovery.work.spinning {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .accessibilityLabel("Loading Songs")
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: discovery.work.spinning)
        .overlay(alignment: .bottom) { note }
    }

    /// Why the last discovery added nothing, until the user clears it.
    @ViewBuilder private var note: some View {
        if let text = discovery.work.note {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(text)
                Button(action: discovery.dismissNote) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: .capsule)
            .padding(.bottom, 12)
        }
    }

    private func added(_ row: Row) -> Bool {
        player.added.indices.contains(row.id) && player.added[row.id]
    }

    private func start(_ position: Int) {
        if position == player.index { player.toggle() } else { player.jump(to: position) }
    }

    private func remove(_ positions: Set<Int>) {
        guard !Player.clears(player.queue.count, positions, from: player.index) else {
            return NotificationCenter.default.post(name: .clearUpNext, object: nil)
        }

        selection = []
        player.remove(positions)
    }
}

struct PlaylistView: View {
    let name: String
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(YouTube.self) private var youTube
    @Environment(Playlists.self) private var playlists
    @Environment(Likes.self) private var likes
    @State private var selection: Set<Row.ID> = []
    @State private var removing: [Row] = []
    @State private var sort = Sort()
    @State private var sorted = Sorted<Row>()
    @Environment(\.active) private var active

    var body: some View {
        let rows = sorted.apply(sort, library.rows(playlists.paths[name] ?? []))
        let now = youTube.showing ?? player.current

        if playlists.paths[name]?.isEmpty ?? true {
            ContentUnavailableView("No Songs", systemImage: "music.note.list", description: Text("Right-click a song or an album and choose Add to Playlist."))
                .modifier(Selected(tracks: [], playlist: name))
        } else {
            ScrollViewReader { proxy in
                Table(of: Row.self, selection: $selection, sortOrder: order($sort, "playlist")) {
                    TableColumn("Title", value: \.track.title) { Cell(text: $0.track.title, playing: $0.track == now, liked: likes.contains($0.track)) }
                    TableColumn("Artist", value: \.track.artist) { Cell(text: $0.track.artist, playing: $0.track == now) }
                    TableColumn("Album", value: \.track.album) { Cell(text: $0.track.album, playing: $0.track == now) }
                    TableColumn("Plays", value: \.plays) { Cell(text: "\($0.plays)", playing: $0.track == now).monospacedDigit() }.width(70)
                    TableColumn("Time", value: \.track.duration) { Cell(text: $0.track.duration.time, playing: $0.track == now).monospacedDigit() }.width(60)
                } rows: {
                    ForEach(rows) { TableRow($0).draggable(String($0.id)) }
                        .dropDestination(for: String.self) { index, ids in
                            guard sort.column == nil else { return Log.navigation.debug("drop ignored", metadata: ["sorted": "\(sort.rawValue)"]) }

                            move(rows, ids.compactMap { Int($0) }, to: index)
                        }
                }
                .onDeleteCommand {
                    if active { removing = rows.filter { selection.contains($0.id) } }
                }
                .onChange(of: active) { if !active { sort = Sort() } }
                .onChange(of: playlists.paths[name]) { selection = [] }
                .id("\(sort.rawValue)\u{1F}\(library.edits)")
                .contextMenu(forSelectionType: Row.ID.self) { ids in
                    let target = targets(ids, selection)
                    let picked = rows.filter { target.contains($0.id) }

                    if !picked.isEmpty {
                        TrackMenu(tracks: picked.map(\.track), exclude: name)
                        Button("Remove from Playlist", role: .destructive) { removing = picked }
                            .keyboardShortcut(.delete)
                            .buttonStyle(PressableButtonStyle(isDestructive: true))
                        Button("Duplicate") {
                            selection = []
                            playlists.duplicate(target, in: name)
                        }
                        .buttonStyle(PressableButtonStyle())
                        Divider()

                        if picked.count == 1 {
                            GoMenu(track: picked[0].track)
                        }

                        CopyMenu(tracks: picked.map(\.track))
                        FileMenu(urls: picked.map(\.track.url))
                    }
                } primaryAction: { ids in
                    guard let index = rows.firstIndex(where: { ids.contains($0.id) }) else { return }

                    player.start(rows.map(\.track), at: index)
                }
                .onChange(of: youTube.showing ?? player.current, initial: true) { _, track in
                    guard let track else { return }

                    let index = player.index
                    if rows.indices.contains(index), rows[index].track == track, youTube.showing == nil {
                        selection = [rows[index].id]
                    } else if let row = rows.first(where: { $0.track == track }) {
                        selection = [row.id]
                    }
                }
                .confirmationDialog(removing.count == 1 ? "Remove “\(removing[0].track.title)” from the playlist?" : "Remove \(count(removing.count, "song")) from the playlist?", isPresented: Binding { !removing.isEmpty } set: { if !$0 { removing = [] } }) {
                    Button("Remove", role: .destructive) {
                        selection = []
                        playlists.remove(Set(removing.map(\.id)), from: name)
                    }
                }
                .modifier(Keys(count: rows.count, selected: { selection.contains(rows[$0].id) }, select: { index in
                    selection = [rows[index].id]
                    proxy.scrollTo(rows[index].id)
                }, enter: { player.start(rows.map(\.track), at: $0) }, extend: { index in
                    selection.insert(rows[index].id)
                    proxy.scrollTo(rows[index].id)
                }, delete: { removing = rows.filter { selection.contains($0.id) } }, selectAll: { selection = Set(rows.map(\.id)) }))
                .modifier(Selected(tracks: rows.filter { selection.contains($0.id) }.map(\.track), playlist: name) { removing = rows.filter { selection.contains($0.id) } })

            }
        }
    }

    private func move(_ rows: [Row], _ ids: [Int], to index: Int) {
        var order = rows.map(\.id)
        let moved = Set(ids).intersection(order)
        guard !moved.isEmpty else { return }

        let target = index - order[..<index].count { moved.contains($0) }
        let dragged = order.filter { moved.contains($0) }

        order.removeAll { moved.contains($0) }
        order.insert(contentsOf: dragged, at: target)
        selection = []
        playlists.reorder(order, in: name)
    }
}

struct LikedView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(YouTube.self) private var youTube
    @Environment(Likes.self) private var likes
    @State private var selection: Set<Row.ID> = []
    @State private var sort = Sort()
    @State private var sorted = Sorted<Row>()
    @Environment(\.active) private var active

    var body: some View {
        let rows = sorted.apply(sort, library.rows(likes.paths))
        let now = youTube.showing ?? player.current

        if likes.paths.isEmpty {
            ContentUnavailableView("No Liked Songs", systemImage: "heart", description: Text("Right-click a song and choose Like Song, or click the heart next to the song that plays."))
                .modifier(Selected(tracks: []))
        } else {
            ScrollViewReader { proxy in
                Table(of: Row.self, selection: $selection, sortOrder: order($sort, "liked")) {
                    TableColumn("Title", value: \.track.title) { Cell(text: $0.track.title, playing: $0.track == now) }
                    TableColumn("Artist", value: \.track.artist) { Cell(text: $0.track.artist, playing: $0.track == now) }
                    TableColumn("Album", value: \.track.album) { Cell(text: $0.track.album, playing: $0.track == now) }
                    TableColumn("Plays", value: \.plays) { Cell(text: "\($0.plays)", playing: $0.track == now).monospacedDigit() }.width(70)
                    TableColumn("Time", value: \.track.duration) { Cell(text: $0.track.duration.time, playing: $0.track == now).monospacedDigit() }.width(60)
                } rows: {
                    ForEach(rows) { TableRow($0) }
                }
                .onChange(of: active) { if !active { sort = Sort() } }
                .onChange(of: likes.paths) { selection = [] }
                .id("\(sort.rawValue)\u{1F}\(library.edits)")
                .contextMenu(forSelectionType: Row.ID.self) { ids in
                    let picked = rows.filter { targets(ids, selection).contains($0.id) }

                    if !picked.isEmpty {
                        TrackMenu(tracks: picked.map(\.track))

                        if picked.count == 1 {
                            GoMenu(track: picked[0].track)
                        }

                        CopyMenu(tracks: picked.map(\.track))
                        FileMenu(urls: picked.map(\.track.url))
                    }
                } primaryAction: { ids in
                    guard let index = rows.firstIndex(where: { ids.contains($0.id) }) else { return }

                    player.start(rows.map(\.track), at: index)
                }
                .onChange(of: youTube.showing ?? player.current, initial: true) { _, track in
                    guard let track else { return }

                    if let row = rows.first(where: { $0.track == track }) {
                        selection = [row.id]
                    }
                }
                .modifier(Keys(count: rows.count, selected: { selection.contains(rows[$0].id) }, select: { index in
                    selection = [rows[index].id]
                    proxy.scrollTo(rows[index].id)
                }, enter: { player.start(rows.map(\.track), at: $0) }, extend: { index in
                    selection.insert(rows[index].id)
                    proxy.scrollTo(rows[index].id)
                }, selectAll: { selection = Set(rows.map(\.id)) }))
                .modifier(Selected(tracks: rows.filter { selection.contains($0.id) }.map(\.track)))

            }
        }
    }
}

/// The songs the user took out of every discovery. The list is the way back in:
/// Delete or the context menu removes the ban, never the song, the file, or
/// anything else.
struct BannedView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(YouTube.self) private var youTube
    @Environment(Bans.self) private var bans
    @State private var selection: Set<Row.ID> = []
    @State private var sort = Sort()
    @State private var sorted = Sorted<Row>()
    @Environment(\.active) private var active

    var body: some View {
        let rows = sorted.apply(sort, library.rows(bans.paths))
        let now = youTube.showing ?? player.current

        if bans.paths.isEmpty {
            ContentUnavailableView("Nothing Is Banned", systemImage: "nosign", description: Text("Right-click a song and choose Ban Song in Discovery. Those songs come here, and no discovery picks them again."))
                .modifier(Selected(tracks: []))
        } else {
            ScrollViewReader { proxy in
                Table(of: Row.self, selection: $selection, sortOrder: order($sort, "banned")) {
                    TableColumn("Title", value: \.track.title) { Cell(text: $0.track.title, playing: $0.track == now) }
                    TableColumn("Artist", value: \.track.artist) { Cell(text: $0.track.artist, playing: $0.track == now) }
                    TableColumn("Album", value: \.track.album) { Cell(text: $0.track.album, playing: $0.track == now) }
                    TableColumn("Plays", value: \.plays) { Cell(text: "\($0.plays)", playing: $0.track == now).monospacedDigit() }.width(70)
                    TableColumn("Time", value: \.track.duration) { Cell(text: $0.track.duration.time, playing: $0.track == now).monospacedDigit() }.width(60)
                } rows: {
                    ForEach(rows) { TableRow($0) }
                }
                .onChange(of: active) { if !active { sort = Sort() } }
                .onChange(of: bans.paths) { selection = [] }
                .id("\(sort.rawValue)\u{1F}\(library.edits)")
                .contextMenu(forSelectionType: Row.ID.self) { ids in
                    let picked = rows.filter { targets(ids, selection).contains($0.id) }

                    if !picked.isEmpty {
                        Button(Bans.label(picked.count, banned: true)) { remove(picked.map(\.track)) }
                            .keyboardShortcut(.delete, modifiers: [])
                        Divider()

                        TrackMenu(tracks: picked.map(\.track))

                        if picked.count == 1 {
                            GoMenu(track: picked[0].track)
                        }

                        CopyMenu(tracks: picked.map(\.track))
                        FileMenu(urls: picked.map(\.track.url))
                    }
                } primaryAction: { ids in
                    guard let index = rows.firstIndex(where: { ids.contains($0.id) }) else { return }

                    player.start(rows.map(\.track), at: index)
                }
                .onChange(of: youTube.showing ?? player.current, initial: true) { _, track in
                    guard let track, let row = rows.first(where: { $0.track == track }) else { return }

                    selection = [row.id]
                }
                .modifier(Keys(count: rows.count, selected: { selection.contains(rows[$0].id) }, select: { index in
                    selection = [rows[index].id]
                    proxy.scrollTo(rows[index].id)
                }, enter: { player.start(rows.map(\.track), at: $0) }, extend: { index in
                    selection.insert(rows[index].id)
                    proxy.scrollTo(rows[index].id)
                }, delete: { remove(rows.filter { selection.contains($0.id) }.map(\.track)) }, selectAll: { selection = Set(rows.map(\.id)) }))
                .modifier(Selected(tracks: rows.filter { selection.contains($0.id) }.map(\.track)))
            }
        }
    }

    private func remove(_ tracks: [Track]) {
        selection = []
        bans.remove(tracks)
    }
}

struct SpectrumBar: View {
    static let width: CGFloat = 4
    static let gap: CGFloat = 2
    static let height: CGFloat = 26
    static let interval = 1.0 / 60

    @Environment(Player.self) private var player
    @Environment(\.appearsActive) private var shown
    @State private var analyzer = Analyzer()
    @State private var fading = false

    static func count(_ width: CGFloat) -> Int {
        max(Int((width + gap) / (Self.width + gap)), 1)
    }

    static func draw(_ levels: [Float], in context: inout GraphicsContext, size: CGSize) {
        let step = (size.width + gap) / CGFloat(max(levels.count, 1))
        let width = step - gap
        var path = Path()
        for (index, level) in levels.enumerated() {
            let height = max(CGFloat(level) * size.height, width)
            path.addRoundedRect(in: CGRect(x: CGFloat(index) * step, y: size.height - height, width: width, height: height), cornerSize: CGSize(width: width / 2, height: width / 2))
        }
        context.fill(path, with: .linearGradient(Gradient(colors: [.accentColor, .accentColor.opacity(0.35)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }

    static func running(shown: Bool, active: Bool, fading: Bool) -> Bool {
        shown && (active || fading)
    }

    var body: some View {
        let active = player.playing && !player.isMuted

        TimelineView(.animation(minimumInterval: Self.interval, paused: !Self.running(shown: shown, active: active, fading: fading))) { timeline in
            Canvas { context, size in
                let levels = analyzer.update(player.spectrum, count: Self.count(size.width), active: active, time: timeline.date.timeIntervalSinceReferenceDate)
                Self.draw(levels, in: &context, size: size)
            }
        }
        .frame(height: Self.height)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityHidden(true)
        .onChange(of: shown, initial: true) {
            Log.player.debug("spectrum", metadata: ["shown": "\(shown)"])
            player.spectrum.listening = shown
        }
        .task(id: active) {
            guard !active else { return fading = false }

            fading = true
            try? await Task.sleep(for: .seconds(1))
            fading = false
        }
    }
}

struct TimeBar: View {
    @Environment(Player.self) private var player
    @State private var scrub: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text((scrub ?? player.position).time).monospacedDigit().foregroundStyle(.secondary)
            Slider(value: Binding { scrub ?? player.position } set: { scrub = $0 }, in: 0...max(player.duration, 1)) { editing in
                if !editing, let scrub {
                    player.seek(scrub)
                    self.scrub = nil
                }
            }
            .frame(minWidth: 120, maxWidth: .infinity)
            Text(player.duration.time).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct Controls: View {
    let open: (Track) -> Void
    @Environment(Player.self) private var player
    @Environment(Likes.self) private var likes

    var body: some View {
        @Bindable var player = player

        HStack(spacing: 16) {
            Button {
                if let current = player.current { open(current) }
            } label: {
                HStack(spacing: 16) {
                    Cover(track: player.current).frame(width: 48)

                    VStack(alignment: .leading) {
                        Marquee(text: player.current?.title ?? "Not Playing").bold()
                        Marquee(text: player.current.map { "\($0.artist) — \($0.album)" } ?? "").foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 120, maxWidth: 360, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .contextMenu {
                CopyMenu(tracks: player.current.map { [$0] } ?? [])
            }

            if let track = player.current {
                let liked = likes.contains(track)

                Button(liked ? "Unlike Song" : "Like Song", systemImage: liked ? "heart.fill" : "heart") {
                    likes.toggle([track])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(liked ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }

            HStack(spacing: 14) {
                Button("Shuffle", systemImage: "shuffle") { player.shuffle.toggle() }
                    .foregroundStyle(player.shuffle ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
                Button("Previous", systemImage: "backward.fill", action: player.previous)
                Button(action: player.toggle) {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.title)
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.easeInOut(duration: 0.15), value: player.playing)
                        .frame(width: 30, height: 30)
                }
                Button("Next", systemImage: "forward.fill", action: player.next)
                Button("Repeat", systemImage: player.repeatMode == .one ? "repeat.1" : "repeat") {
                    player.repeatMode = Player.Repeat(rawValue: (player.repeatMode.rawValue + 1) % 3)!
                }
                .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .contentTransition(.symbolEffect(.replace))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .disabled(player.current == nil)

            TimeBar()
                .frame(minWidth: 200, maxWidth: .infinity)
                .disabled(player.current == nil)

            Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeInOut(duration: 0.15), value: player.isMuted)
                    .onTapGesture { player.toggleMute() }
                    .padding(.leading, 16)
                    .frame(width: 28, alignment: .center)
                Slider(value: Binding(
                    get: { player.isMuted ? 0 : player.volume },
                    set: { player.isMuted = false; player.volume = $0 }
                ), in: 0...1).frame(width: 90)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Playlists.self) private var playlists
    @Environment(Likes.self) private var likes
    @Environment(Bans.self) private var bans
    @Environment(YouTube.self) private var youTube
    @Environment(\.openWindow) private var openWindow
    @State private var lyrics = Lyrics(enabled: Player.saved?.lyrics ?? true)
    @State private var navigation = Navigation(page: Page(key: Player.saved?.page ?? "") ?? .section(.albums), query: Player.saved?.query ?? "")
    @State private var tracker = Tracker()
    @State private var name = ""
    @State private var deleting: String?
    @State private var clearing = false
    @State private var saved = Player.saved?.path
    @State private var monitor: Any?
    @State private var swipe: CGFloat = 0
    @State private var navigator = Navigator()
    @State private var search = ""
    @State private var panel: LyricsPanel?
    @State private var memo = Memo<String>()
    @FocusState private var focus: Focus?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                NavigationSplitView {
                    List(selection: sidebar) {
                        row("About", "info.circle", .about)

                        ForEach(Section.allCases) { section in
                            row(section.rawValue, section.symbol, .section(section))
                        }

                        row("Liked Songs", "heart", .liked)
                        row("Banned Songs", "nosign", .banned)
                        row("Up Next", "list.bullet", .upNext)

                        SwiftUI.Section {
                            ForEach(playlists.names, id: \.self) { name in
                                row(name, "music.note.list", .playlist(name))
                                    .contextMenu {
                                        Button("Delete Playlist", role: .destructive) { deleting = name }
                                            .keyboardShortcut(.delete, modifiers: [])
                                            .buttonStyle(PressableButtonStyle(isDestructive: true))
                                    }
                            }
                        } header: {
                            HStack {
                                Text("Playlists")
                                Spacer()
                                Button("New Playlist", systemImage: "plus") { playlists.naming = [] }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(ToolbarButtonStyle())
                            }
                        }
                    }
                    .navigationSplitViewColumnWidth(180)
                    .focused($focus, equals: .sidebar)
                    .onDeleteCommand {
                        if case .playlist(let name) = page { deleting = name }
                    }
                } detail: {
                    Group {
                        if library.folders.isEmpty {
                            ContentUnavailableView {
                                Label("No Music", systemImage: "music.note")
                            } description: {
                                Text("Add a folder with music or drop it here.")
                            } actions: {
                                Button("Add Folder…", action: library.choose)
                                    .buttonStyle(PressableButtonStyle(isProminent: true))
                            }
                        } else if library.albums.isEmpty, library.scanning {
                            ProgressView()
                        } else {
                            ZStack {
                                ForEach(navigation.pages, id: \.self) { page in
                                    stack(page)
                                }
                            }
                            .navigationTitle(title)
                            .navigationSubtitle(subtitle)
                        }
                    }
                    .overlay(alignment: swipe > 0 ? .leading : .trailing) {
                        if swipe != 0 {
                            Image(systemName: swipe > 0 ? "chevron.backward" : "chevron.forward")
                                .font(.title2.bold())
                                .padding()
                                .background(.regularMaterial, in: .circle)
                                .opacity(abs(swipe))
                                .padding()
                        }
                    }
                    .background(NavigatorInstaller(navigator: navigator))
                }
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button("Back", systemImage: "chevron.backward", action: goBack)
                            .keyboardShortcut("[")
                            .disabled(!navigation.canGoBack)
                        Button("Forward", systemImage: "chevron.forward", action: goForward)
                            .keyboardShortcut("]")
                            .disabled(navigation.forward.isEmpty)
                    }
                    if page == .upNext {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Clear Up Next", systemImage: "trash") { clearing = true }
                                .help("Clear Up Next")
                                .disabled(player.queue.isEmpty)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(player.lyrics ? "Hide Lyrics" : "Show Lyrics", systemImage: player.lyrics ? "quote.bubble.fill" : "quote.bubble") { player.lyrics.toggle() }
                            .help(player.lyrics ? "Hide Lyrics" : "Show Lyrics")
                    }
                }
                .searchable(text: $search, placement: .toolbarPrincipal)
                .searchFocused($focus, equals: .search)
                .task(id: search) {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { library.query = search }
                }

                if shown, !lyrics.floating {
                    Divider()
                    LyricsView().frame(width: LyricsView.width)
                        .background(Color(nsColor: .textBackgroundColor))
                }
            }

            Divider()
            VStack(spacing: 0) {
                if player.showsSpectrum { SpectrumBar() }
                Controls(open: reveal)
            }
            .background(.bar)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            Log.library.info("drop", metadata: ["folders": "\(folders.count)", "rejected": Log.list(urls.filter { !folders.contains($0) }.prefix(20).map(\.path))])
            library.add(folders)
            return !folders.isEmpty
        }
        .alert("New Playlist", isPresented: Binding { playlists.naming != nil } set: { if !$0 { playlists.naming = nil } }) {
            TextField("Name", text: $name)
            Button("Create") {
                let urls = playlists.naming ?? []
                if let created = playlists.create(name, urls), urls.isEmpty { lyrics.settle { navigation.open(.playlist(created), leaving: tracker.position) } }
                name = ""
            }
            .disabled(!playlists.valid(name))
            Button("Cancel", role: .cancel) {
                Log.playlists.info("create cancelled")
                name = ""
            }
        }
        .confirmationDialog("Delete the playlist “\(deleting ?? "")”?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }) {
            Button("Cancel", role: .cancel) { Log.playlists.info("delete cancelled", metadata: ["name": "\(deleting ?? "")"]) }
            Button("Delete", role: .destructive) {
                if let deleting {
                    lyrics.settle { navigation.remove(.playlist(deleting), fallback: .section(.albums)) }
                    playlists.delete(deleting)
                }
            }
        } message: {
            Text("The app keeps a copy as “\(deleting ?? "").backup.plist” in the Playlists folder.")
        }
        .environment(lyrics)
        .environment(\.go, GoAction { destination in
            Log.navigation.info("go", metadata: ["destination": "\(destination.key)", "page": "\(page.key)", "path": Log.list(path.map(\.key))])
            let route: Route

            switch destination {
            case .album(let album): route = .album(album)
            case .artist(let name): route = .artist(name)
            case .playing(let track):
                guard let album = library.album(track.albumID) else {
                    return Log.navigation.warning("played without album", metadata: ["album": "\(track.albumID)", "path": "\(track.url.path)"])
                }

                if case .section = page, path.last != .album(album) { tracker.target = track.id }
                lyrics.settle { navigation.played(album, leaving: tracker.position) }
                return
            case .search(let text):
                lyrics.settle {
                    navigation.filter(.section(.albums), to: text, leaving: tracker.position)
                    library.query = text
                }
                return
            }

            guard path.last != route else { return Log.navigation.debug("open ignored", metadata: ["route": "\(route.key)", "reason": "already open"]) }

            Log.navigation.info("navigate", metadata: ["page": "\(page.key)", "from": Log.list(path.map(\.key)), "to": "\(route.key)"])
            lyrics.settle { navigation.push(route, leaving: tracker.position) }
        })
        .modifier(ClearUpNext(clearing: $clearing))
        .modifier(BanSongs())
        .modifier(Find { window in focusSearch(window, selecting: true) })
        .onReceive(NotificationCenter.default.publisher(for: .reveal)) { _ in
            if let current = player.current { reveal(current) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .discovery)) { note in
            let stage = note.object as? String ?? Work.done
            Log.navigation.info("discovery", metadata: ["stage": "\(stage)", "songs": "\(player.queue.count)", "page": "\(page.key)"])
            lyrics.settle { navigation.open(.upNext, leaving: tracker.position) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatLyrics)) { _ in
            player.lyrics = true
            guard let current = player.current else { return Log.lyrics.debug("float ignored", metadata: ["reason": "no song"]) }

            lyrics.show(current)
            lyrics.floating = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveLyrics)) { _ in
            Log.lyrics.info("save command")
            lyrics.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            lyrics.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            Log.lyrics.debug("flush", metadata: ["reason": "resign active"])
            lyrics.flush()
        }
        .onChange(of: player.current, initial: true) {
            if let current = player.current { lyrics.show(current) }
        }
        .onChange(of: player.lyrics) {
            Log.lyrics.info("shown", metadata: ["on": "\(player.lyrics)"])
            lyrics.enabled = player.lyrics
            if let current = player.current { lyrics.show(current) }
        }
        .onAppear {
            navigator.available = { (navigation.canGoBack, !navigation.forward.isEmpty) }
            navigator.progress = { swipe = $0 }
            navigator.go = { back, source in
                guard deleting == nil, playlists.naming == nil, NSApp.keyWindow?.attachedSheet == nil else {
                    return Log.navigation.debug("gesture ignored", metadata: ["source": "\(source)"])
                }

                Log.navigation.info("gesture", metadata: ["source": "\(source)", "back": "\(back)"])
                back ? goBack() : goForward()
            }
            focus = .search
            search = library.query
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { press($0) ? nil : $0 }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            lyrics.flush()
        }
        .onChange(of: library.scans, refreshed)
        .onChange(of: library.folders) {
            lyrics.flush()
            playlists.load()
            likes.load()
            bans.load()
        }
        .onChange(of: lyrics.floating) {
            if lyrics.floating {
                let panel = self.panel ?? LyricsPanel(lyrics: lyrics, player: player) { openWindow(id: "main") }
                self.panel = panel
                panel.show()
            } else {
                panel?.hide()
            }
        }
        .modifier(QueryFocus(navigation: $navigation, lyrics: lyrics, tracker: tracker, placed: placed, remember: remember, search: $search))
        .environment(\.tracker, tracker)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(minWidth: 820, minHeight: 520)
    }

    private var sidebar: Binding<Page?> {
        Binding { page } set: { value in if let value { lyrics.settle { navigation.open(value, leaving: tracker.position) } } }
    }

    private func row(_ title: String, _ symbol: String, _ value: Page) -> some View {
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .tag(value)
            .buttonStyle(SidebarButtonStyle())
    }

    private var page: Page { navigation.page }
    private var path: [Route] { navigation.path }

    private var title: String {
        switch path.last {
        case .album(let album): album.title
        case .artist(let name): name
        case nil: page.title
        }
    }

    private var subtitle: String {
        let list: Int? = switch page {
        case .playlist(let name): playlists.paths[name]?.count
        case .liked: likes.paths.count
        case .banned: bans.count
        default: nil
        }
        let token: [AnyHashable] = [page.key, path.map(\.key), library.version, player.queue.count, player.index, player.head, list]
        return memo.value(token) { summarize() }
    }

    private func summarize() -> String {
        switch (path.last, page) {
        case (.album, _): ""
        case (.artist(let name), _): summary(library.albums(by: name))
        case (nil, .section(.albums)): summary(library.filtered)
        case (nil, .section(.artists)): summary(library.artists.flatMap(\.albums))
        case (nil, .section(.songs)): summary(library.tracks)
        case (nil, .playlist(let name)): summary(library.rows(playlists.paths[name] ?? []).map(\.track))
        case (nil, .liked): summary(library.rows(likes.paths).map(\.track))
        case (nil, .banned): summary(library.rows(bans.paths).map(\.track))
        case (nil, .upNext): summary(player.queue.dropFirst(player.head))
        case (nil, .about): ""
        }
    }

    private func stack(_ page: Page) -> some View {
        let current = page == self.page
        let path = navigation.path(of: page)

        return ZStack {
            screen(current && path.isEmpty, current && path.isEmpty ? navigation.place.position : Position()) {
                switch page {
                case .section(.albums): AlbumGrid(albums: library.filtered).id(library.edits)
                case .section(.artists): ArtistList(artists: library.artists)
                case .playlist(let name): PlaylistView(name: name)
                case .liked: LikedView()
                case .banned: BannedView()
                case .upNext: UpNextView()
                case .about: AboutView()
                case .section(.songs):
                    VStack(spacing: 0) {
                        if !library.query.isEmpty, !library.filtered.isEmpty {
                            AlbumStrip(albums: library.filtered).id(library.edits)
                            Divider()
                        }
                        SongTable(tracks: library.tracks).id("\(library.query)\u{1F}\(library.members)\u{1F}\(library.edits)")
                    }
                }
            }

            ForEach(path.indices, id: \.self) { index in
                let route = path[index]
                let top = current && index == path.count - 1

                screen(top, top ? navigation.place.position : Position()) {
                    switch route {
                    case .album(let album): AlbumView(album: album)
                    case .artist(let name): AlbumGrid(albums: library.albums(by: name))
                    }
                }
                .id("\(route.key)\u{1F}\(library.edits)")
            }
        }
    }

    private func screen(_ top: Bool, _ position: Position, @ViewBuilder _ content: () -> some View) -> some View {
        content()
            .environment(\.active, top)
            .environment(\.restore, position)
            .opacity(top ? 1 : 0)
            .allowsHitTesting(top)
            .accessibilityHidden(!top)
    }

    private func goBack() {
        Log.navigation.info("back", metadata: ["page": "\(page.key)", "path": Log.list(path.map(\.key)), "back": "\(navigation.back.count)"])
        lyrics.settle {
            if !navigation.goBack(leaving: tracker.position) { navigation.pop(leaving: tracker.position) }
            arrived()
        }
    }

    private func goForward() {
        Log.navigation.info("forward", metadata: ["page": "\(page.key)", "path": Log.list(path.map(\.key)), "forward": "\(navigation.forward.count)"])
        lyrics.settle {
            navigation.goForward(leaving: tracker.position)
            arrived()
        }
    }

    private func arrived() {
        let query = navigation.place.query
        guard query != library.query else { return }

        search = query
        library.query = query
    }

    private func placed() {
        Log.navigation.info("place", metadata: ["page": "\(page.key)", "path": Log.list(path.map(\.key)), "back": "\(navigation.back.count)", "forward": "\(navigation.forward.count)", "searching": "\(navigation.searching)", "query": "\(navigation.place.query)"])
        tracker.position = navigation.place.position
        remember()
    }

    private func refreshed() {
        player.refresh { library.track($0) }
        likes.load()
        playlists.load()
        bans.load()
        navigation.refresh(library.albums)
        guard let saved, !library.albums.isEmpty else { return }

        self.saved = nil
        let routes = saved.compactMap { Route(key: $0, albums: library.albums) }
        let target = Page(key: Player.saved?.page ?? "") ?? .section(.albums)
        Log.navigation.info("restore", metadata: ["page": "\(target.key)", "current": "\(page.key)", "routes": Log.list(routes.map(\.key))])
        switch target {
        case .liked, .banned, .playlist, .upNext:
            break
        default:
            navigation.restore(routes, on: target)
        }
    }

    private func press(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow, window.identifier?.rawValue.hasPrefix("main") == true, window.attachedSheet == nil,
              playlists.naming == nil, deleting == nil else { return false }

        Log.keys.debug("key", metadata: ["code": "\(event.keyCode)", "flags": "\(String(event.modifierFlags.rawValue, radix: 16))", "focus": "\(String(describing: focus))", "responder": "\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "")"])
        let sidebar = focus == .sidebar
        if event.keyCode == 53, event.modifierFlags.isDisjoint(with: [.command, .option, .control]) { return escape(window, sidebar: sidebar) }
        guard sidebar || focus == .search || !Focus.typing(window.firstResponder) else { return false }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if flags == .command, event.keyCode == 0 {
            NotificationCenter.default.post(name: .key, object: Key.all)
            return true
        }

        if flags == .control, event.keyCode == 36 || event.keyCode == 76 {
            if sidebar { showMenu(in: window.firstResponder as? NSTableView) } else { NotificationCenter.default.post(name: .key, object: Key.menu) }
            return true
        }

        guard flags.isDisjoint(with: [.command, .option, .control]) else { return false }


        let editing = Focus.typing(window.firstResponder)
        if !editing, let characters = event.characters, characters.count == 1, let character = characters.first, Focus.types(character, into: search) {
            search.append(character)
            focusSearch(window)
            return true
        }

        if !editing, event.keyCode == 51, !search.isEmpty {
            search.removeLast()
            focusSearch(window)
            return true
        }

        let typing = !search.isEmpty
        let key: Key
        switch (event.keyCode, sidebar) {
        case (48, false):
            focus = .sidebar
            return true
        case (48, true), (36, true), (76, true):
            focus = .search
            return true
        case (123...126, true): return false
        case (126, _): key = .step(flags == .shift ? .extendUp : .up)
        case (125, _): key = .step(flags == .shift ? .extendDown : .down)
        case (123, _) where !typing: key = .step(.left)
        case (124, _) where !typing: key = .step(.right)
        case (36, false), (76, false): key = .enter
        case (51, false) where !typing: key = .delete
        case (49, false) where !typing:
            player.toggle()
            return true
        default: return false
        }

        NotificationCenter.default.post(name: .key, object: key)
        return true
    }

    private func escape(_ window: NSWindow, sidebar: Bool) -> Bool {
        Log.navigation.info("escape", metadata: ["page": "\(page.key)", "path": Log.list(path.map(\.key)), "video": "\(youTube.showing != nil)", "query": "\(search)"])
        if youTube.showing != nil {
            youTube.close()
        } else if !path.isEmpty {
            goBack()
        } else if !sidebar, focus != .search, Focus.typing(window.firstResponder) {
            focus = .search
        } else if focus != .search, !search.isEmpty {
            search = ""
            library.query = ""
        } else {
            return false
        }
        return true
    }

    private func focusSearch(_ window: NSWindow, selecting: Bool = false) {
        focus = .search
        DispatchQueue.main.async {
            if !Focus.typing(window.firstResponder), let field = Focus.field(in: window) { window.makeFirstResponder(field) }
            if selecting { (window.firstResponder as? NSTextView)?.selectAll(nil) } else { (window.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) }
        }
    }

    private func reveal(_ track: Track) {
        guard let album = library.album(track.albumID) else {
            Log.navigation.warning("reveal without album", metadata: ["album": "\(track.albumID)"])
            return
        }

        Log.navigation.info("reveal", metadata: ["path": "\(track.url.path)", "page": "\(page.key)"])
        navigate([.album(album)])
    }

    private func remember() {
        player.view = (page.key, path.map(\.key), library.query)
        player.save()
    }

    private func navigate(_ value: [Route]) {
        Log.navigation.info("navigate", metadata: ["page": "\(page.key)", "from": Log.list(path.map(\.key)), "to": Log.list(value.map(\.key))])
        lyrics.settle { navigation.show(value, leaving: tracker.position) }
    }

    private var shown: Bool {
        player.lyrics && (player.current != nil || lyrics.selected) && lyrics.track != nil && navigation.lyrics
    }
}

struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(LastFM.self) private var lastFM
    @Environment(Loves.self) private var loves
    @Environment(YouTube.self) private var youTube
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        @Bindable var youTube = youTube
        @Bindable var player = player

        Form {
            SwiftUI.Section("Folders") {
                ForEach(library.folders, id: \.self) { folder in
                    HStack {
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { library.folders.removeAll { $0 == folder } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(IconButtonStyle(isDestructive: true))
                    }
                }

                Button("Add Folder…", action: library.choose)
                    .buttonStyle(PressableButtonStyle(isProminent: true))
            }

            SwiftUI.Section("Playback") {
                Toggle("Show Spectrum", isOn: $player.showsSpectrum)
            }

            SwiftUI.Section {
                if lastFM.key.isEmpty {
                    Text("This build has no Last.fm API key.").foregroundStyle(.secondary)
                } else if lastFM.session.isEmpty {
                    TextField("Username", text: $username)
                    SecureField("Password", text: $password)
                    Button(lastFM.connecting ? "Connecting…" : "Connect") {
                        Task {
                            await lastFM.connect(username, password)
                            password = ""
                        }
                    }
                    .buttonStyle(PressableButtonStyle(isProminent: true))
                    .disabled(username.isEmpty || password.isEmpty || lastFM.connecting)
                } else {
                    LabeledContent("Account", value: lastFM.user)
                    LabeledContent("Pending Scrobbles", value: String(lastFM.pending.count))
                    if !lastFM.rejected.isEmpty { LabeledContent("Rejected by Last.fm", value: String(lastFM.rejected.count)) }
                    LabeledContent("Loved Tracks", value: loves.summary)
                    Button("Sync Loved Tracks Now", action: loves.syncNow)
                        .buttonStyle(PressableButtonStyle())
                        .disabled(loves.syncing)
                    Button("Disconnect", action: lastFM.disconnect)
                    .buttonStyle(PressableButtonStyle(isDestructive: true))
                }

                if !lastFM.status.isEmpty {
                    Text(lastFM.status).foregroundStyle(.secondary)
                }
            } header: {
                Text("Last.fm")
            }

            SwiftUI.Section {
                Button("Sign Out") { Task { await youTube.signOut() } }
                    .buttonStyle(PressableButtonStyle(isDestructive: true))
                Picker("Open Videos In", selection: $youTube.browser) {
                    Text("Floating Window").tag(false)
                    Text("Default Browser").tag(true)
                }

                if !youTube.browser {
                    Picker("Window Corner", selection: $youTube.corner) {
                        ForEach(YouTube.Corner.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                }
            } header: {
                Text("YouTube")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}
