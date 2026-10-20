import Foundation
import Testing
@testable import Overdrive

struct ParserTests {
    private func box(_ type: String, _ body: Data) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt32(8 + body.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array(type.utf8))
        return data + body
    }

    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        try data.write(to: url)
        return url
    }

    @Test(.timeLimit(.minutes(1))) func readsMP4WithBrokenLargeSize() throws {
        var large = Data()
        withUnsafeBytes(of: UInt32(1).bigEndian) { large.append(contentsOf: $0) }
        large.append(contentsOf: Array("free".utf8))
        withUnsafeBytes(of: UInt64(0).bigEndian) { large.append(contentsOf: $0) }

        let url = try file(box("moov", large))
        defer { try? FileManager.default.removeItem(at: url) }

        _ = MP4.read(url)
    }

    @Test(.timeLimit(.minutes(1))) func readsMP4WithHugeSizes() throws {
        var huge = Data()
        withUnsafeBytes(of: UInt32(1).bigEndian) { huge.append(contentsOf: $0) }
        huge.append(contentsOf: Array("udta".utf8))
        withUnsafeBytes(of: UInt64.max.bigEndian) { huge.append(contentsOf: $0) }

        var name = Data()
        withUnsafeBytes(of: UInt32.max.bigEndian) { name.append(contentsOf: $0) }
        name.append(contentsOf: Array("data".utf8))

        let ilst = box("ilst", box("\u{A9}nam", name))
        let meta = box("meta", Data(count: 4) + ilst)
        let url = try file(box("moov", huge + box("udta", meta)))
        defer { try? FileManager.default.removeItem(at: url) }

        _ = MP4.read(url)
    }

    @Test func appliesLyricsOffsetEarlier() {
        let lines = Lyrics.parse("[offset:+500]\n[00:10.00]Hello")
        #expect(lines == [SyncedLine(time: 9.5, text: "Hello")])
    }

    @Test func keepsBracketsInsideLyricsLines() {
        let lines = Lyrics.parse("[00:10.00]Hi [Chorus: X] there\n[00:12.00]Hello [x]")
        #expect(lines.map(\.text) == ["Hi [Chorus: X] there", "Hello [x]"])
    }
}
