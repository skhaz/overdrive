import SwiftUI
import UniformTypeIdentifiers

enum Section: String, CaseIterable, Identifiable {
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

enum Page: Hashable {
    case section(Section)
    case playlist(String)

    var title: String {
        switch self {
        case .section(let section): section.rawValue
        case .playlist(let name): name
        }
    }
}

enum Destination {
    case album(Album)
    case artist(String)
    case search(String)
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

func count(_ number: Int, _ noun: String) -> String {
    "\(number) \(noun)\(number == 1 ? "" : "s")"
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

    var body: some View {
        if !tracks.isEmpty {
            Button("Play Next") { player.insert(tracks, next: true) }
            Button("Add to Queue") { player.insert(tracks, next: false) }

            Menu("Add to Playlist") {
                let names = playlists.names.filter { $0 != exclude }

                ForEach(names, id: \.self) { name in
                    Button(name) { playlists.add(tracks.map(\.url), to: name) }
                }

                if !names.isEmpty { Divider() }

                Button("New Playlist…") { playlists.naming = tracks.map(\.url) }
            }

            Divider()
        }
    }
}

struct FileMenu: View {
    let urls: [URL]

    var body: some View {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.mp3tag.Mp3tag") {
            Button("Open in Mp3tag") { NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: .init()) }
        }

        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }
}

func copy(_ values: [String]) {
    var seen: Set<String> = []
    let text = values.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
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
                }
            }

            Divider()
        }
    }
}

struct LyricsToolbar: ViewModifier {
    @Environment(Lyrics.self) private var lyrics
    @Environment(Player.self) private var player

    func body(content: Content) -> some View {
        content.toolbar {
            Button("Lyrics", systemImage: "quote.bubble") { lyrics.visible ? lyrics.hide() : lyrics.show(player.current ?? lyrics.track) }
        }
    }
}

struct LyricsView: View {
    static let width: CGFloat = 320

    @Environment(Lyrics.self) private var lyrics
    @Environment(Player.self) private var player
    @State private var editing = false

    var body: some View {
        @Bindable var lyrics = lyrics

        if let track = lyrics.track {
            let lines = lyrics.synced
            let live = player.current == track
            let current = live ? Lyrics.index(at: player.position, in: lines) : nil

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text(track.title).font(.headline).lineLimit(2)
                        Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise", action: lyrics.refresh)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    if !lines.isEmpty {
                        Button(editing ? "Done" : "Edit", systemImage: editing ? "checkmark" : "pencil", action: { editing.toggle() })
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }

                Group {
                    if lyrics.loading, lyrics.text.isEmpty, lyrics.synced.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !editing, !lines.isEmpty {
                        SyncedLyrics(lines: lines, current: current) { player.seek($0) }
                    } else {
                        TextEditor(text: $lyrics.text)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                    }
                }
                .background(Color(nsColor: NSColor.alternatingContentBackgroundColors[1]), in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    Text(lyrics.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Save") {
                        lyrics.save()
                        editing = false
                    }
                    .keyboardShortcut("s")
                    .disabled(!lyrics.changed || lyrics.loading)
                }
            }
            .padding()
            .onChange(of: track) { editing = false }
        } else {
            ContentUnavailableView("No Song", systemImage: "quote.bubble", description: Text("Play a song, or choose Lyrics from the menu of a song."))
        }
    }
}

struct SyncedLyrics: NSViewRepresentable {
    let lines: [SyncedLine]
    let current: Int?
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
            coordinator.highlight(current)
            coordinator.center(animated: true)
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
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
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
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: ranges[old])
            }

            if let index, ranges.indices.contains(index) {
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: ranges[index])
            }

            current = index
        }

        func center(animated: Bool) {
            guard let text, let scroll = text.enclosingScrollView, let manager = text.layoutManager, let container = text.textContainer,
                  let current, ranges.indices.contains(current), text.selectedRange().length == 0 else { return }

            manager.ensureLayout(for: container)
            let glyphs = manager.glyphRange(forCharacterRange: ranges[current], actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let visible = scroll.contentView.bounds.height
            let y = min(max(rect.midY + text.textContainerInset.height - visible / 2, 0), max(text.frame.height - visible, 0))
            let origin = NSPoint(x: 0, y: y)

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

    var body: some View {
        let overflow = width > visible
        let cycle = width + Marquee.gap

        Text(text)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { visible = $0 }
            .overlay(alignment: .leading) {
                TimelineView(.animation(paused: !overflow)) { context in
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

struct AlbumGrid: View {
    let albums: [Album]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)], spacing: 24) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 2) {
                            Cover(track: album.tracks[0]).shadow(radius: 2, y: 1)
                            Text(album.title).lineLimit(1).padding(.top, 4)
                            Text(album.artist).lineLimit(1).foregroundStyle(.secondary)
                            Text(count(album.tracks.count, "song")).font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        TrackMenu(tracks: album.tracks)
                        CopyMenu(tracks: album.tracks, album: album)
                        FileMenu(urls: album.tracks.map(\.url))
                    }
                }
            }
            .padding(20)
        }
    }
}

