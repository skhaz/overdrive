import Foundation
import Logging
import os

nonisolated enum Log {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Overdrive")
    static let sink: Sink? = Bundle.main.bundleIdentifier == "org.delduca.Overdrive" ? Sink(directory: directory) : nil
    nonisolated(unsafe) static var tap: (@Sendable (Data) -> Void)?

    private static let bootstrapped: Void = LoggingSystem.bootstrap { label in Handler(label: label, sink: sink) }

    static let app = make("app")
    static let player = make("player")
    static let library = make("library")
    static let cache = make("cache")
    static let persist = make("persist")
    static let lyrics = make("lyrics")
    static let lastFM = make("lastfm")
    static let youTube = make("youtube")
    static let loudness = make("loudness")
    static let likes = make("likes")
    static let loves = make("loves")
    static let plays = make("plays")
    static let playlists = make("playlists")
    static let navigation = make("navigation")
    static let keys = make("keys")
    static let crash = make("crash")

    static func make(_ label: String) -> Logging.Logger {
        _ = bootstrapped
        var logger = Logging.Logger(label: label)
        logger.logLevel = .trace
        return logger
    }

    static func list(_ items: some Sequence<some CustomStringConvertible>) -> Logging.Logger.MetadataValue {
        .array(items.map { .string($0.description) })
    }

    static func paths(_ items: [String], limit: Int = 20) -> Logging.Logger.Metadata {
        ["count": "\(items.count)", "paths": list(items.prefix(limit))]
    }

    static func flush() {
        sink?.flush()
    }

    static func start() {
        guard let sink else { return }

        sink.start()
        NSSetUncaughtExceptionHandler { exception in
            Log.crash.critical("exception", metadata: ["name": "\(exception.name.rawValue)", "reason": "\(exception.reason ?? "")", "stack": Log.list(exception.callStackSymbols)])
            Log.flush()
        }
        for number in Sink.signals {
            signal(number) { number in
                Sink.crashed(number)
                signal(number, SIG_DFL)
                raise(number)
            }
        }
    }
}

nonisolated struct Handler: LogHandler {
    let label: String
    let sink: Sink?
    private let system: os.Logger
    var logLevel = Logging.Logger.Level.trace
    var metadata: Logging.Logger.Metadata = [:]
    var metadataProvider: Logging.Logger.MetadataProvider?

    init(label: String, sink: Sink?) {
        self.label = label
        self.sink = sink
        system = os.Logger(subsystem: "org.delduca.Overdrive", category: label)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        var fields = metadata
        if let provided = metadataProvider?.get() { fields.merge(provided) { $1 } }
        if let extra = event.metadata { fields.merge(extra) { $1 } }
        if let error = event.error { fields["error"] = "\(error)" }

        let date = Date()
        let record = Sink.record(date, event.level, label, event.message.description, fields, (event.file as NSString).lastPathComponent, event.line)
        system.log(level: Self.type(event.level), "\(String(decoding: record, as: UTF8.self), privacy: .public)")
        sink?.write(record, at: date, now: event.level >= .error)
        Log.tap?(record)
    }

    static func type(_ level: Logging.Logger.Level) -> OSLogType {
        switch level {
        case .trace, .debug: .debug
        case .info: .info
        case .notice, .warning: .default
        case .error: .error
        case .critical: .fault
        }
    }
}

nonisolated final class Sink: @unchecked Sendable {
    static let interval = 3600.0
    static let batch = 0.1
    static let kept = 24
    static let signals = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP, SIGSYS]
    nonisolated(unsafe) private static var descriptor: Int32 = -1
    nonisolated(unsafe) private static var messages: [Int32: UnsafeMutablePointer<CChar>] = [:]

    let directory: URL
    private let queue = DispatchQueue(label: "Log", qos: .utility)
    private var file: Int32 = -1
    private var hour = Int.min
    private var waiting = false

    init(directory: URL) {
        self.directory = directory
    }

    static func name(_ hour: Int) -> String {
        var time = time_t(hour) * time_t(interval)
        var parts = tm()
        gmtime_r(&time, &parts)
        return String(format: "%04d-%02d-%02dT%02d.log", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday, parts.tm_hour)
    }

    static func record(_ date: Date, _ level: Logging.Logger.Level, _ label: String, _ message: String, _ metadata: Logging.Logger.Metadata, _ file: String, _ line: UInt) -> Data {
        var object: [String: Any] = [
            "time": date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            "level": level.rawValue,
            "label": label,
            "message": message,
            "source": "\(file):\(line)",
        ]
        if !metadata.isEmpty { object["metadata"] = metadata.mapValues(value) }

        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{\"message\":\"unencodable\"}".utf8)
        data.append(0x0A)
        return data
    }

    private static func value(_ value: Logging.Logger.MetadataValue) -> Any {
        switch value {
        case .string(let text): text
        case .stringConvertible(let item): item.description
        case .array(let items): items.map(Self.value)
        case .dictionary(let items): items.mapValues(Self.value)
        }
    }

    func start() {
        queue.sync {
            for number in Self.signals where Self.messages[number] == nil {
                Self.messages[number] = strdup("{\"label\":\"crash\",\"level\":\"critical\",\"message\":\"signal\",\"metadata\":{\"signal\":\"\(number)\"}}\n")
            }
        }
    }

    func write(_ record: Data, at date: Date, now: Bool = false) {
        queue.async { [self] in
            rotate(Int((date.timeIntervalSince1970 / Self.interval).rounded(.down)))
            guard file >= 0 else { return }

            record.withUnsafeBytes { bytes in
                _ = Darwin.write(file, bytes.baseAddress, bytes.count)
            }
            if now {
                fsync(file)
                waiting = false
            } else if !waiting {
                waiting = true
                queue.asyncAfter(deadline: .now() + Self.batch) { [self] in
                    guard waiting else { return }

                    waiting = false
                    if file >= 0 { fsync(file) }
                }
            }
        }
    }

    func flush() {
        queue.sync {
            if file >= 0 { fsync(file) }
        }
    }

    static func repair(_ file: Int32) {
        var end = lseek(file, 0, SEEK_END)
        var byte: UInt8 = 0
        while end > 0, pread(file, &byte, 1, end - 1) == 1, byte != 0x0A { end -= 1 }

        guard end < lseek(file, 0, SEEK_END) else { return }

        ftruncate(file, end)
        fsync(file)
    }

    static func crashed(_ number: Int32) {
        guard descriptor >= 0, let message = messages[number] else { return }

        _ = Darwin.write(descriptor, message, strlen(message))
        fsync(descriptor)
    }

    private func rotate(_ now: Int) {
        guard now != hour else { return }

        if file >= 0 {
            fsync(file)
            close(file)
            file = -1
            Self.descriptor = -1
        }
        hour = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = open(directory.appending(path: Self.name(now)).path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        if file >= 0 { Self.repair(file) }
        Self.descriptor = file

        let oldest = Self.name(now - Self.kept + 1)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".log") && name < oldest {
            unlink(directory.appending(path: name).path)
        }
        let folder = open(directory.path, O_RDONLY)
        if folder >= 0 {
            fsync(folder)
            close(folder)
        }
    }
}
