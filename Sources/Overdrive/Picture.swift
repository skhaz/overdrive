import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

nonisolated enum Picture {
    private static let names: Set<String> = ["cover", "folder", "front", "album"]

    typealias Run = ([URL], Int) -> (received: Set<Int>, covers: [Int: Data], clean: Bool)

    static func generate(_ urls: [URL]) -> [Data?] {
        collect(urls, run)
    }

    static func collect(_ urls: [URL], _ run: Run) -> [Data?] {
        var covers = [Data?](repeating: nil, count: urls.count)
        var left = Array(urls.indices)
        var workers = 4

        while !left.isEmpty {
            let result = run(left.map { urls[$0] }, workers)
            var missing: [Int] = []
            for (offset, index) in left.enumerated() {
                if result.received.contains(offset) { covers[index] = result.covers[offset] } else { missing.append(index) }
            }
            if missing.isEmpty { break }

            if result.clean {
                Log.cache.error("covers missing", metadata: ["count": "\(missing.count)"])
                break
            }
            if workers > 1 {
                Log.cache.warning("covers crashed", metadata: ["missing": "\(missing.count)", "retry": "one at a time"])
                workers = 1
                left = missing
                continue
            }

            Log.cache.error("cover crashed", metadata: ["path": "\(urls[missing[0]].path)"])
            left = Array(missing.dropFirst())
        }

        Log.cache.info("covers", metadata: ["requested": "\(urls.count)", "found": "\(covers.count { $0 != nil })"])
        return covers
    }

    static func record(_ index: Int, _ cover: Data?) -> Data {
        var data = Data(capacity: 8 + (cover?.count ?? 0))
        withUnsafeBytes(of: UInt32(index).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(cover?.count ?? 0).littleEndian) { data.append(contentsOf: $0) }
        if let cover { data.append(cover) }
        return data
    }

    static func records(_ data: Data) -> (received: Set<Int>, covers: [Int: Data]) {
        var received = Set<Int>()
        var covers: [Int: Data] = [:]
        var offset = data.startIndex

        func number(_ at: Int) -> Int {
            Int(data[at..<(at + 4)].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        }

        while offset + 8 <= data.endIndex {
            let index = number(offset)
            let count = number(offset + 4)
            guard offset + 8 + count <= data.endIndex else { break }

            received.insert(index)
            if count > 0 { covers[index] = data[(offset + 8)..<(offset + 8 + count)] }
            offset += 8 + count
        }
        return (received, covers)
    }

    private static func run(_ urls: [URL], _ workers: Int) -> (received: Set<Int>, covers: [Int: Data], clean: Bool) {
        guard Bundle.main.bundleIdentifier == "org.delduca.Overdrive" else { return ([], [:], true) }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["covers", String(workers)]
        process.standardInput = input
        process.standardOutput = output

        do {
            try process.run()
        } catch {
            Log.cache.error("covers process failed", metadata: ["albums": "\(urls.count)", "error": "\(error)"])
            return ([], [:], true)
        }

        let paths = Data(urls.map(\.path).joined(separator: "\0").utf8)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        DispatchQueue.global().async {
            do {
                try input.fileHandleForWriting.write(contentsOf: paths)
                try input.fileHandleForWriting.close()
            } catch {
                Log.cache.error("covers input failed", metadata: ["albums": "\(urls.count)", "error": "\(error)"])
            }
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let clean = process.terminationReason == .exit && process.terminationStatus == 0
        let result = records(data)
        Log.cache.log(level: clean ? .debug : .error, "covers run", metadata: [
            "requested": "\(urls.count)", "received": "\(result.received.count)", "workers": "\(workers)", "bytes": "\(data.count)",
            "exit": "\(process.terminationStatus)", "signal": "\(process.terminationReason == .uncaughtSignal)",
        ])
        return (result.received, result.covers, clean)
    }

    static func serve(workers: Int) {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let urls = input.split(separator: 0).map { URL(filePath: String(decoding: $0, as: UTF8.self)) }
        let next = Atomic(0)
        let writing = Mutex(())

        DispatchQueue.concurrentPerform(iterations: max(1, min(workers, 8))) { _ in
            while true {
                let index = next.add(1, ordering: .relaxed).oldValue
                guard index < urls.count else { return }

                autoreleasepool {
                    let data = record(index, thumbnail(urls[index]))
                    writing.withLock { _ in FileHandle.standardOutput.write(data) }
                }
            }
        }
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
