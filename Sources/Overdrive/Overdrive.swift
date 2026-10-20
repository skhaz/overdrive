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
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()

        let lastFM = LastFM()
        let loudness = Loudness()
        let library = Library(loudness: loudness)
        let player = Player(lastFM: lastFM, loudness: loudness)
        let youTube = YouTube(player: player)
        library.loaded = { [unowned library] in player.restore { library.track($0) } }

        Task { await lastFM.flush() }
        AppleMusic.block()

        return (termination: termination, lastFM: lastFM, library: library, player: player, youTube: youTube)
    }()

    @NSApplicationDelegateAdaptor private var delegate: Delegate
    @State private var library = Overdrive.shared.library
    @State private var playlists = Playlists()
    @State private var lastFM = Overdrive.shared.lastFM
    @State private var player = Overdrive.shared.player
    @State private var youTube = Overdrive.shared.youTube

    var body: some Scene {
        Window("Overdrive", id: "main") {
            ContentView()
                .environment(library)
                .environment(player)
                .environment(playlists)
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

                Button("Rescan Library") {
                    library.scan()
                    playlists.load()
                }
                .keyboardShortcut("r")
            }

            CommandMenu("Controls") {
                Button(player.playing ? "Pause" : "Play", systemImage: "playpause.fill", action: player.toggle)
                Button("Next", systemImage: "forward.fill", action: player.next)
                Button("Previous", systemImage: "backward.fill", action: player.previous)
                Divider()
                Toggle("Shuffle", systemImage: "shuffle", isOn: $player.shuffle)
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
