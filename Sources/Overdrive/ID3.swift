import Foundation

nonisolated enum ID3 {
    private static let recorded: UInt32 = 0x5444_5243
    private static let year: UInt32 = 0x5459_4552
    private static let original: UInt32 = 0x5444_4F52
    private static let originalYear: UInt32 = 0x544F_5259

    static func year(_ url: URL) -> (original: String, release: String) {
        let file = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY) }
        guard file >= 0 else { return ("", "") }
        defer { close(file) }

        return withUnsafeTemporaryAllocation(byteCount: 16, alignment: 4) { buffer -> (original: String, release: String) in
            guard pread(file, buffer.baseAddress, 10, 0) == 10,
                  buffer[0] == 0x49, buffer[1] == 0x44, buffer[2] == 0x33,
                  buffer[3] == 3 || buffer[3] == 4 else { return ("", "") }

            var result = (original: "", release: "")

            let version = buffer[3]
            let end = 10 + syncsafe(buffer, 6)
            var offset = 10

            if buffer[5] & 0x40 != 0, pread(file, buffer.baseAddress, 4, 10) == 4 {
                offset += version == 4 ? syncsafe(buffer, 0) : Int(UInt32(bigEndian: buffer.loadUnaligned(as: UInt32.self))) + 4
            }

            while offset + 10 <= end, pread(file, buffer.baseAddress, 10, off_t(offset)) == 10, buffer[0] != 0 {
                let id = UInt32(bigEndian: buffer.loadUnaligned(as: UInt32.self))
                let size = version == 4 ? syncsafe(buffer, 4) : Int(UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))

                if id == recorded || id == year || id == original || id == originalYear {
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

    static func syncsafe(_ bytes: some RandomAccessCollection<UInt8>, _ offset: Int) -> Int {
        let start = bytes.index(bytes.startIndex, offsetBy: offset)
        return bytes[start...].prefix(4).reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }
}
