import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

nonisolated enum Picture {
    private static let names: Set<String> = ["cover", "folder", "front", "album"]

    static func generate(_ urls: [URL]) -> [Data?] {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["covers"]
        process.standardInput = input
        process.standardOutput = output
        try! process.run()

        let paths = Data(urls.map(\.path).joined(separator: "\0").utf8)

        DispatchQueue.global().async {
            input.fileHandleForWriting.write(paths)
            try? input.fileHandleForWriting.close()
        }

        let descriptor = output.fileHandleForReading.fileDescriptor

        func fill(_ buffer: UnsafeMutableRawBufferPointer) {
            var done = 0

            while done < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress! + done, buffer.count - done)
                guard count > 0 else { return }
                done += count
            }
        }

        var size = UInt64(0)
        withUnsafeMutableBytes(of: &size) { fill($0) }

        var data = Data(count: Int(UInt64(littleEndian: size)))
        data.withUnsafeMutableBytes { fill($0) }
        process.waitUntilExit()

        var covers: [Data?] = []
        covers.reserveCapacity(urls.count)
        var offset = data.startIndex

        while offset + 4 <= data.endIndex {
            let count = Int(data[offset..<(offset + 4)].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
            offset += 4
            covers.append(count > 0 ? data[offset..<(offset + count)] : nil)
            offset += count
        }

        return covers
    }

    static func serve() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let urls = input.split(separator: 0).map { URL(filePath: String(decoding: $0, as: UTF8.self)) }
        let next = Atomic(0)
        nonisolated(unsafe) let results = UnsafeMutableBufferPointer<Data?>.allocate(capacity: urls.count)
        results.initialize(repeating: nil)

        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            while true {
                let index = next.add(1, ordering: .relaxed).oldValue
                guard index < urls.count else { return }

                autoreleasepool {
                    results[index] = thumbnail(urls[index])
                }
            }
        }

        var output = Data()
        let size = results.reduce(0) { $0 + 4 + ($1?.count ?? 0) }
        output.reserveCapacity(8 + size)
        withUnsafeBytes(of: UInt64(size).littleEndian) { output.append(contentsOf: $0) }

        for result in results {
            withUnsafeBytes(of: UInt32(result?.count ?? 0).littleEndian) { output.append(contentsOf: $0) }
            if let result { output.append(result) }
        }

        FileHandle.standardOutput.write(output)
    }

    static func thumbnail(_ url: URL) -> Data? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 440,
            kCGImageSourceShouldCache: false,
        ] as CFDictionary
        let uncached = [kCGImageSourceShouldCache: false] as CFDictionary

        let source = embedded(url).flatMap { CGImageSourceCreateWithData($0 as CFData, uncached) } ?? folder(url).flatMap { CGImageSourceCreateWithURL($0 as CFURL, uncached) }
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static func read(_ file: Int32, _ offset: Int64, _ count: Int) -> Data? {
        guard count > 0 else { return nil }

        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { pread(file, $0.baseAddress, count, offset) }
        return read == count ? data : nil
    }

    private static func embedded(_ url: URL) -> Data? {
        let file = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY) }
        guard file >= 0 else { return nil }
        defer { close(file) }

        var info = stat()
        fstat(file, &info)

        return withUnsafeTemporaryAllocation(byteCount: 12, alignment: 4) { magic -> Data? in
            guard pread(file, magic.baseAddress, 12, 0) == 12 else { return nil }

            if magic[0] == 0x49, magic[1] == 0x44, magic[2] == 0x33 { return id3(file, magic) }
            if magic[0] == 0x66, magic[1] == 0x4C, magic[2] == 0x61, magic[3] == 0x43 { return flac(file) }
            if magic[4] == 0x66, magic[5] == 0x74, magic[6] == 0x79, magic[7] == 0x70 { return MP4.cover(file, Int64(info.st_size)) }
            return nil
        }
    }

    private static func id3(_ file: Int32, _ header: UnsafeMutableRawBufferPointer) -> Data? {
        let version = header[3]
        guard version == 3 || version == 4 else { return nil }

        let size = syncsafe(header, 6)
        guard let tag = read(file, 10, size) else { return nil }

        return tag.withUnsafeBytes { tag -> Data? in
            var offset = 0

            if header[5] & 0x40 != 0 {
                offset = version == 4 ? syncsafe(tag, 0) : Int(UInt32(bigEndian: tag.loadUnaligned(as: UInt32.self))) + 4
            }

            while offset + 10 <= size, tag[offset] != 0 {
                let length = version == 4 ? syncsafe(tag, offset + 4) : Int(UInt32(bigEndian: tag.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
                let start = offset + 10
                let end = min(start + length, size)

                if tag[offset] == 0x41, tag[offset + 1] == 0x50, tag[offset + 2] == 0x49, tag[offset + 3] == 0x43 {
                    return picture(tag, start, end)
                }

                offset = end
            }

            return nil
        }
    }

    private static func picture(_ frame: UnsafeRawBufferPointer, _ start: Int, _ end: Int) -> Data? {
        let encoding = frame[start]
        var index = start + 1

        while index < end, frame[index] != 0 { index += 1 }
        index += 2

        if encoding == 1 || encoding == 2 {
            while index + 1 < end, frame[index] != 0 || frame[index + 1] != 0 { index += 2 }
            index += 2
        } else {
            while index < end, frame[index] != 0 { index += 1 }
            index += 1
        }

        guard index < end else { return nil }

        return Data(UnsafeRawBufferPointer(rebasing: frame[index..<end]))
    }

    private static func flac(_ file: Int32) -> Data? {
        var offset: Int64 = 4

        return withUnsafeTemporaryAllocation(byteCount: 4, alignment: 4) { header -> Data? in
            while pread(file, header.baseAddress, 4, offset) == 4 {
                let last = header[0] & 0x80 != 0
                let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])

                if header[0] & 0x7F == 6, let block = read(file, offset + 4, length) {
                    return block.withUnsafeBytes { block -> Data? in
                        var index = 4
                        index += 4 + Int(UInt32(bigEndian: block.loadUnaligned(fromByteOffset: index, as: UInt32.self)))
                        index += 4 + Int(UInt32(bigEndian: block.loadUnaligned(fromByteOffset: index, as: UInt32.self)))
                        index += 16
                        let count = Int(UInt32(bigEndian: block.loadUnaligned(fromByteOffset: index, as: UInt32.self)))
                        index += 4

                        guard index + count <= block.count else { return nil }

                        return Data(UnsafeRawBufferPointer(rebasing: block[index..<(index + count)]))
                    }
                }

                guard !last else { return nil }

                offset += 4 + Int64(length)
            }

            return nil
        }
    }

    private static func folder(_ url: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.contentTypeKey], options: .skipsHiddenFiles)) ?? []
        let images = files.filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true }

        return images.first { names.contains($0.deletingPathExtension().lastPathComponent.lowercased()) } ?? images.first
    }

    private static func syncsafe(_ bytes: some RandomAccessCollection<UInt8>, _ offset: Int) -> Int {
        let start = bytes.index(bytes.startIndex, offsetBy: offset)
        return bytes[start...].prefix(4).reduce(0) { $0 << 7 | Int($1 & 0x7F) }
    }
}
