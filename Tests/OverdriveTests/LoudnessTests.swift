import AVFoundation
import Foundation
import Testing
@testable import Overdrive

private struct LoudnessFailure: Error {}

@MainActor
struct LoudnessTests {
    private func wave(_ directory: URL, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appending(path: name)
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
        try audio.write(from: buffer)
        return url
    }

    @Test func savesAlbumMeasurementsFromPlayback() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OverdriveTests-\(UUID().uuidString)")
        defer { Persist.flush(); try? FileManager.default.removeItem(at: directory) }

        let first = try wave(directory, "A.wav")
        let second = try wave(directory, "B.wav")
        let tracks = [first, second].enumerated().map { index, url in
            Track(url: url, title: "Song \(index)", artist: "Artist", album: "Album", number: index + 1, disc: 1,
                  albumArtist: "Artist", year: 2020, duration: 1, albumID: directory.path + "\nAlbum")
        }

        let file = directory.appending(path: "Loudness.plist")
        let loudness = Loudness(file: file)
        loudness.albums = [tracks[0].albumID: tracks.map(\.url.path)]

        await loudness.measure(tracks[0], album: true)
        Persist.flush()

        var reloaded = Loudness(file: file)

        for _ in 0..<200 {
            if reloaded.gain(tracks[1], album: false) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
            reloaded = Loudness(file: file)
        }

        #expect(reloaded.gain(tracks[0], album: false) != nil)
        #expect(reloaded.gain(tracks[1], album: false) != nil)
    }
}
