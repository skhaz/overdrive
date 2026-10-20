import Foundation
import Testing
@testable import Overdrive

private let fixtures = Bundle.module.resourceURL!.appending(path: "Fixtures")

private func header(_ index: UInt8, mpeg1: Bool = true, mono: Bool = false, frequency: UInt8 = 0, padding: Bool = false) -> [UInt8] {
    [0xFF, mpeg1 ? 0xFB : 0xF3, index << 4 | frequency << 2 | (padding ? 2 : 0), mono ? 0xC0 : 0x40]
}

private func frame(_ index: UInt8, mpeg1: Bool = true, mono: Bool = false, frequency: UInt8 = 0) -> [UInt8] {
    let bytes = header(index, mpeg1: mpeg1, mono: mono, frequency: frequency)
    var data = [UInt8](repeating: 0, count: MPEG.frame(UnsafeRawBufferPointer(start: bytes, count: 4), 0)!.length)
    data.replaceSubrange(0..<4, with: bytes)
    return data
}

private func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }

private func be(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }

private func tagged(_ id: String, flags: UInt32 = 0x0F, frames: UInt32 = 100, size: UInt32 = 41_800, encoder: String? = nil, method: UInt8 = 0, index: UInt8 = 9, mpeg1: Bool = true, mono: Bool = false) -> [UInt8] {
    var data = frame(index, mpeg1: mpeg1, mono: mono)
    var payload = ascii(id) + be(flags)
    if flags & 1 != 0 { payload += be(frames) }
    if flags & 2 != 0 { payload += be(size) }
    if flags & 4 != 0 { payload += [UInt8](repeating: 0, count: 100) }
    if flags & 8 != 0 { payload += be(50) }
    if let encoder { payload += ascii(encoder).prefix(9) + [UInt8](repeating: 0x20, count: max(0, 9 - encoder.utf8.count)) + [method] }
    let offset = 4 + (mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17))
    data.replaceSubrange(offset..<offset + payload.count, with: payload)
    return data
}

private func stream(_ indexes: [UInt8], mpeg1: Bool = true, mono: Bool = false) -> [UInt8] {
    indexes.flatMap { frame($0, mpeg1: mpeg1, mono: mono) }
}

private func variable(_ bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBytes { MPEG.variable($0) }
}

private func id3(_ size: Int, footer: Bool = false) -> [UInt8] {
    let s = UInt32(size)
    return ascii("ID3") + [4, 0, footer ? 0x10 : 0] + [UInt8(s >> 21 & 0x7F), UInt8(s >> 14 & 0x7F), UInt8(s >> 7 & 0x7F), UInt8(s & 0x7F)]
        + [UInt8](repeating: 0, count: size) + (footer ? ascii("3DI") + [4, 0, 0x10, 0, 0, 0, 0] : [])
}

private func write(_ bytes: [UInt8]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp3")
    try Data(bytes).write(to: url)
    return url
}

private let real: [(String, Bool)] = [
    ("cbr", false), ("cbr-320", false), ("cbr-mono", false), ("cbr-mpeg2", false), ("cbr-mpeg25", false), ("cbr-bare", false),
    ("vbr", true), ("abr", true), ("vbr-mono", true), ("vbr-mpeg2", true), ("vbr-mpeg25", true), ("vbr-bare", true),
]

@Test(arguments: real) func encoded(_ name: String, _ expected: Bool) {
    #expect(MPEG.variable(fixtures.appending(path: "\(name).mp3")) == expected)
}

@MainActor @Test(arguments: real) func information(_ name: String, _ expected: Bool) {
    let line = FileInfo.lines(fixtures.appending(path: "\(name).mp3")).first { $0.hasPrefix("Bit Rate:") }
    #expect(line?.hasSuffix(" kbps (VBR)") == expected)
    #expect(line?.hasSuffix(" kbps") == !expected)
}

