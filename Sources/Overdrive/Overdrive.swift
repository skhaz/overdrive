import SwiftUI

@main
enum Main {
    static func main() {
        guard CommandLine.arguments.count > 1, CommandLine.arguments[1] == "covers" else { return Overdrive.main() }

        Picture.serve()
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var open: OpenWindowAction?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKey = HotKey { [weak self] in self?.find() }
        Log.app.info("launched")
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { notification in
                Log.app.info("workspace", metadata: ["event": "\(notification.name.rawValue)", "volume": "\((notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path ?? "")"])
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Log.app.info("active")
    }

    func applicationDidResignActive(_ notification: Notification) {
        Log.app.info("inactive")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("quit")
        Log.flush()
    }

    func find() {
        Log.app.info("find shortcut")
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            open?(id: "main")
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .find, object: nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { open?(id: "main") }
        return true
    }
}

struct Reopen: ViewModifier {
    let delegate: Delegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { delegate.open = openWindow }
    }
}

struct Overdrive: App {
    private static let shared = {
        Log.start()
        Log.app.info("start", metadata: ["version": "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")", "macos": "\(ProcessInfo.processInfo.operatingSystemVersionString)", "pid": "\(getpid())"])
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { Log.app.info("terminate signal"); NSApp.terminate(nil) }
        termination.resume()

        let lastFM = LastFM()
        let loudness = Loudness()
        let library = Library(loudness: loudness)
        let player = Player(lastFM: lastFM, loudness: loudness)
        let youTube = YouTube(player: player)
        library.loaded = { [unowned library] complete in player.restore(complete: complete) { library.track($0) } }

        Task { await lastFM.flush() }
        AppleMusic.block()

        let rightClick = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let window = event.window, let content = window.contentView else { return event }

            let location = event.locationInWindow
            NotificationCenter.default.post(name: .rightClick, object: content.convert(location, from: nil))

            var views = [content]
            while let view = views.popLast() {
                guard let table = view as? NSTableView else {
                    views += view.subviews
                    continue
                }

                let point = table.convert(location, from: nil)
                guard table.headerView != nil, !table.isHiddenOrHasHiddenAncestor, table.visibleRect.contains(point), reachable(table, in: content) else { continue }

                let row = table.row(at: point)
                guard row >= 0 else { break }

                window.makeFirstResponder(table)
                if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
                break
            }

            return event
        }

        return (termination: termination, rightClick: rightClick, lastFM: lastFM, library: library, player: player, youTube: youTube)
    }()

    @NSApplicationDelegateAdaptor private var delegate: Delegate
    @State private var library = Overdrive.shared.library
    @State private var playlists = Playlists(directory: { Playlists.directory(in: Overdrive.shared.library.folders.first) }, folder: { Overdrive.shared.library.folders.first })
    @State private var likes = Likes(file: { Likes.file(in: Overdrive.shared.library.folders.first) }, folder: { Overdrive.shared.library.folders.first })
    @State private var lastFM = Overdrive.shared.lastFM
    @State private var player = Overdrive.shared.player
    @State private var youTube = Overdrive.shared.youTube

    var body: some Scene {
        Window("Overdrive", id: "main") {
            ContentView()
                .environment(library)
                .environment(player)
                .environment(playlists)
                .environment(likes)
                .environment(youTube)
                .modifier(Reopen(delegate: delegate))
        }
        .defaultWindowPlacement { _, context in
            let frame = context.defaultDisplay.visibleRect
            return WindowPlacement(frame.origin, size: frame.size)
        }
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Playlist…") {
                    delegate.open?(id: "main")
                    playlists.naming = []
                }
                .keyboardShortcut("n")

                Button("Sync Library") {
                    library.scan("menu")
                    playlists.load()
                    likes.load()
                }
                .keyboardShortcut("r")

                Button("Rebuild Library Cache") {
                    library.rebuild()
                    playlists.load()
                    likes.load()
                }
                .disabled(library.scanning)
            }

            CommandGroup(after: .textEditing) {
                Button("Find Song") { delegate.find() }
                    .keyboardShortcut(.space, modifiers: .option)
                Button("Clear Search") { library.query = "" }
                    .keyboardShortcut("k")
                    .disabled(library.query.isEmpty)
            }

            CommandMenu("Song") {
                SongMenu()
                    .environment(library)
                    .environment(player)
                    .environment(playlists)
                    .environment(likes)
                    .environment(youTube)
            }

            CommandMenu("Controls") {
                Button(player.playing ? "Pause" : "Play", systemImage: "playpause.fill", action: player.toggle)
                Button("Next", systemImage: "forward.fill", action: player.next)
                    .keyboardShortcut(.rightArrow)
                Button("Previous", systemImage: "backward.fill", action: player.previous)
                    .keyboardShortcut(.leftArrow)
                Divider()
                Button("Increase Volume", systemImage: "speaker.wave.3.fill") { player.volume = min(player.volume + 0.1, 1) }
                    .keyboardShortcut(.upArrow)
                Button("Decrease Volume", systemImage: "speaker.wave.1.fill") { player.volume = max(player.volume - 0.1, 0) }
                    .keyboardShortcut(.downArrow)
                Button(player.isMuted ? "Unmute" : "Mute", systemImage: player.isMuted ? "speaker.slash.fill" : "speaker.fill") { player.toggleMute() }
                    .keyboardShortcut("m")
                Divider()
                Button("Seek Forward", systemImage: "goforward.10") { player.seek(min(player.position + 10, player.duration)) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(player.current == nil)
                Button("Seek Backward", systemImage: "gobackward.10") { player.seek(max(player.position - 10, 0)) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(player.current == nil)
                Divider()
                Button("Clear Queue…", systemImage: "trash") { NotificationCenter.default.post(name: .clearQueue, object: nil) }
                    .disabled(player.queue.isEmpty)
                Button("Go to Current Song") { NotificationCenter.default.post(name: .reveal, object: nil) }
                    .keyboardShortcut("l")
                    .disabled(player.current == nil)
                Button(player.current.map(likes.contains) == true ? "Unlike Song" : "Like Song", systemImage: player.current.map(likes.contains) == true ? "heart.fill" : "heart") {
                    if let current = player.current { likes.toggle([current]) }
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(player.current == nil)
                .contentTransition(.symbolEffect(.replace))
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: player.current.map(likes.contains) ?? false)
                Button(player.lyrics ? "Hide Lyrics" : "Show Lyrics", systemImage: "quote.bubble") { player.lyrics.toggle() }
                    .keyboardShortcut("y", modifiers: [.command, .option])
                Button("Edit Lyrics", systemImage: "pencil") { NotificationCenter.default.post(name: .editLyrics, object: nil) }
                    .keyboardShortcut("e")
                    .disabled(!player.lyrics)
                Button("Show Lyrics in a Floating Window", systemImage: "macwindow") { NotificationCenter.default.post(name: .floatLyrics, object: nil) }
                    .keyboardShortcut("u")
                    .disabled(player.current == nil)
                Divider()
                Toggle("Shuffle", systemImage: "shuffle", isOn: $player.shuffle)
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Repeat: " + ["Off", "All", "One"][player.repeatMode.rawValue], systemImage: "repeat") {
                    player.repeatMode = Player.Repeat(rawValue: (player.repeatMode.rawValue + 1) % 3)!
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                Toggle("Normalize Volume", systemImage: "speaker.wave.2", isOn: $player.normalize)
            }
        }

        Settings {
            SettingsView()
                .environment(library)
                .environment(lastFM)
                .environment(youTube)
        }
    }
}
