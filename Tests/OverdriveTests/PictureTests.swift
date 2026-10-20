import Foundation
import Testing
@testable import Overdrive

struct PictureTests {
    private func file(_ data: Data, _ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "OverdriveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Song" + name)
        try data.write(to: url)
        return url
    }

    @Test func ignoresFLACPictureWithBrokenLengths() throws {
        var block = Data(count: 4)
        withUnsafeBytes(of: UInt32.max.bigEndian) { block.append(contentsOf: $0) }
        block.append(Data(count: 8))

        var data = Data("fLaC".utf8)
        data.append(contentsOf: [0x86, 0, 0, UInt8(block.count)])
        data.append(block)

        let url = try file(data, ".flac")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(Picture.thumbnail(url) == nil)
    }

    @Test func ignoresEmptyAPICFrameAtTheEnd() throws {
        var tag = Data("APIC".utf8)
        tag.append(contentsOf: [0, 0, 0, 0, 0, 0])

        var data = Data("ID3".utf8)
        data.append(contentsOf: [3, 0, 0, 0, 0, 0, UInt8(tag.count)])
        data.append(tag)

        let url = try file(data, ".mp3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(Picture.thumbnail(url) == nil)
    }

    @Test func ignoresID3ExtendedHeaderThatIsTooShort() throws {
        let fixture = Bundle.module.resourceURL!.appending(path: "Fixtures/id3-extended-header.mp3")
        let url = try file(Data(contentsOf: fixture), ".mp3")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = Embedded.cover(url)
        _ = ID3.read(url)
    }
}
