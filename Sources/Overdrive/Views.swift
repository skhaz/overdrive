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

struct Cover: View {
    let track: Track?
    @State private var image: NSImage?

    init(track: Track?) {
        self.track = track
        _image = State(initialValue: track.flatMap(Artwork.cached))
    }

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: track?.albumID) {
                image = track.flatMap(Artwork.cached)
                guard image == nil, let track else { return }

                image = await Artwork.image(track)
            }
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

    var body: some View {
        List {
            HStack(alignment: .bottom, spacing: 20) {
                Cover(track: album.tracks[0]).frame(width: 220).shadow(radius: 4, y: 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text(album.title).font(.largeTitle.bold()).lineLimit(2)
                    Text(album.artist).font(.title2).foregroundStyle(.secondary)
                    Text([album.year > 0 ? String(album.year) : nil, "\(album.tracks.count) songs", album.tracks.reduce(0) { $0 + $1.duration }.time].compactMap(\.self).joined(separator: " · "))
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Play", systemImage: "play.fill") { player.shuffle = false; player.play(album.tracks) }
                        Button("Shuffle", systemImage: "shuffle") { player.shuffle = true; player.play(album.tracks, at: .random(in: album.tracks.indices)) }
                    }
                    .controlSize(.large)
                    .padding(.top, 8)
                }
            }
            .padding(.vertical, 12)
            .listRowSeparator(.hidden)
            .contextMenu { FileMenu(urls: album.tracks.map(\.url)) }

            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
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
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { player.play(album.tracks, at: index) }
                .contextMenu { FileMenu(urls: [track.url]) }
            }
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
                    Text("\(artist.albums.count)").foregroundStyle(.secondary)
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
            TableColumn("Title", value: \.title)
            TableColumn("Artist", value: \.artist)
            TableColumn("Album", value: \.album)
            TableColumn("Time") { Text($0.duration.time).monospacedDigit() }.width(60)
        }
        .contextMenu(forSelectionType: Track.ID.self) { ids in
            FileMenu(urls: Array(ids))
        } primaryAction: { ids in
            guard let id = ids.first, let index = tracks.firstIndex(where: { $0.id == id }) else { return }

            player.play(tracks, at: index)
        }
    }
}

struct Controls: View {
    @Environment(Player.self) private var player
    @State private var scrub: Double?

    var body: some View {
        @Bindable var player = player

        HStack(spacing: 16) {
            Cover(track: player.current).frame(width: 48)

            VStack(alignment: .leading) {
                Marquee(text: player.current?.title ?? "Not Playing").bold()
                Marquee(text: player.current.map { "\($0.artist) — \($0.album)" } ?? "").foregroundStyle(.secondary)
            }
            .frame(width: 220, alignment: .leading)

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
    @Environment(Library.self) private var library
    @State private var section = Section.albums
    @State private var path = NavigationPath()

    var body: some View {
        @Bindable var library = library

        VStack(spacing: 0) {
            NavigationSplitView {
                List(Section.allCases, selection: $section) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                }
                .navigationSplitViewColumnWidth(180)
            } detail: {
                NavigationStack(path: $path) {
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
                            switch section {
                            case .albums: AlbumGrid(albums: library.filtered)
                            case .artists: ArtistList(artists: library.artists)
                            case .songs: SongTable(tracks: library.tracks)
                            }
                        }
                    }
                    .navigationTitle(section.rawValue)
                    .navigationDestination(for: Album.self) { AlbumView(album: $0) }
                    .navigationDestination(for: String.self) { name in
                        AlbumGrid(albums: library.albums.filter { $0.artist == name }).navigationTitle(name)
                    }
                }
            }
            .searchable(text: $library.query)

            Divider()
            Controls().background(.bar)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            library.add(folders)
            return !folders.isEmpty
        }
        .onChange(of: section) { path = NavigationPath() }
        .onChange(of: library.query) { path = NavigationPath() }
        .frame(minWidth: 820, minHeight: 520)
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
