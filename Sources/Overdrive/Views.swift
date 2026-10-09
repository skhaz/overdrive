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

func count(_ number: Int, _ noun: String) -> String {
    "\(number) \(noun)\(number == 1 ? "" : "s")"
}

extension Double {
    var time: String {
        guard isFinite, self > 0 else { return "0:00" }

        return Duration.seconds(self).formatted(.time(pattern: self >= 3600 ? .hourMinuteSecond : .minuteSecond))
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

struct LyricsButton: View {
    let track: Track
    @Environment(Lyrics.self) private var lyrics

    var body: some View {
        Button("Lyrics") { lyrics.show(track) }
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

    var body: some View {
        @Bindable var lyrics = lyrics

        if let track = lyrics.track {
            VStack(alignment: .leading, spacing: 8) {
                Text(track.title).font(.headline).lineLimit(2)
                Text(track.artist).foregroundStyle(.secondary).lineLimit(1)

                TextEditor(text: $lyrics.text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: NSColor.alternatingContentBackgroundColors[1]), in: RoundedRectangle(cornerRadius: 6))
                    .disabled(lyrics.loading)
                    .overlay { if lyrics.loading { ProgressView() } }

                HStack {
                    Text(lyrics.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Save", action: lyrics.save)
                        .keyboardShortcut("s")
                        .disabled(!lyrics.changed || lyrics.loading)
                }
            }
            .padding()
        } else {
            ContentUnavailableView("No Song", systemImage: "quote.bubble", description: Text("Play a song, or choose Lyrics from the menu of a song."))
        }
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

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .frame(height: Stripe.height)
            .background(index.isMultiple(of: 2) ? .clear : Color(nsColor: NSColor.alternatingContentBackgroundColors[1]), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

extension View {
    func stripe(_ index: Int) -> some View {
        modifier(Stripe(index: index))
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
                    }
                    .buttonStyle(.plain)
                    .contextMenu { FileMenu(urls: album.tracks.map(\.url)) }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 20) {
                    Cover(track: album.tracks[0]).frame(width: 220).shadow(radius: 4, y: 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.title).font(.largeTitle.bold()).lineLimit(2)
                        Text(album.artist).font(.title2).foregroundStyle(.secondary)
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
                .padding(.bottom, 20)
                .contextMenu { FileMenu(urls: album.tracks.map(\.url)) }

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
                        .stripe(index)
                        .onTapGesture(count: 2) { player.play(album.tracks, at: index) }
                        .contextMenu {
                            LyricsButton(track: track)
                            FileMenu(urls: [track.url])
                        }
                    }
                }
            }
            .padding(20)
            .padding(.trailing, lyrics.visible ? LyricsView.width : 0)
        }
        .navigationTitle(album.title)
    }
}

struct ArtistList: View {
    let artists: [(name: String, albums: [Album])]

    var body: some View {
        List(artists, id: \.name) { artist in
            NavigationLink(value: artist.name) {
                HStack {
                    Cover(track: artist.albums[0].tracks[0]).frame(width: 40)
                    Text(artist.name)
                    Spacer()
                    Text(count(artist.albums.count, "album") + " · " + count(artist.albums.reduce(0) { $0 + $1.tracks.count }, "song")).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SongTable: View {
    let tracks: [Track]
    @Environment(Player.self) private var player
    @State private var selection: Track.ID?

    var body: some View {
        Table(tracks, selection: $selection) {
            TableColumn("Title") { Text($0.title).padding(.vertical, Stripe.padding) }
            TableColumn("Artist") { Text($0.artist).padding(.vertical, Stripe.padding) }
            TableColumn("Album") { Text($0.album).padding(.vertical, Stripe.padding) }
            TableColumn("Time") { Text($0.duration.time).monospacedDigit().padding(.vertical, Stripe.padding) }.width(60)
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            if ids.count == 1, let track = tracks.first(where: { ids.contains($0.id) }) {
                LyricsButton(track: track)
            }

            FileMenu(urls: Array(ids))
        } primaryAction: { ids in
            guard let id = ids.first, let index = tracks.firstIndex(where: { $0.id == id }) else { return }

            player.play(tracks, at: index)
        }
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
                    .frame(width: 220, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

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

            HStack {
                Text((scrub ?? player.position).time).monospacedDigit().foregroundStyle(.secondary)
                Slider(value: Binding { scrub ?? player.position } set: { scrub = $0 }, in: 0...max(player.duration, 1)) { editing in
                    if !editing, let scrub {
                        player.seek(scrub)
                        self.scrub = nil
                    }
                }
                Text(player.duration.time).monospacedDigit().foregroundStyle(.secondary)
            }
            .disabled(player.current == nil)

            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
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
    @State private var lyrics = Lyrics()
    @State private var depth = 0
    @State private var section = Section.albums
    @State private var path = NavigationPath()
    @FocusState private var searching: Bool

    var body: some View {
        @Bindable var library = library

        VStack(spacing: 0) {
            NavigationSplitView {
                List(Section.allCases, selection: Binding { section } set: { value in lyrics.confirm { section = value } }) { section in
                    Label(section.rawValue, systemImage: section.symbol)
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
                                switch section {
                                case .albums: AlbumGrid(albums: library.filtered)
                                case .artists: ArtistList(artists: library.artists)
                                case .songs: SongTable(tracks: library.tracks).navigationSubtitle(count(library.tracks.count, "song"))
                                }
                            }
                            .id(library.version)
                        }
                    }
                    .navigationTitle(section.rawValue)
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
            .searchable(text: $library.query)
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
        .environment(lyrics)
        .onChange(of: player.current) {
            if lyrics.visible, let current = player.current { lyrics.show(current) }
        }
        .onChange(of: search) { searching = true }
        .onChange(of: section) { path = NavigationPath() }
        .onChange(of: lyrics.visible) {
            if lyrics.visible { depth = path.count }
        }
        .onChange(of: path) {
            if path.count < depth { lyrics.hide() }
        }
        .onChange(of: library.query) { navigate(NavigationPath()) }
        .frame(minWidth: 820, minHeight: 520)
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
