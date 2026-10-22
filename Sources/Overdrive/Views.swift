import SwiftUI
import UniformTypeIdentifiers

enum Focus {
    case search, sidebar
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
    let tracks: [Track]
    var album: Album?
    var playlist: String?
    var remove: (() -> Void)?
    @Environment(\.active) private var active
    @Environment(\.go) private var go

    func body(content: Content) -> some View {
        content.focusedSceneValue(\.selection, active && !tracks.isEmpty ? Selection(tracks: tracks, album: album, playlist: playlist, remove: remove, go: go) : nil)
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

func count(_ number: Int, _ noun: String) -> String {
    "\(number) \(noun)\(number == 1 ? "" : "s")"
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
    @Environment(YouTube.self) private var youTube

    var body: some View {
        if !tracks.isEmpty {
            Button("Play Next") { player.insert(tracks, next: true) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Add to Queue") { player.insert(tracks, next: false) }
                .keyboardShortcut(.return, modifiers: [.command, .option])

            let liked = tracks.allSatisfy(likes.contains)
            Button((liked ? "Unlike " : "Like ") + (tracks.count == 1 ? "Song" : "Songs"), systemImage: liked ? "heart.slash" : "heart") { likes.toggle(tracks) }
                .keyboardShortcut("l", modifiers: [.command, .shift])

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
    let urls: [URL]

    var body: some View {
        if urls.count == 1 {
            Menu("Information") {
                ForEach(FileInfo.lines(urls[0]), id: \.self) { line in
                    Button(line) { copy([String(line.split(separator: ": ", maxSplits: 1).last ?? "")]) }
                }
            }
        }

        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "app.mp3tag.Mp3tag") {
            Button("Open in Mp3tag") { NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: .init()) }
        }

        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            .keyboardShortcut("r", modifiers: [.command, .shift])
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
    @State private var editing = false
    @FocusState private var typing: Bool

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
                        if !lyrics.text.isEmpty, lyrics.remote {
                            Button("Save next to the song", systemImage: "square.and.arrow.down", action: lyrics.persist)
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }
                        if !lines.isEmpty {
                            Button(editing ? "Done" : "Edit", systemImage: editing ? "checkmark" : "pencil", action: { editing.toggle() })
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }
                    }
                }

                Group {
                    if !editing, !lines.isEmpty {
                        SyncedLyrics(lines: lines, current: current) { player.seek($0) }
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
    @Environment(\.go) private var go
    @State private var selected: Album.ID?
    @State private var columns = 1
    @State private var frame = Frame()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)], spacing: 24) {
                    ForEach(albums) { album in
                        NavigationLink(value: Route.album(album)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Cover(track: album.tracks[0])
                                    .shadow(radius: 2, y: 1)
                                    .overlay {
                                        if album.id == selected {
                                            RoundedRectangle(cornerRadius: 6).stroke(.tint, lineWidth: 3)
                                        }
                                    }
                                    .onGeometryChange(for: CGRect?.self) { album.id == selected ? $0.frame(in: .global) : nil } action: { if let rect = $0 { frame.rect = rect } }
                                Text(album.title).lineLimit(1).padding(.top, 4)
                                Text(album.artist).lineLimit(1).foregroundStyle(.secondary)
                                Text(count(album.tracks.count, "song")).font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded { selected = album.id })
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
            .modifier(Keys(count: albums.count, columns: columns, selected: { albums[$0].id == selected }, select: { index in
                selected = albums[index].id
                proxy.scrollTo(albums[index].id)
            }, enter: { go(.album(albums[$0])) }, point: { _ in CGPoint(x: frame.rect.midX, y: frame.rect.midY) }))
            .modifier(Selected(tracks: albums.first { $0.id == selected }?.tracks ?? [], album: albums.first { $0.id == selected }))
            .modifier(Remember(selection: selected.map { [$0] } ?? []) { selected = $0.first })
        }
    }
}

extension Notification.Name {
    static let rightClick = Notification.Name("rightClick")
    static let key = Notification.Name("key")
    static let reveal = Notification.Name("reveal")
    static let editLyrics = Notification.Name("editLyrics")
    static let floatLyrics = Notification.Name("floatLyrics")
}

enum Key {
    case step(Step), enter, menu, delete
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
            if let table = view as? NSTableView, !table.isHiddenOrHasHiddenAncestor, table.selectedRow >= 0 { tables.append(table) } else { views += view.subviews }
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

final class Tracker {
    var position = Position()
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
            .onChange(of: active) { if active { tracker.position = position } }
    }
}

extension Player {
    func start(_ tracks: [Track], at index: Int) {
        if tracks[index] == current { toggle() } else { play(tracks, at: index) }
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

                                let now = track == youTube.showing ?? player.current
                                Text(track.title).foregroundStyle(now ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))

