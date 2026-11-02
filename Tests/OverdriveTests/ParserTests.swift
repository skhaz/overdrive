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

    private func atom(_ type: [UInt8], _ body: Data) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt32(8 + body.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: type)
        return data + body
    }

    private func dataAtom(_ value: Data, type: UInt32 = 1) -> Data {
        var body = Data()
        withUnsafeBytes(of: type.bigEndian) { body.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0).bigEndian) { body.append(contentsOf: $0) }
        body.append(value)
        return box("data", body)
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
        let lines = LRC.parse("[offset:+500]\n[00:10.00]Hello")
        #expect(lines == [SyncedLine(time: 9.5, text: "Hello")])
    }

    @Test func keepsBracketsInsideLyricsLines() {
        let lines = LRC.parse("[00:10.00]Hi [Chorus: X] there\n[00:12.00]Hello [x]")
        #expect(lines.map(\.text) == ["Hi [Chorus: X] there", "Hello [x]"])
    }

    @Test func readsTheMP4CustomGenre() throws {
        let gen = atom([0xA9, 0x67, 0x65, 0x6E], dataAtom(Data("Indie Rock".utf8)))
        let ilst = box("ilst", gen)
        let meta = box("meta", Data(count: 4) + ilst)
        let url = try file(box("moov", box("udta", meta)))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MP4.read(url)?.genre == "Indie Rock")
    }

    @Test func readsTheMP4NumberedGenre() throws {
        let gnre = atom([0x67, 0x6E, 0x72, 0x65], dataAtom(Data([0, 17]), type: 0))
        let ilst = box("ilst", gnre)
        let meta = box("meta", Data(count: 4) + ilst)
        let url = try file(box("moov", box("udta", meta)))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MP4.read(url)?.genre == "Rock")
    }

    @Test func theCustomGenreWinsOverTheNumber() throws {
        let gen = atom([0xA9, 0x67, 0x65, 0x6E], dataAtom(Data("Jazz".utf8)))
        let gnre = atom([0x67, 0x6E, 0x72, 0x65], dataAtom(Data([0, 17]), type: 0))
        let ilst = box("ilst", gnre + gen)
        let meta = box("meta", Data(count: 4) + ilst)
        let url = try file(box("moov", box("udta", meta)))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(MP4.read(url)?.genre == "Jazz")
    }

    @Test func readsTheID3Genre() throws {
        let body = Data([0]) + Data("(17)Rock".utf8)

        var frame = Data("TCON".utf8)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: [0, 0]) // flags
        frame.append(body)

        var header = Data("ID3".utf8)
        header.append(3) // version 2.3
        header.append(0) // revision
        header.append(0) // flags
        header.append(contentsOf: [0, 0, 0, UInt8(frame.count)]) // syncsafe size
        header.append(frame)

        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try header.write(to: url)

        #expect(ID3.read(url).genre == "Rock")
    }
}
