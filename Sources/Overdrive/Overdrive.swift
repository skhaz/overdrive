import SwiftUI

@main
struct Overdrive: App {
    @State private var library = Library()
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
        }
        .defaultWindowPlacement { _, context in
            let frame = context.defaultDisplay.visibleRect
            return WindowPlacement(frame.origin, size: frame.size)
        }
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan Library", action: library.scan).keyboardShortcut("r")
            }

            CommandMenu("Controls") {
                Button(player.playing ? "Pause" : "Play", action: player.toggle).keyboardShortcut(.space, modifiers: [])
                Button("Next", action: player.next).keyboardShortcut(.rightArrow)
                Button("Previous", action: player.previous).keyboardShortcut(.leftArrow)
                Divider()
                Toggle("Shuffle", isOn: $player.shuffle)
            }
        }

        Settings {
            SettingsView()
                .environment(library)
                .environment(lastFM)
        }
    }
}
