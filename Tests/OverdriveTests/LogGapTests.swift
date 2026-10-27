import Foundation
import Testing
@testable import Overdrive

struct LogGapTests {
    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }

    @Test func aDiskWithoutFullSyncStillSaves() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "Durable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = open(url.path, O_WRONLY | O_CREAT, 0o600)
        defer { close(file) }

        #expect(Persist.durable(file) { _ in errno = ENOTSUP; return -1 }, "a network disk without F_FULLFSYNC falls back to fsync")
        #expect(Persist.durable(file) { _ in errno = EINVAL; return -1 })
        #expect(!Persist.durable(file) { _ in errno = EIO; return -1 }, "a real disk error still fails the write")
        #expect(Persist.durable(file) { _ in 0 })
    }

    @Test func aSignInURLKeepsNoSecrets() {
        let url = URL(string: "https://accounts.google.com/signin/v2?continue=https%3A%2F%2Fyoutube.com&state=SECRET&token=abc")!
        #expect(YouTube.redact(url) == "https://accounts.google.com/signin/v2", "a sign-in URL can carry tokens; only the host and the path go to the log")
        #expect(YouTube.redact(nil) == "")
    }

    @Test func everyGapLogs() throws {
        let events: [String: [String]] = [
            "Player.swift": ["play to end failed", "stalled", "item error log", "time control", "seek done", "remote ignored", "resume ignored", "begin ignored", "now playing", "volume"],
            "Output.swift": ["output device"],
            "YouTube.swift": ["search failed", "play failed", "stop video failed", "signed out"],
            "Overdrive.swift": ["window"],
            "LastFM.swift": ["network", "history invalid", "top artists", "top tracks", "love", "love dropped", "love retry", "http failed", "loved page", "loved invalid"],
            "Library.swift": ["unreadable attributes", "walk error"],
            "Loudness.swift": ["buffer failed", "file unreadable"],
            "Views.swift": ["editing", "copy", "played without album", "float ignored"],
            "Persist.swift": ["folder failed", "full sync unsupported", "encode failed"],
            "Lyrics.swift": ["refresh ignored"],
            "Picture.swift": ["covers input failed"],
        ]
        for (file, names) in events {
            let text = try source(file)
            for name in names {
                #expect(text.contains("\"\(name)\", metadata") || text.contains("(\"\(name)\")"), "\(file) must log \(name)")
            }
        }
        #expect(!(try source("YouTube.swift")).contains("\"url\": \"\\(webView.url?.absoluteString"), "the full page URL never goes to the log")
    }

    @Test func thePlaybackStateLogsOnlyChanges() throws {
        let player = try source("Player.swift")
        #expect(player.contains("guard changed else { return }\n\n            Log.player.info(\"time control\""), "AVFoundation repeats the same state; only a change goes to the log")
    }
}
