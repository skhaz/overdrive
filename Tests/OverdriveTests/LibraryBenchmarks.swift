import AVFoundation
import Foundation
import Testing
@testable import Overdrive

@Suite(.enabled(if: ProcessInfo.processInfo.environment["OVERDRIVE_BENCH"] != nil), .serialized)
struct LibraryBenchmarks {
    private let folder = URL(filePath: ProcessInfo.processInfo.environment["OVERDRIVE_BENCH"] ?? "/")

    @Test func loadsTheLibrary() async {
        let clock = ContinuousClock()
        var covers: [String: Data] = [:]

        for run in 1...3 {
            let start = clock.now
            let result = await Library.load([folder], [:])
            print("BENCH full run=\(run) albums=\(result.albums.count) tracks=\(result.albums.reduce(0) { $0 + $1.tracks.count }) time=\(clock.now - start)")
            covers = result.covers
        }

        for run in 1...3 {
            let start = clock.now
            _ = await Library.load([folder], covers)
            print("BENCH without covers run=\(run) time=\(clock.now - start)")
        }
    }

    @Test func walksTheFolder() {
        let clock = ContinuousClock()
        let types = AVURLAsset.audiovisualContentTypes.filter { $0.conforms(to: .audio) }

        for run in 1...3 {
            let start = clock.now
            var count = 0
            let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentTypeKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])!
            while let url = enumerator.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .contentModificationDateKey, .fileSizeKey]), let type = values.contentType, types.contains(where: type.conforms) else { continue }
                count += 1
            }
            print("BENCH walk run=\(run) files=\(count) time=\(clock.now - start)")
        }
    }
}
