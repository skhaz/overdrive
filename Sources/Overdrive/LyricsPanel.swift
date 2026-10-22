import AppKit
import SwiftUI

final class LyricsPanel {
    private let window: NSPanel

    init(lyrics: Lyrics, player: Player) {
        let width: CGFloat = 340
        let height: CGFloat = 380
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let visible = screen.visibleFrame

        window = NSPanel(
            contentRect: NSRect(x: visible.maxX - width - 24, y: visible.maxY - height - 24, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 280, height: 240)
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.identifier = NSUserInterfaceItemIdentifier("lyrics")
        window.contentView = NSHostingView(rootView: FloatingLyrics().environment(lyrics).environment(player))
    }

    func show() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 1.0
        }
        window.orderFrontRegardless()
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0.0
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.window.orderOut(nil)
            self.window.alphaValue = 1.0
        }
    }
}

struct FloatingLyrics: View {
    @Environment(Lyrics.self) private var lyrics
    @Environment(Player.self) private var player
    @State private var scrub: Double?
    @State private var editing = false

    var body: some View {
        let _ = player.position
        if let track = lyrics.track {
            let lines = lyrics.synced
            let live = player.current == track
            let current = live ? LRC.index(at: player.position, in: lines) : nil

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Cover(track: track).frame(width: 56)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.headline).lineLimit(2)
                        Text(track.artist).lineLimit(1)
                        Text(track.album).foregroundStyle(.secondary).lineLimit(1)
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

                        Button("Put the lyrics back in the window", systemImage: "xmark") { lyrics.floating = false }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }

                Group {
                    if !editing, !lines.isEmpty {
                        SyncedLyrics(lines: lines, current: current) { player.seek($0) }
                    } else {
                        TextEditor(text: Binding { lyrics.text } set: { lyrics.edit($0) })
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
            .onChange(of: track) { editing = false }
            .onReceive(NotificationCenter.default.publisher(for: .editLyrics)) { _ in
                if !lines.isEmpty { editing = true }
            }
        }
    }
}