                                if likes.contains(track) {
                                    Image(systemName: "heart").font(.caption).foregroundStyle(now ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                }

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
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { list.rect = $0 }
                }
                .padding(20)
                .padding(.trailing, lyrics.visible && !lyrics.floating && lyrics.track.map(album.tracks.contains) == true ? LyricsView.width : 0)
            }
            .task { reveal(proxy) }
            .modifier(Keys(count: album.tracks.count, selected: { selection.contains(album.tracks[$0].id) }, select: { index in
                selection = [album.tracks[index].id]
                anchor = index
                proxy.scrollTo(index)
            }, enter: { player.start(album.tracks, at: $0) }, point: { CGPoint(x: list.rect.minX + 40, y: list.rect.minY + (CGFloat($0) + 0.5) * Stripe.height) }, extend: { index in
                selection.insert(album.tracks[index].id)
                proxy.scrollTo(index)
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
            guard let point = notification.object as? CGPoint, list.rect.contains(point) else { return }

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

struct Cell: View {
    let text: String
    let playing: Bool
    var liked = false
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .foregroundStyle(playing && prominence != .increased ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))

            if liked {
                Image(systemName: "heart").font(.caption).foregroundStyle(playing && prominence != .increased ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.vertical, Stripe.padding)
    }
}

struct SongTable: View {
    let tracks: [Track]
    @Environment(Player.self) private var player
    @Environment(YouTube.self) private var youTube
    @Environment(Likes.self) private var likes
    @State private var selection: Set<Track.ID> = []

    var body: some View {
        let now = youTube.showing ?? player.current

        ScrollViewReader { proxy in
            Table(tracks, selection: $selection) {
                TableColumn("Title") { Cell(text: $0.title, playing: $0 == now, liked: likes.contains($0)) }
                TableColumn("Artist") { Cell(text: $0.artist, playing: $0 == now) }
                TableColumn("Album") { Cell(text: $0.album, playing: $0 == now) }
                TableColumn("Time") { Cell(text: $0.duration.time, playing: $0 == now).monospacedDigit() }.width(60)
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
            .onChange(of: youTube.showing ?? player.current, initial: true) { _, track in
                if let track, tracks.contains(track) { selection = [track.id] }
            }
            .modifier(Keys(count: tracks.count, selected: { selection.contains(tracks[$0].id) }, select: { index in
                selection = [tracks[index].id]
                proxy.scrollTo(tracks[index].id)
            }, enter: { player.start(tracks, at: $0) }, extend: { index in
                selection.insert(tracks[index].id)
                proxy.scrollTo(tracks[index].id)
            }))
            .modifier(Selected(tracks: tracks.filter { selection.contains($0.id) }))

        }
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

    var body: some View {
        let rows = library.rows(playlists.paths[name] ?? [])
        let now = youTube.showing ?? player.current

        if playlists.paths[name]?.isEmpty ?? true {
            ContentUnavailableView("No Songs", systemImage: "music.note.list", description: Text("Right-click a song or an album and choose Add to Playlist."))
        } else {
            ScrollViewReader { proxy in
                Table(of: Row.self, selection: $selection) {
                    TableColumn("Title") { Cell(text: $0.track.title, playing: $0.track == now, liked: likes.contains($0.track)) }
                    TableColumn("Artist") { Cell(text: $0.track.artist, playing: $0.track == now) }
                    TableColumn("Album") { Cell(text: $0.track.album, playing: $0.track == now) }
                    TableColumn("Time") { Cell(text: $0.track.duration.time, playing: $0.track == now).monospacedDigit() }.width(60)
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
                        .keyboardShortcut(.delete)
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
                }, delete: { removing = rows.filter { selection.contains($0.id) } }))
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

    var body: some View {
        let rows = library.rows(likes.paths)
        let now = youTube.showing ?? player.current

        if likes.paths.isEmpty {
            ContentUnavailableView("No Liked Songs", systemImage: "heart", description: Text("Right-click a song and choose Like Song, or click the heart next to the song that plays."))
        } else {
            ScrollViewReader { proxy in
                Table(of: Row.self, selection: $selection) {
                    TableColumn("Title") { Cell(text: $0.track.title, playing: $0.track == now) }
                    TableColumn("Artist") { Cell(text: $0.track.artist, playing: $0.track == now) }
                    TableColumn("Album") { Cell(text: $0.track.album, playing: $0.track == now) }
                    TableColumn("Time") { Cell(text: $0.track.duration.time, playing: $0.track == now).monospacedDigit() }.width(60)
                } rows: {
                    ForEach(rows) { TableRow($0) }
                }
                .contextMenu(forSelectionType: Row.ID.self) { ids in
                    let picked = rows.filter { ids.contains($0.id) }

                    if !picked.isEmpty {
                        TrackMenu(tracks: picked.map(\.track))

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
                }))
                .modifier(Selected(tracks: rows.filter { selection.contains($0.id) }.map(\.track)))

            }
        }
    }
}

struct Controls: View {
    let open: (Track) -> Void
    @Environment(Player.self) private var player
    @Environment(Likes.self) private var likes
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
    @Environment(YouTube.self) private var youTube
    @State private var lyrics = Lyrics(cache: Lyrics.directory(in: nil))
    @State private var navigation = Navigation(page: Page(key: Player.saved?.page ?? "") ?? .section(.albums))
    @State private var tracker = Tracker()
    @State private var name = ""
    @State private var deleting: String?
    @State private var saved = Player.saved?.path
    @State private var monitor: Any?
    @State private var swipe: CGFloat = 0
    @State private var navigator = Navigator()
    @State private var search = ""
    @State private var panel: LyricsPanel?
    @FocusState private var focus: Focus?

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: Binding<Page?> { page } set: { value in if let value { lyrics.settle { navigation.open(value, leaving: tracker.position) } } }) {
                    ForEach(Section.allCases) { section in
                        row(section.rawValue, section.symbol, .section(section))
                    }

                    row("Liked Songs", "heart", .liked)

                    SwiftUI.Section {
                        ForEach(playlists.names, id: \.self) { name in
                            row(name, "music.note.list", .playlist(name))
                                .contextMenu {
                                    Button("Delete Playlist") { deleting = name }
                                        .keyboardShortcut(.delete, modifiers: [])
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
                        }
                    } else if library.albums.isEmpty, library.scanning {
                        ProgressView()
                    } else {
                        ZStack {
                            ForEach(navigation.pages, id: \.self) { page in
                                stack(page)
                                    .opacity(page == self.page ? 1 : 0)
                                    .allowsHitTesting(page == self.page)
                                    .accessibilityHidden(page != self.page)
                            }
                        }
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
            .overlay(alignment: .trailing) {
                if shown(path, page), !lyrics.floating {
                    HStack(spacing: 0) {
                        Divider()
                        LyricsView().frame(width: LyricsView.width)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("Back", systemImage: "chevron.backward", action: goBack)
                        .keyboardShortcut("[")
                        .disabled(navigation.back.isEmpty)
                    Button("Forward", systemImage: "chevron.forward", action: goForward)
                        .keyboardShortcut("]")
                        .disabled(navigation.forward.isEmpty)
                }
            }
            .searchable(text: $search, placement: .toolbarPrincipal)
            .searchFocused($focus, equals: .search)
            .task(id: search) {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                await MainActor.run { library.query = search }
            }

            Divider()
            Controls(open: reveal)
            .background(.bar)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            library.add(folders)
            return !folders.isEmpty
        }
        .alert("New Playlist", isPresented: Binding { playlists.naming != nil } set: { if !$0 { playlists.naming = nil } }) {
            TextField("Name", text: $name)
            Button("Create") {
                let urls = playlists.naming ?? []
                if let created = playlists.create(name, urls), urls.isEmpty { navigation.open(.playlist(created), leaving: tracker.position) }
                name = ""
            }
            .disabled(!playlists.valid(name))
            Button("Cancel", role: .cancel) { name = "" }
        }
        .confirmationDialog("Delete the playlist “\(deleting ?? "")”?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }) {
            Button("Delete", role: .destructive) {
                if let deleting {
                    navigation.remove(.playlist(deleting), fallback: .section(.albums))
                    playlists.delete(deleting)
                }
            }
        } message: {
            Text("The app keeps a copy as “\(deleting ?? "").backup.plist” in the Playlists folder.")
        }
        .environment(lyrics)
        .environment(\.go, GoAction { destination in
            var value = path

            switch destination {
            case .album(let album): value.append(.album(album))
            case .artist(let name): value.append(.artist(name))
            case .search(let text):
                lyrics.settle {
                    navigation.open(.section(.albums), leaving: tracker.position)
                    library.query = text
                }
                return
            }

            navigate(value)
        })
        .onReceive(NotificationCenter.default.publisher(for: .reveal)) { _ in
            if let current = player.current { reveal(current) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatLyrics)) { _ in
            if let current = player.current {
                lyrics.show(current)
                lyrics.floating = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            lyrics.flush()
        }
        .onChange(of: player.current) {
            if let current = player.current { lyrics.show(current) }
        }
        .onAppear {
            navigator.available = { (!navigation.back.isEmpty, !navigation.forward.isEmpty) }
            navigator.progress = { swipe = $0 }
            navigator.go = { $0 ? goBack() : goForward() }
            focus = .search
            search = library.query
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { press($0) ? nil : $0 }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        .onChange(of: library.version) {
            navigation.refresh(library.albums)
            guard let saved, !library.albums.isEmpty else { return }

            self.saved = nil
            navigation.restore(saved.compactMap { Route(key: $0, albums: library.albums) })
        }
        .onChange(of: library.folders) {
            lyrics = Lyrics(cache: Lyrics.directory(in: library.folders.first))
        }
        .onChange(of: lyrics.floating) {
            if lyrics.floating {
                let panel = self.panel ?? LyricsPanel(lyrics: lyrics, player: player)
                self.panel = panel
                panel.show()
            } else {
                panel?.hide()
            }
        }
        .onChange(of: navigation.place) {
            tracker.position = navigation.place.position
            remember()
        }
        .onChange(of: library.query, initial: true) {
            if search != library.query { search = library.query }
        }
        .onChange(of: library.query) {
            navigate([])
            remember()
        }
        .environment(\.tracker, tracker)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(minWidth: 820, minHeight: 520)
    }

    private func row(_ title: String, _ symbol: String, _ value: Page) -> some View {
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .tag(value)
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
        switch (path.last, page) {
        case (.album, _): ""
        case (.artist(let name), _): summary(library.albums.filter { $0.artist == name })
        case (nil, .section(.albums)): summary(library.filtered)
        case (nil, .section(.artists)): summary(library.artists.flatMap(\.albums))
        case (nil, .section(.songs)): summary(library.tracks)
        case (nil, .playlist(let name)): summary(library.rows(playlists.paths[name] ?? []).map(\.track))
        case (nil, .liked): summary(library.rows(likes.paths).map(\.track))
        }
    }

    private func stack(_ page: Page) -> some View {
        let current = page == self.page
        let path = navigation.path(of: page)

        return NavigationStack(path: Binding { navigation.path(of: page) } set: { if current { navigate($0) } }) {
            Group {
                switch page {
                case .section(.albums): AlbumGrid(albums: library.filtered)
                case .section(.artists): ArtistList(artists: library.artists)
                case .playlist(let name): PlaylistView(name: name)
                case .liked: LikedView()
                case .section(.songs): SongTable(tracks: library.tracks)
                }
            }
            .environment(\.active, current && path.isEmpty)
            .environment(\.restore, current && path.isEmpty ? navigation.place.position : Position())
            .id(library.query)
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .navigationDestination(for: Route.self) { route in
                Group {
                    switch route {
                    case .album(let album): AlbumView(album: album)
                    case .artist(let name): AlbumGrid(albums: library.albums.filter { $0.artist == name })
                    }
                }
                .environment(\.active, current && path.last == route)
                .environment(\.restore, current && path.last == route ? navigation.place.position : Position())
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .navigationBarBackButtonHidden()
            }
        }
    }

    private func goBack() {
        lyrics.settle {
            if !navigation.goBack(leaving: tracker.position) {
                navigation.show(Array(path.dropLast()), leaving: tracker.position)
            }
        }
    }

    private func goForward() {
        lyrics.settle { navigation.goForward(leaving: tracker.position) }
    }

    private func press(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.isKeyWindow, window.identifier?.rawValue.hasPrefix("main") == true, window.attachedSheet == nil,
              playlists.naming == nil, deleting == nil else { return false }

        let sidebar = focus == .sidebar
        guard sidebar || focus == .search || !(window.firstResponder is NSText) else {
            guard event.keyCode == 53, event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else { return false }

            focus = .search
            return true
        }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command, event.keyCode == 3 {
            focus = .search
            return true
        }

        if flags == .control, event.keyCode == 36 || event.keyCode == 76 {
            if sidebar { showMenu(in: window.firstResponder as? NSTableView) } else { NotificationCenter.default.post(name: .key, object: Key.menu) }
            return true
        }

        guard flags.isDisjoint(with: [.command, .option, .control]) else { return false }

        if event.keyCode == 53, youTube.showing != nil {
            youTube.close()
            return true
        }

        if !(window.firstResponder is NSText), let characters = event.characters, characters.count == 1, let character = characters.first, character.isLetter || character.isNumber {
            focus = .search
            search.append(character)
            return true
        }

        let typing = focus == .search && !search.isEmpty
        let key: Key
        switch (event.keyCode, sidebar) {
        case (48, false):
            focus = .sidebar
            return true
        case (48, true), (36, true), (76, true):
            focus = .search
            return true
        case (126, _): key = .step(flags == .shift ? .extendUp : .up)
        case (125, _): key = .step(flags == .shift ? .extendDown : .down)
        case (123, _) where !typing: key = .step(.left)
        case (124, _) where !typing: key = .step(.right)
        case (36, false), (76, false): key = .enter
        case (51, false) where !typing: key = .delete
        case (49, false) where !typing:
            player.toggle()
            return true
        case (53, false) where !path.isEmpty:
            goBack()
            return true
        default: return false
        }

        NotificationCenter.default.post(name: .key, object: key)
        return true
    }

    private func reveal(_ track: Track) {
        guard let album = library.albums.first(where: { $0.id == track.albumID }) else { return }
        navigate([.album(album)])
    }

    private func remember() {
        player.view = (page.key, path.map(\.key), library.query)
        player.save()
    }

    private func navigate(_ value: [Route]) {
        if shown(path, page), !shown(value, page) {
            lyrics.settle { navigation.show(value, leaving: tracker.position) }
        } else {
            navigation.show(value, leaving: tracker.position)
        }
    }

    private func shown(_ path: [Route], _ page: Page) -> Bool {
        guard lyrics.visible, let track = lyrics.track else { return false }

        switch (path.last, page) {
        case (.album(let album), _): return album.tracks.contains(track)
        case (.artist, _): return false
        case (nil, .section(.songs)): return library.tracks.contains(track)
        case (nil, .playlist(let name)): return playlists.paths[name]?.contains(track.url.path) ?? false
        case (nil, .liked): return likes.contains(track)
        case (nil, .section): return false
        }
    }
}

struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(LastFM.self) private var lastFM
    @Environment(YouTube.self) private var youTube
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        @Bindable var youTube = youTube

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
                    if !lastFM.rejected.isEmpty { LabeledContent("Rejected by Last.fm", value: String(lastFM.rejected.count)) }
                    Button("Disconnect", action: lastFM.disconnect)
                }

                if !lastFM.status.isEmpty {
                    Text(lastFM.status).foregroundStyle(.secondary)
                }
            } header: {
                Text("Last.fm")
            }

            SwiftUI.Section {
                Button("Sign Out") { Task { await youTube.signOut() } }
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
