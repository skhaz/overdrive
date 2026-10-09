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
    @State private var lastFM: LastFM
    @State private var player: Player
    @State private var search = 0

    init() {
        let lastFM = LastFM()
        _lastFM = State(initialValue: lastFM)
        _player = State(initialValue: Player(lastFM: lastFM))

        Task { await lastFM.flush() }
    }

    var body: some Scene {
        Window("Overdrive", id: "main") {
            ContentView(search: search)
                .environment(library)
                .environment(player)
                .modifier(Reopen(delegate: delegate))
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

            CommandGroup(after: .textEditing) {
                Button("Search") {
                    delegate.open?(id: "main")
                    search += 1
                }
                .keyboardShortcut("p", modifiers: .control)
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