struct AlbumView: View {
    let album: Album
    @Environment(Player.self) private var player
    @Environment(Lyrics.self) private var lyrics
    @Environment(\.go) private var go
    @State private var selection: Set<Track.ID> = []
    @State private var anchor: Int?

    var body: some View {
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
                            Button("Play", systemImage: "play.fill") { player.shuffle = false; player.play(album.tracks) }
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

                            Text(track.title)

                            if album.artist != track.artist {
                                Text(track.artist).foregroundStyle(.secondary)
                            }

                            Spacer()

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
            }
            .padding(20)
            .padding(.trailing, lyrics.visible ? LyricsView.width : 0)
        }
        .navigationTitle(album.title)
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

    var body: some View {
        List(artists, id: \.name) { artist in
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
        }
    }
}

struct GoMenu: View {
    let track: Track
    @Environment(Library.self) private var library
    @Environment(\.go) private var go

    var body: some View {
        if let album = library.albums.first(where: { $0.id == track.albumID }) {
            Button("Go to Album") { go(.album(album)) }
        }

        if library.albums.contains(where: { $0.artist == track.artist }) {
            Button("Go to Artist") { go(.artist(track.artist)) }
        }

        Divider()
    }
}

struct SongTable: View {
    let tracks: [Track]
    @Environment(Player.self) private var player
    @State private var selection: Set<Track.ID> = []

    var body: some View {
        Table(tracks, selection: $selection) {
            TableColumn("Title") { Text($0.title).padding(.vertical, Stripe.padding) }
            TableColumn("Artist") { Text($0.artist).padding(.vertical, Stripe.padding) }
            TableColumn("Album") { Text($0.album).padding(.vertical, Stripe.padding) }
            TableColumn("Time") { Text($0.duration.time).monospacedDigit().padding(.vertical, Stripe.padding) }.width(60)
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            TrackMenu(tracks: tracks.filter { ids.contains($0.id) })

            if ids.count == 1, let track = tracks.first(where: { ids.contains($0.id) }) {
                GoMenu(track: track)
            }

            CopyMenu(tracks: tracks.filter { ids.contains($0.id) })
            FileMenu(urls: Array(ids))
        } primaryAction: { ids in
            guard let id = ids.first, let index = tracks.firstIndex(where: { $0.id == id }) else { return }

            player.play(tracks, at: index)
        }
    }
}

