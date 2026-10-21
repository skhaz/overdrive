import AppKit
import SwiftUI

final class LyricsPanel {
    private let window: NSPanel

    init(lyrics: Lyrics, player: Player) {
        let width: CGFloat = 340
        let height: CGFloat = 560
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let visible = screen.visibleFrame

        window = NSPanel(
            contentRect: NSRect(x: visible.maxX - width - 24, y: visible.maxY - height - 24, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.identifier = NSUserInterfaceItemIdentifier("lyrics")
        window.contentView = NSHostingView(rootView: FloatingLyrics().environment(lyrics).environment(player))
    }

    func show() {
        window.orderFrontRegardless()
    }

    func hide() {
        window.orderOut(nil)
    }
}

struct FloatingLyrics: View {
    @Environment(Lyrics.self) private var lyrics
    @Environment(Player.self) private var player
    @State private var scrub: Double?

    var body: some View {
        if let track = lyrics.track {
            let lines = lyrics.synced
            let live = player.current == track
            let current = live ? LRC.index(at: player.position, in: lines) : nil

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Cover(track: track).frame(width: 56)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.headline).lineLimit(2)
                        Text(track.artist).lineLimit(1)
                        Text(track.album).foregroundStyle(.secondary).lineLimit(1)
                    }

                    Spacer()

                    Button("Put the lyrics back in the window", systemImage: "xmark") { lyrics.floating = false }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }

                Group {
                    if lyrics.loading, lyrics.text.isEmpty, lyrics.synced.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if !lines.isEmpty {
                        SyncedLyrics(lines: lines, current: current) { player.seek($0) }
                    } else {
                        ScrollView {
                            Text(lyrics.text.isEmpty ? "No lyrics." : lyrics.text)
                                .foregroundStyle(lyrics.text.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                    }
                }
                .background(Color(nsColor: NSColor.alternatingContentBackgroundColors[1]), in: RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 8) {
                    Text((scrub ?? player.position).time).monospacedDigit().foregroundStyle(.secondary).font(.caption)
                    Slider(value: Binding { scrub ?? player.position } set: { scrub = $0 }, in: 0...max(player.duration, 1)) { editing in
                        if !editing, let scrub {
                            player.seek(scrub)
                            self.scrub = nil
                        }
                    }
                    Text(player.duration.time).monospacedDigit().foregroundStyle(.secondary).font(.caption)
                }
                .disabled(player.current == nil)

                HStack {
                    Spacer()
                    Button("Previous", systemImage: "backward.fill", action: player.previous)
                    Button(player.playing ? "Pause" : "Play", systemImage: player.playing ? "pause.fill" : "play.fill", action: player.toggle)
                        .font(.title3)
                    Button("Next", systemImage: "forward.fill", action: player.next)
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .disabled(player.current == nil)
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
