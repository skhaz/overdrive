import Foundation

nonisolated enum MP4 {
    struct Tags {
        var title = ""
        var artist = ""
        var album = ""
        var year = ""
        var original = ""
        var number = 0
        var duration = 0.0
    }

    private typealias Box = (type: UInt32, start: Int64, end: Int64)

    private static let moov: UInt32 = 0x6D6F_6F76
    private static let mvhd: UInt32 = 0x6D76_6864
    private static let udta: UInt32 = 0x7564_7461
    private static let meta: UInt32 = 0x6D65_7461
    private static let ilst: UInt32 = 0x696C_7374
    private static let name: UInt32 = 0xA96E_616D
    private static let artist: UInt32 = 0xA941_5254
    private static let album: UInt32 = 0xA961_6C62
    private static let day: UInt32 = 0xA964_6179
    private static let trkn: UInt32 = 0x7472_6B6E
    private static let covr: UInt32 = 0x636F_7672
    private static let freeform: UInt32 = 0x2D2D_2D2D
    private static let nameBox: UInt32 = 0x6E61_6D65
    private static let data: UInt32 = 0x6461_7461
    private static let originals = ["ORIGINAL YEAR", "ORIGINALYEAR", "ORIGINALDATE", "ORIGINAL DATE"].map { Array($0.utf8) }

    static func cover(_ file: Int32, _ size: Int64) -> Data? {
        guard let moov = child(file, moov, 0, size),
              let udta = child(file, udta, moov.start, moov.end),
              let meta = child(file, meta, udta.start, udta.end),
              let ilst = child(file, ilst, meta.start + 4, meta.end),
              let item = child(file, covr, ilst.start, ilst.end),
              let data = header(file, item.start, item.end) else { return nil }

        return Picture.read(file, data.start + 8, Int(data.end - data.start - 8))
    }

    static func read(_ url: URL) -> Tags? {
        let file = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY) }
        guard file >= 0 else { return nil }
        defer { close(file) }

        var info = stat()
        fstat(file, &info)

        guard let moov = child(file, moov, 0, Int64(info.st_size)) else { return nil }

        var tags = Tags()

        if let mvhd = child(file, mvhd, moov.start, moov.end) {
            tags.duration = duration(file, mvhd.start)
        }

        guard let udta = child(file, udta, moov.start, moov.end),
              let meta = child(file, meta, udta.start, udta.end),
              let ilst = child(file, ilst, meta.start + 4, meta.end) else { return tags }

        walk(file, ilst.start, ilst.end) { item in
            switch item.type {
            case name where tags.title.isEmpty: tags.title = text(file, item)
            case artist where tags.artist.isEmpty: tags.artist = text(file, item)
            case album where tags.album.isEmpty: tags.album = text(file, item)
            case day where tags.year.isEmpty: tags.year = text(file, item)
            case trkn where tags.number == 0: tags.number = number(file, item)
            case freeform where tags.original.isEmpty: tags.original = original(file, item)
            default: break
            }
        }

        return tags
    }

    private static func header(_ file: Int32, _ offset: Int64, _ limit: Int64) -> Box? {
        withUnsafeTemporaryAllocation(byteCount: 16, alignment: 8) { buffer in
            guard pread(file, buffer.baseAddress, 16, offset) >= 8 else { return nil }

            let size = UInt32(bigEndian: buffer.loadUnaligned(as: UInt32.self))
            let type = UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 4, as: UInt32.self))

            switch size {
            case 0: return (type, offset + 8, limit)
            case 1: return (type, offset + 16, offset + Int64(UInt64(bigEndian: buffer.loadUnaligned(fromByteOffset: 8, as: UInt64.self))))
            case 2..<8: return nil
            default: return (type, offset + 8, offset + Int64(size))
            }
        }
    }

    private static func walk(_ file: Int32, _ start: Int64, _ end: Int64, _ body: (Box) -> Void) {
        var offset = start

        while offset + 8 <= end, let box = header(file, offset, end) {
            body(box)
            offset = box.end
        }
    }

    private static func child(_ file: Int32, _ type: UInt32, _ start: Int64, _ end: Int64) -> Box? {
        var offset = start

        while offset + 8 <= end, let box = header(file, offset, end) {
            if box.type == type { return box }
            offset = box.end
        }

        return nil
    }

    private static func text(_ file: Int32, _ item: Box) -> String {
        guard let data = header(file, item.start, item.end) else { return "" }

        let start = data.start + 8
        let count = Int(data.end - start)
        guard count > 0 else { return "" }

        return String(unsafeUninitializedCapacity: count) { max(pread(file, $0.baseAddress, count, start), 0) }
    }

    private static func original(_ file: Int32, _ item: Box) -> String {
        guard let name = child(file, nameBox, item.start, item.end) else { return "" }

        let count = Int(name.end - name.start - 4)
        guard count > 0, count < 16 else { return "" }

        let matches = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: count) { key in
            guard pread(file, key.baseAddress, count, name.start + 4) == count else { return false }

            return originals.contains { $0.count == count && zip($0, key).allSatisfy { $0 == $1 & 0xDF || $0 == 0x20 && $1 == 0x20 } }
        }
        guard matches else { return "" }

        var offset = item.start

        while offset + 8 <= item.end, let box = header(file, offset, item.end) {
            if box.type == data { return text(file, (data, offset, item.end)) }
            offset = box.end
        }

        return ""
    }

    private static func number(_ file: Int32, _ item: Box) -> Int {
        guard let data = header(file, item.start, item.end) else { return 0 }

        return withUnsafeTemporaryAllocation(byteCount: 4, alignment: 4) { buffer in
            guard pread(file, buffer.baseAddress, 4, data.start + 8) == 4 else { return 0 }

            return Int(UInt32(bigEndian: buffer.loadUnaligned(as: UInt32.self)) & 0xFFFF)
        }
    }

    private static func duration(_ file: Int32, _ start: Int64) -> Double {
        withUnsafeTemporaryAllocation(byteCount: 32, alignment: 8) { buffer in
            guard pread(file, buffer.baseAddress, 32, start) == 32 else { return 0 }

            if buffer[0] == 1 {
                let scale = UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 20, as: UInt32.self))
                return Double(UInt64(bigEndian: buffer.loadUnaligned(fromByteOffset: 24, as: UInt64.self))) / Double(max(scale, 1))
            }

            let scale = UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            return Double(UInt32(bigEndian: buffer.loadUnaligned(fromByteOffset: 16, as: UInt32.self))) / Double(max(scale, 1))
        }
    }
}
