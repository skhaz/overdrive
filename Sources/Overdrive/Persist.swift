import Foundation

nonisolated enum Persist {
    private static let queue = DispatchQueue(label: "Persist", qos: .utility)

    static func write(_ data: Data, to url: URL, wait: Bool = false) {
        if wait {
            queue.sync { store(data, url) }
        } else {
            queue.async { store(data, url) }
        }
    }

    private static func store(_ data: Data, _ url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = url.appendingPathExtension("tmp")
        let file = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard file >= 0 else { return }

        let complete = data.withUnsafeBytes { bytes in
            var offset = 0

            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress! + offset, bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }

            return true
        }

        let synced = fcntl(file, F_FULLFSYNC) == 0
        close(file)

        guard complete, synced, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            return
        }

        let folder = open(directory.path, O_RDONLY)
        guard folder >= 0 else { return }

        fsync(folder)
        close(folder)
    }
}
