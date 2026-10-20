import Foundation

nonisolated enum ID3 {
    struct Tags {
        var original = ""
        var release = ""
        var albumArtist = ""
        var disc = 0
    }

    private static let recorded: UInt32 = 0x5444_5243
    private static let year: UInt32 = 0x5459_4552
    private static let original: UInt32 = 0x5444_4F52
    private static let originalYear: UInt32 = 0x544F_5259
    private static let part: UInt32 = 0x5450_4F53
    private static let band: UInt32 = 0x5450_4532

    static func read(_ url: URL) -> Tags {
        let file = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY) }
        guard file >= 0 else { return Tags() }
        defer { close(file) }

        return withUnsafeTemporaryAllocation(byteCount: 16, alignment: 4) { buffer -> Tags in
            guard pread(file, buffer.baseAddress, 10, 0) == 10,
                  buffer[0] == 0x49, buffer[1] == 0x44, buffer[2] == 0x33,
                  buffer[3] == 3 || buffer[3] == 4 else { return Tags() }

            var result = Tags()

            let version = buffer[3]
            let end = 10 + syncsafe(buffer, 6)
            var offset = 10

            if buffer[5] & 0x40 != 0, pread(file, buffer.baseAddress, 4, 10) == 4 {
                offset += version == 4 ? syncsafe(buffer, 0) : Int(UInt32(bigEndian: buffer.loadUnaligned(as: UInt32.self))) + 4
            }

            while offset + 10 <= end, pread(file, buffer.baseAddress, 10, off_t(offset)) == 10, buffer[0] != 0 {
                let id = UInt32(bigEndian: buffer.loadUnaligned(as: UInt32.self))
                let size = version == 4 ? syncsafe(buffer, 4) : Int(UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))

                if id == part {
                    let count = pread(file, buffer.baseAddress, min(size, 16), off_t(offset + 10))
                    result.disc = Int(String(decoding: buffer.prefix(max(count, 0)).drop { !(0x30...0x39).contains($0) }.prefix { (0x30...0x39).contains($0) }, as: UTF8.self)) ?? 0
                } else if id == band {
                    result.albumArtist = text(file, off_t(offset + 10), size)
                } else if id == recorded || id == year || id == original || id == originalYear {
                    let count = pread(file, buffer.baseAddress, min(size, 16), off_t(offset + 10))
                    let digits = String(decoding: buffer.prefix(max(count, 0)).filter { (0x30...0x39).contains($0) }.prefix(4), as: UTF8.self)

                    if id == original || id == originalYear {
                        result.original = digits
                    } else {
                        result.release = digits
                    }
                }

                offset += 10 + size
            }

            return result
        }
    }

    private static func text(_ file: Int32, _ offset: off_t, _ size: Int) -> String {
        let count = min(size, 512)
        guard count > 1 else { return "" }

        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: count) { bytes in
            let read = pread(file, bytes.baseAddress, count, offset)
            guard read > 1 else { return "" }

            let body = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(bytes)[1..<read])
            let encoding: String.Encoding = switch bytes[0] {
            case 1: .utf16
            case 2: .utf16BigEndian
            case 3: .utf8
            default: .isoLatin1
            }

            return String(bytes: body, encoding: encoding)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces)) ?? ""
        }
    }

    static func syncsafe(_ bytes: some RandomAccessCollection<UInt8>, _ offset: Int) -> Int {
        let start = bytes.index(bytes.startIndex, offsetBy: offset)
        return bytes[start...].prefix(4).reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }
}