@Test(arguments: real) func largeTag(_ name: String, _ expected: Bool) throws {
    let data = try Data(contentsOf: fixtures.appending(path: "\(name).mp3"))
    let url = try write(id3(3 << 20) + Array(data))
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(MPEG.variable(url) == expected)
}

@Test(arguments: real) func footerTag(_ name: String, _ expected: Bool) throws {
    let data = try Data(contentsOf: fixtures.appending(path: "\(name).mp3"))
    let url = try write(id3(64, footer: true) + Array(data))
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(MPEG.variable(url) == expected)
}

@Test(arguments: real) func junk(_ name: String, _ expected: Bool) throws {
    let data = try Data(contentsOf: fixtures.appending(path: "\(name).mp3"))
    let url = try write([0xFF, 0xFB, 0x90, 0x44, 0x00, 0xFF, 0xE0, 0x12] + Array(data))
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(MPEG.variable(url) == expected)
}

@Test func missing() {
    #expect(!MPEG.variable(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mp3")))
}

@Test func empty() {
    #expect(!variable([]))
}

@Test func garbage() {
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<200 {
        let bytes = (0..<Int.random(in: 0..<4096, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        _ = variable(bytes)
    }
}

@Test func layerTwo() {
    let bytes = (0..<20).flatMap { i -> [UInt8] in
        var data = [UInt8](repeating: 0, count: 417)
        data.replaceSubrange(0..<4, with: [0xFF, 0xFD, (i % 2 == 0 ? 9 : 10) << 4, 0x40])
        return data
    }
    #expect(!variable(bytes))
}

@Test func reservedFields() {
    #expect(!variable([0xFF, 0xEB, 0x90, 0x40] + [UInt8](repeating: 0, count: 500)))
    #expect(!variable([0xFF, 0xFB, 0xF0, 0x40] + [UInt8](repeating: 0, count: 500)))
    #expect(!variable([0xFF, 0xFB, 0x0C, 0x40] + [UInt8](repeating: 0, count: 500)))
}

@Test(arguments: [(UInt8(1), false), (8, false), (2, true), (3, true), (4, true), (5, true), (6, true), (9, true)])
func lameMethod(_ method: UInt8, _ expected: Bool) {
    #expect(variable(tagged("Xing", encoder: "LAME3.100", method: method) + stream(Array(repeating: 9, count: 20))) == expected)
    #expect(variable(tagged("Info", encoder: "LAME3.100", method: method) + stream(Array(repeating: 9, count: 20))) == expected)
    #expect(variable(tagged("Xing", encoder: "L3.99r", method: method) + stream(Array(repeating: 9, count: 20))) == expected)
}

@Test func lameRevision() {
    #expect(!variable(tagged("Xing", encoder: "LAME3.99r", method: 0x11) + stream(Array(repeating: 9, count: 20))))
    #expect(variable(tagged("Info", encoder: "LAME3.99r", method: 0x13) + stream(Array(repeating: 9, count: 20))))
}

@Test(arguments: [UInt8(0), 7, 10, 15])
func lameUnknownMethod(_ method: UInt8) {
    #expect(variable(tagged("Xing", flags: 0x07, encoder: "LAME3.100", method: method) + stream(Array(repeating: 9, count: 20))))
    #expect(!variable(tagged("Info", flags: 0x07, encoder: "LAME3.100", method: method) + stream(Array(repeating: 9, count: 20))))
}

@Test func otherEncoder() {
    #expect(!variable(tagged("Xing", flags: 0x07, encoder: "Lavc61.19", method: 3) + stream(Array(repeating: 9, count: 20))))
    #expect(!variable(tagged("Info", flags: 0x0F, encoder: "Lavc61.19", method: 3) + stream([9, 10, 11, 9])))
}

@Test func info() {
    #expect(!variable(tagged("Info", flags: 0x0F) + stream([9, 10, 11, 12, 9])))
    #expect(!variable(tagged("Info", flags: 0) + stream([9, 10, 11, 12, 9])))
}

@Test func xingQuality() {
    #expect(variable(tagged("Xing", flags: 0x0F) + stream(Array(repeating: 9, count: 20))))
    #expect(variable(tagged("Xing", flags: 0x08) + stream(Array(repeating: 9, count: 20))))
}

@Test func xingWithoutHints() {
    #expect(!variable(tagged("Xing", flags: 0x07) + stream(Array(repeating: 9, count: 20))))
    #expect(variable(tagged("Xing", flags: 0x07) + stream([9, 9, 9, 10, 9])))
    #expect(variable(tagged("Xing", flags: 0x03, index: 5) + stream([9, 9, 9, 10, 9])))
}

@Test func xingTagFrameIgnored() {
    #expect(!variable(tagged("Xing", flags: 0x07, index: 5) + stream(Array(repeating: 9, count: 20))))
}

@Test(arguments: [(true, false), (true, true), (false, false), (false, true)])
func xingOffset(_ mpeg1: Bool, _ mono: Bool) {
    let rest = stream(Array(repeating: 9, count: 20), mpeg1: mpeg1, mono: mono)
    #expect(variable(tagged("Xing", flags: 0x0F, mpeg1: mpeg1, mono: mono) + rest))
    var shifted = tagged("Info", flags: 0x0F, encoder: "LAME3.100", method: 3, mpeg1: mpeg1, mono: mono)
    shifted[3] ^= 0x80
    #expect(!variable(shifted + rest))
}

@Test func xingInsideAudio() {
    var data = stream(Array(repeating: 9, count: 20))
    data.replaceSubrange(500..<504, with: ascii("Xing"))
    #expect(!variable(data))
}

@Test func vbri() {
    var data = frame(9)
    data.replaceSubrange(36..<40, with: ascii("VBRI"))
    #expect(variable(data + stream(Array(repeating: 9, count: 20))))
}

@Test func vbriWrongOffset() {
    var data = frame(9)
    data.replaceSubrange(40..<44, with: ascii("VBRI"))
    #expect(!variable(data + stream(Array(repeating: 9, count: 20))))
}

@Test(arguments: [true, false])
func bare(_ mpeg1: Bool) {
    #expect(!variable(stream(Array(repeating: 9, count: 50), mpeg1: mpeg1)))
    #expect(variable(stream(Array(repeating: 9, count: 49) + [10], mpeg1: mpeg1)))
    #expect(variable(stream([5] + Array(repeating: 9, count: 49), mpeg1: mpeg1)))
}

@Test func padding() {
    let bytes = (0..<40).flatMap { i -> [UInt8] in
        let head = header(9, padding: i % 3 == 0)
        var data = [UInt8](repeating: 0, count: MPEG.frame(UnsafeRawBufferPointer(start: head, count: 4), 0)!.length)
        data.replaceSubrange(0..<4, with: head)
        return data
    }
    #expect(!variable(bytes))
}

@Test func falseSync() {
    #expect(!variable([0xFF, 0xFB, 0x90, 0x40, 0x00, 0x00] + stream(Array(repeating: 9, count: 20))))
    #expect(variable([0xFF, 0xFB, 0x50, 0x40, 0x00, 0x00] + stream(Array(repeating: 9, count: 19) + [10])))
}

@Test func truncated() {
    let full = tagged("Xing", encoder: "LAME3.100", method: 3)
    for count in 0..<full.count {
        _ = variable(Array(full.prefix(count)))
    }
    #expect(variable(full))
}

@Test func frameLengths() {
    let cases: [([UInt8], Int)] = [
        (header(9), 417), (header(9, padding: true), 418), (header(14), 1044), (header(1), 104),
        (header(9, frequency: 1), 384), (header(9, frequency: 2), 576),
        (header(8, mpeg1: false), 208), (header(8, mpeg1: false, frequency: 1), 192),
        ([0xFF, 0xE3, 0x80, 0x40], 417), ([0xFF, 0xE3, 0x18, 0x40], 72),
    ]
    for (bytes, length) in cases {
        #expect(bytes.withUnsafeBytes { MPEG.frame($0, 0)?.length } == length)
    }
}
