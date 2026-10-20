import Foundation
import Testing
@testable import Overdrive

private struct Random: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private let seeds = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Fuzz/Seeds").standardized
private let values: [UInt32] = [0, 1, 2, 4, 7, 8, 15, 16, 0x7F, 0x80, 0xFF, 0xFFFF, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFE, 0xFFFF_FFFF]

private func mutate(_ data: [UInt8], _ random: inout Random) -> [UInt8] {
    var bytes = data

    for _ in 0..<Int.random(in: 1...8, using: &random) {
        guard !bytes.isEmpty else { break }

        let index = Int.random(in: 0..<bytes.count, using: &random)

        switch Int.random(in: 0..<6, using: &random) {
        case 0:
            bytes[index] ^= UInt8(1 << Int.random(in: 0..<8, using: &random))
        case 1:
            bytes[index] = UInt8.random(in: 0...255, using: &random)
        case 2:
            let value = values.randomElement(using: &random)!.bigEndian
            withUnsafeBytes(of: value) { word in
                for (offset, byte) in word.enumerated() where index + offset < bytes.count { bytes[index + offset] = byte }
            }
        case 3:
            bytes.removeSubrange(index..<min(bytes.count, index + Int.random(in: 1...64, using: &random)))
        case 4:
            bytes.insert(contentsOf: (0..<Int.random(in: 1...16, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }, at: index)
        default:
            bytes.removeLast(Int.random(in: 0...(bytes.count - index), using: &random))
        }
    }

    return bytes
}

@MainActor
@Suite(.serialized)
struct FuzzTests {
    @Test(.timeLimit(.minutes(5)), arguments: ["mp4", "id3", "mpeg", "flac", "lrc"])
    func survivesMutatedFiles(_ format: String) throws {
        let files = try FileManager.default.contentsOfDirectory(at: seeds.appending(path: format), includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)

        let directory = FileManager.default.temporaryDirectory.appending(path: "OverdriveFuzz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var random = Random(state: 0x0D0E_0F10)

        for file in files {
            let seed = try [UInt8](Data(contentsOf: file))
            let url = directory.appending(path: "Song." + file.pathExtension)

            for _ in 0..<2000 {
                let bytes = mutate(seed, &random)

                if format == "lrc" {
                    let lines = LRC.parse(String(decoding: bytes, as: UTF8.self))
                    _ = LRC.index(at: 30, in: lines)
                    continue
                }

                try Data(bytes).write(to: url)
                _ = MP4.read(url)
                _ = ID3.read(url)
                _ = MPEG.variable(url)
                _ = Embedded.cover(url)
                _ = Picture.thumbnail(url)
                _ = FileInfo.lines(url)
            }
        }
    }
}
