import AVFoundation
import Foundation
import Testing
@testable import Overdrive

private struct LoudnessFailure: Error {}
private let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")

@MainActor
struct LoudnessTests {
    private func wave(_ directory: URL, _ name: String, seconds: Int = 1) throws -> URL {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8000,
            AVNumberOfChannelsKey: 1,
        ]
        let audio = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 8000) else {
            throw LoudnessFailure()
        }
        buffer.frameLength = 8000
        for _ in 0..<seconds { try audio.write(from: buffer) }
        return url
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OverdriveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return URL(filePath: url.path.withCString { String(cString: realpath($0, nil)) })
    }

    private func tracks(_ urls: [URL], in folder: URL) -> [Track] {
        urls.enumerated().map { index, url in
            Track(url: url, title: "Song \(index)", artist: "Artist", album: "Album", number: index + 1, disc: 1,
                  albumArtist: "Artist", year: 2020, duration: 1, albumID: folder.path + "\nAlbum")
        }
    }

    private func measured(_ track: Track, in folders: [URL]) async throws -> Bool {
        for _ in 0..<200 {
            if Loudness(folders: folders).gain(track, album: false) != nil { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func savesAlbumMeasurementsFromPlayback() async throws {
        let directory = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let tracks = tracks([try wave(directory, "Album/A.wav"), try wave(directory, "Album/B.wav")], in: directory)
        let loudness = Loudness(folders: [directory])
        loudness.albums = [tracks[0].albumID: tracks.map(\.url.path)]

        await loudness.measure(tracks[0], album: true)
        Persist.flush()

        #expect(try await measured(tracks[0], in: [directory]))
        #expect(try await measured(tracks[1], in: [directory]))
    }

    @Test func keepsTheMeasurementsInTheMusicFolderWithRelativePaths() async throws {
        let directory = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let track = tracks([try wave(directory, "Album/A.wav")], in: directory)[0]
        await Loudness(folders: [directory]).measure(track, album: false)
        Persist.flush()

        let data = try Data(contentsOf: directory.appending(path: Loudness.name))
        let stored = try PropertyListDecoder().decode([String: Loudness.Entry].self, from: data)
        #expect(Array(stored.keys) == ["Album/A.wav"])
    }

    @Test func keepsTheMeasurementsWhenTheMusicFolderMoves() async throws {
        let directory = try folder()
        let moved = directory.deletingLastPathComponent().appending(path: directory.lastPathComponent + "-moved")
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: moved) }

        let track = tracks([try wave(directory, "Album/A.wav")], in: directory)[0]
        await Loudness(folders: [directory]).measure(track, album: false)
        Persist.flush()
        try FileManager.default.moveItem(at: directory, to: moved)

        let relocated = tracks([moved.appending(path: "Album/A.wav")], in: moved)[0]
        #expect(Loudness(folders: [moved]).gain(relocated, album: false) != nil)
    }

    @Test func savesEachMeasurementInItsOwnMusicFolder() async throws {
        let one = try folder()
        let two = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: one); try? FileManager.default.removeItem(at: two) }

        let first = tracks([try wave(one, "A.wav")], in: one)[0]
        let second = tracks([try wave(two, "B.wav")], in: two)[0]
        let loudness = Loudness(folders: [one, two])
        await loudness.measure(first, album: false)
        await loudness.measure(second, album: false)
        Persist.flush()

        #expect(Loudness(folders: [one]).gain(first, album: false) != nil)
        #expect(Loudness(folders: [one]).gain(second, album: false) == nil)
        #expect(Loudness(folders: [two]).gain(second, album: false) != nil)
    }

    @Test func measuresASongWhoseHeaderPromisesMoreFrames() async throws {
        let directory = try folder()
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "Album/A.mp3")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appending(path: "vbr-truncated.mp3"), to: url)
        let track = tracks([url], in: directory)[0]

        let loudness = Loudness(folders: [directory])
        await loudness.measure(track, album: false)
        #expect(loudness.gain(track, album: false) != nil)

        loudness.update([Album(id: track.albumID, title: "Album", artist: "Artist", year: 2020, tracks: [track])])
        #expect(try await measured(track, in: [directory]))
    }
}
