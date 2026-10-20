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
    @NSApplicationDelegateAdaptor private var delegate: Delegate
    @State private var library = Library()
    @State private var playlists = Playlists()
    @State private var lastFM: LastFM
    @State private var player: Player

    init() {
        let lastFM = LastFM()
        _lastFM = State(initialValue: lastFM)
        _player = State(initialValue: Player(lastFM: lastFM))

        Task { await lastFM.flush() }
    }

    var body: some Scene {
        Window("Overdrive", id: "main") {
            ContentView()
                .environment(library)
                .environment(player)
                .environment(playlists)
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
            }
        }

        Settings {
            SettingsView()
                .environment(library)
                .environment(lastFM)
        }
    }
}
