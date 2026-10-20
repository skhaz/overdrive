import Foundation

nonisolated enum MPEG {
    struct Frame {
        let mpeg1: Bool
        let mono: Bool
        let bitrate: Int
        let frequency: Int
        let length: Int
    }

    private static let bitrates = [[0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160], [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]]
    private static let frequencies = [44100, 48000, 32000]
    private static let window = 1 << 18
    private static let xing: UInt32 = 0x5869_6E67
    private static let info: UInt32 = 0x496E_666F
    private static let vbri: UInt32 = 0x5642_5249
    private static let lame: UInt32 = 0x4C41_4D45
    private static let old: UInt32 = 0x4C33_2E39

    static func variable(_ url: URL) -> Bool {
        let file = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY) }
        guard file >= 0 else { return false }
        defer { close(file) }

        return withUnsafeTemporaryAllocation(byteCount: window, alignment: 4) { buffer -> Bool in
            var start = 0
            if pread(file, buffer.baseAddress, 10, 0) == 10, buffer[0] == 0x49, buffer[1] == 0x44, buffer[2] == 0x33 {
                start = 10 + ID3.syncsafe(buffer, 6) + (buffer[5] & 0x10 != 0 ? 10 : 0)
            }

            let count = pread(file, buffer.baseAddress, window, off_t(start))
            return count > 0 && variable(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
        }
    }

    static func variable(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let start = first(bytes), let head = frame(bytes, start) else { return false }

        let tag = start + 4 + (head.mpeg1 ? (head.mono ? 17 : 32) : (head.mono ? 9 : 17))
        let id = word(bytes, tag)

        if id == xing || id == info, let flags = word(bytes, tag + 4) {
            var offset = tag + 8
            if flags & 1 != 0 { offset += 4 }
            if flags & 2 != 0 { offset += 4 }
            if flags & 4 != 0 { offset += 100 }
            if flags & 8 != 0 { offset += 4 }

            let encoder = word(bytes, offset)
            let tagged = encoder == lame || encoder == old
            if tagged, offset + 10 <= bytes.count {
                switch bytes[offset + 9] & 0x0F {
                case 1, 8: return false
                case 2...6, 9: return true
                default: break
                }
            }

            if id == info { return false }
            if flags & 8 != 0 || tagged { return true }
            return uniform(bytes, start + head.length) == nil
        }

        if word(bytes, start + 36) == vbri { return true }
        return uniform(bytes, start) == nil
    }

    static func frame(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> Frame? {
        guard offset >= 0, offset + 4 <= bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] & 0xE6 == 0xE2 else { return nil }

        let version = Int(bytes[offset + 1] >> 3 & 3)
        let index = Int(bytes[offset + 2] >> 4)
        let sample = Int(bytes[offset + 2] >> 2 & 3)
        guard version != 1, index != 0, index != 15, sample != 3 else { return nil }

        let mpeg1 = version == 3
        let bitrate = bitrates[mpeg1 ? 1 : 0][index] * 1000
        let frequency = frequencies[sample] >> (mpeg1 ? 0 : version == 2 ? 1 : 2)
        let length = (mpeg1 ? 144 : 72) * bitrate / frequency + Int(bytes[offset + 2] >> 1 & 1)
        return Frame(mpeg1: mpeg1, mono: bytes[offset + 3] >> 6 == 3, bitrate: bitrate, frequency: frequency, length: length)
    }

    private static func first(_ bytes: UnsafeRawBufferPointer) -> Int? {
        var offset = 0
        while offset + 4 <= bytes.count {
            if let head = frame(bytes, offset) {
                let end = offset + head.length
                if end >= bytes.count { return offset }
                if let next = frame(bytes, end), next.mpeg1 == head.mpeg1, next.frequency == head.frequency { return offset }
            }
            offset += 1
        }
        return nil
    }

    private static func uniform(_ bytes: UnsafeRawBufferPointer, _ start: Int) -> Int? {
        var offset = start
        var rate = 0
        while let next = frame(bytes, offset) {
            if rate != 0, next.bitrate != rate { return nil }
            rate = next.bitrate
            offset += next.length
        }
        return rate
    }

    private static func word(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}
