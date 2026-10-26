import Foundation
import Logging

nonisolated enum Persist {
    private static let queue = DispatchQueue(label: "Persist", qos: .utility)

    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let done = queue.sync { store(data, url) }
        Log.persist.log(level: done ? .debug : .error, "write", metadata: ["path": "\(url.path)", "bytes": "\(data.count)", "result": Self.result(done)])
        return done
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                Log.persist.error("read failed", metadata: ["path": "\(url.path)", "error": "\(error)"])
            }
            return nil
        }

        do {
            let value = try PropertyListDecoder().decode(type, from: data)
            Log.persist.debug("read", metadata: ["path": "\(url.path)", "bytes": "\(data.count)"])
            return value
        } catch {
            Log.persist.error("decode failed", metadata: ["path": "\(url.path)", "bytes": "\(data.count)", "error": "\(error)"])
            return nil
        }
    }

    static func flush() {
        queue.sync {}
    }

    @discardableResult
    static func move(_ source: URL, to destination: URL) -> Bool {
        let done = queue.sync { relocate(source, destination) }
        Log.persist.log(level: done ? .info : .error, "move", metadata: ["from": "\(source.path)", "to": "\(destination.path)", "result": Self.result(done)])
        return done
    }

    @discardableResult
    static func remove(_ url: URL) -> Bool {
        let done = queue.sync {
            guard unlink(url.path) == 0 else { return false }

            sync(url.deletingLastPathComponent())
            return true
        }
        Log.persist.log(level: done ? .info : .error, "remove", metadata: ["path": "\(url.path)", "result": Self.result(done)])
        return done
    }

    private static func result(_ done: Bool) -> Logging.Logger.MetadataValue {
        .string(done ? "ok" : String(cString: strerror(errno)))
    }

    static func durable(_ file: Int32, full: (Int32) -> Int32 = { fcntl($0, F_FULLFSYNC) }) -> Bool {
        if full(file) == 0 { return true }
        guard errno == ENOTSUP || errno == EINVAL || errno == ENOTTY else { return false }

        Log.persist.debug("full sync unsupported", metadata: ["error": "\(String(cString: strerror(errno)))"])
        return fsync(file) == 0
    }

    static func encode<T: Encodable>(_ value: T, for url: URL) -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            return try encoder.encode(value)
        } catch {
            Log.persist.error("encode failed", metadata: ["path": "\(url.path)", "error": "\(error)"])
            return nil
        }
    }

    private static func folder(_ directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.persist.error("folder failed", metadata: ["path": "\(directory.path)", "error": "\(error)"])
        }
    }

    private static func store(_ data: Data, _ url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        folder(directory)

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

        let synced = durable(file)
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
        folder(directory)

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
