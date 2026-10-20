import Foundation

nonisolated enum Persist {
    private static let queue = DispatchQueue(label: "Persist", qos: .utility)

    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        queue.sync { store(data, url) }
    }

    static func flush() {
        queue.sync {}
    }

    @discardableResult
    static func move(_ source: URL, to destination: URL) -> Bool {
        queue.sync { relocate(source, destination) }
    }

    @discardableResult
    static func remove(_ url: URL) -> Bool {
        queue.sync {
            guard unlink(url.path) == 0 else { return false }

            sync(url.deletingLastPathComponent())
            return true
        }
    }

    private static func store(_ data: Data, _ url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = url.appendingPathExtension("tmp")
        let file = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard file >= 0 else { return false }

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
            return false
        }

        sync(directory)
        return true
    }

    private static func relocate(_ source: URL, _ destination: URL) -> Bool {
        let directory = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let moved = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return false }
                return rename(from, to) == 0
            }
        }

        guard moved else { return false }

        sync(directory)
        return true
    }

    private static func sync(_ directory: URL) {
        let folder = open(directory.path, O_RDONLY)
        guard folder >= 0 else { return }

        fsync(folder)
        close(folder)
    }
}