struct PlaylistView: View {
    let name: String
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Playlists.self) private var playlists
    @State private var selection: Set<Row.ID> = []
    @State private var removing: [Row] = []

    var body: some View {
        let rows = library.rows(playlists.paths[name] ?? [])

        if playlists.paths[name]?.isEmpty ?? true {
            ContentUnavailableView("No Songs", systemImage: "music.note.list", description: Text("Right-click a song or an album and choose Add to Playlist."))
        } else {
            Table(of: Row.self, selection: $selection) {
                TableColumn("Title") { Text($0.track.title).padding(.vertical, Stripe.padding) }
                TableColumn("Artist") { Text($0.track.artist).padding(.vertical, Stripe.padding) }
                TableColumn("Album") { Text($0.track.album).padding(.vertical, Stripe.padding) }
                TableColumn("Time") { Text($0.track.duration.time).monospacedDigit().padding(.vertical, Stripe.padding) }.width(60)
            } rows: {
                ForEach(rows) { TableRow($0).draggable(String($0.id)) }
                    .dropDestination(for: String.self) { index, ids in move(rows, ids.compactMap { Int($0) }, to: index) }
            }
            .onDeleteCommand {
                removing = rows.filter { selection.contains($0.id) }
            }
            .contextMenu(forSelectionType: Row.ID.self) { ids in
                let picked = rows.filter { ids.contains($0.id) }

                if !picked.isEmpty {
                    TrackMenu(tracks: picked.map(\.track), exclude: name)
                    Button("Remove from Playlist") { removing = picked }
                    Button("Duplicate") {
                        selection = []
                        playlists.duplicate(Set(ids), in: name)
                    }
                    Divider()

                    if picked.count == 1 {
                        GoMenu(track: picked[0].track)
                    }

                    CopyMenu(tracks: picked.map(\.track))
                    FileMenu(urls: picked.map(\.track.url))
                }
            } primaryAction: { ids in
                guard let id = ids.first, let index = rows.firstIndex(where: { $0.id == id }) else { return }

                player.play(rows.map(\.track), at: index)
            }
            .confirmationDialog(removing.count == 1 ? "Remove “\(removing[0].track.title)” from the playlist?" : "Remove \(count(removing.count, "song")) from the playlist?", isPresented: Binding { !removing.isEmpty } set: { if !$0 { removing = [] } }) {
                Button("Remove", role: .destructive) {
                    selection = []
                    playlists.remove(Set(removing.map(\.id)), from: name)
                }
            }
            .navigationSubtitle(count(rows.count, "song"))
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

struct Controls: View {
    let open: (Track) -> Void
    @Environment(Player.self) private var player
    @State private var scrub: Double?

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

            HStack(spacing: 14) {
                Button("Shuffle", systemImage: "shuffle") { player.shuffle.toggle() }
                    .foregroundStyle(player.shuffle ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Button("Previous", systemImage: "backward.fill", action: player.previous)
                Button(player.playing ? "Pause" : "Play", systemImage: player.playing ? "pause.fill" : "play.fill", action: player.toggle)
                    .font(.title)
                Button("Next", systemImage: "forward.fill", action: player.next)
                Button("Repeat", systemImage: player.repeatMode == .one ? "repeat.1" : "repeat") {
                    player.repeatMode = Player.Repeat(rawValue: (player.repeatMode.rawValue + 1) % 3)!
                }
                .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .disabled(player.current == nil)

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
            .frame(minWidth: 200, maxWidth: .infinity)
            .disabled(player.current == nil)

            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary).padding(.leading, 16)
            Slider(value: $player.volume, in: 0...1).frame(width: 90)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct ContentView: View {
    let search: Int
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(Playlists.self) private var playlists
    @State private var lyrics = Lyrics()
    @State private var depth = 0
    @State private var page = Page.section(.albums)
    @State private var name = ""
    @State private var deleting: String?
    @State private var path = NavigationPath()
    @FocusState private var searching: Bool

    var body: some View {
        @Bindable var library = library

        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: Binding<Page?> { page } set: { value in if let value { lyrics.confirm { page = value } } }) {
                    ForEach(Section.allCases) { section in
                        row(section.rawValue, section.symbol, .section(section))
                    }

                    SwiftUI.Section {
                        ForEach(playlists.names, id: \.self) { name in
                            row(name, "music.note.list", .playlist(name))
                                .contextMenu {
                                    Button("Delete Playlist") { deleting = name }
                                }
                        }
                    } header: {
                        HStack {
                            Text("Playlists")
                            Spacer()
                            Button("New Playlist", systemImage: "plus") { playlists.naming = [] }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .navigationSplitViewColumnWidth(180)
            } detail: {
                NavigationStack(path: Binding { path } set: { navigate($0) }) {
                    Group {
                        if library.folders.isEmpty {
                            ContentUnavailableView {
                                Label("No Music", systemImage: "music.note")
                            } description: {
                                Text("Add a folder with music or drop it here.")
                            } actions: {
                                Button("Add Folder…", action: library.choose)
                            }
                        } else if library.albums.isEmpty, library.scanning {
                            ProgressView()
                        } else {
                            Group {
                                switch page {
                                case .section(.albums): AlbumGrid(albums: library.filtered)
                                case .section(.artists): ArtistList(artists: library.artists)
                                case .playlist(let name): PlaylistView(name: name)
                                case .section(.songs): SongTable(tracks: library.tracks).navigationSubtitle(count(library.tracks.count, "song"))
                                }
                            }
                            .id(library.version)
                        }
                    }
                    .navigationTitle(page.title)
                    .modifier(LyricsToolbar())
                    .navigationDestination(for: Album.self) { AlbumView(album: $0).modifier(LyricsToolbar()) }
                    .navigationDestination(for: String.self) { name in
                        AlbumGrid(albums: library.albums.filter { $0.artist == name }).navigationTitle(name).modifier(LyricsToolbar())
                    }
                }
            }
            .overlay(alignment: .trailing) {
                if lyrics.visible && path.count >= depth {
                    HStack(spacing: 0) {
                        Divider()
                        LyricsView().frame(width: LyricsView.width)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
            .searchable(text: $library.query, prompt: "Ctrl+P for search")
            .searchFocused($searching)

            Divider()
            Controls { track in
                guard let album = library.albums.first(where: { $0.id == track.albumID }) else { return }
                navigate(NavigationPath([album]))
            }
            .background(.bar)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            library.add(folders)
            return !folders.isEmpty
        }
        .confirmationDialog("Save the changes to the lyrics?", isPresented: $lyrics.confirming) {
            Button("Save", action: lyrics.commit)
            Button("Discard", role: .destructive, action: lyrics.discard)
            Button("Cancel", role: .cancel, action: lyrics.cancel)
        }
        .alert("New Playlist", isPresented: Binding { playlists.naming != nil } set: { if !$0 { playlists.naming = nil } }) {
            TextField("Name", text: $name)
            Button("Create") {
                let urls = playlists.naming ?? []
                if let created = playlists.create(name, urls), urls.isEmpty { page = .playlist(created) }
                name = ""
            }
            .disabled(!playlists.valid(name))
            Button("Cancel", role: .cancel) { name = "" }
        }
        .confirmationDialog("Delete the playlist “\(deleting ?? "")”?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }) {
            Button("Delete", role: .destructive) {
                if let deleting {
                    if page == .playlist(deleting) { page = .section(.albums) }
                    playlists.delete(deleting)
                }
            }
        } message: {
            Text("The app keeps a copy as “\(deleting ?? "").backup” in the Playlists folder.")
        }
        .environment(lyrics)
        .environment(\.go, GoAction { destination in
            var value = path

            switch destination {
            case .album(let album): value.append(album)
            case .artist(let name): value.append(name)
            case .search(let text):
                lyrics.confirm {
                    page = .section(.albums)
                    library.query = text
                    path = NavigationPath()
                }
                return
            }

            navigate(value)
        })
        .onChange(of: player.current) {
            if lyrics.visible, let current = player.current { lyrics.show(current) }
        }
        .onChange(of: search) { searching = true }
        .onChange(of: page) {
            path = NavigationPath()
            if case .playlist = page { library.query = "" }
        }
        .onChange(of: lyrics.visible) {
            if lyrics.visible { depth = path.count }
        }
        .onChange(of: path) {
            if path.count < depth { lyrics.hide() }
        }
        .onChange(of: library.query) { navigate(NavigationPath()) }
        .frame(minWidth: 820, minHeight: 520)
    }

    private func row(_ title: String, _ symbol: String, _ value: Page) -> some View {
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .tag(value)
    }

    private func navigate(_ value: NavigationPath) {
        if value.count < depth {
            lyrics.confirm { path = value }
        } else {
            path = value
        }
    }
}

struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(LastFM.self) private var lastFM
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            SwiftUI.Section("Folders") {
                ForEach(library.folders, id: \.self) { folder in
                    HStack {
                        Text(folder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { library.folders.removeAll { $0 == folder } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }

                Button("Add Folder…", action: library.choose)
            }

            SwiftUI.Section {
                if LastFM.key.isEmpty {
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
                    .disabled(username.isEmpty || password.isEmpty || lastFM.connecting)
                } else {
                    LabeledContent("Account", value: lastFM.user)
                    LabeledContent("Pending Scrobbles", value: String(lastFM.pending.count))
                    Button("Disconnect", action: lastFM.disconnect)
                }

                if !lastFM.status.isEmpty {
                    Text(lastFM.status).foregroundStyle(.secondary)
                }
            } header: {
                Text("Last.fm")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}
