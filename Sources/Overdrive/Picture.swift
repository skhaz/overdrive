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

        let source = Embedded.cover(url).flatMap { CGImageSourceCreateWithData($0 as CFData, uncached) } ?? folder(url).flatMap { CGImageSourceCreateWithURL($0 as CFURL, uncached) }
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }

        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private static func folder(_ url: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.contentTypeKey], options: .skipsHiddenFiles)) ?? []
        let images = files.filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true }

        return images.first { names.contains($0.deletingPathExtension().lastPathComponent.lowercased()) } ?? images.first
    }
}
