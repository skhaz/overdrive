import Foundation

@Observable
final class Playlists {
    nonisolated static func directory(in folder: URL?) -> URL {
        (folder ?? URL.homeDirectory.appending(path: "Music/Library", directoryHint: .isDirectory))
            .appending(path: "Playlists", directoryHint: .isDirectory)
    }

    private(set) var names: [String] = []
    private(set) var paths: [String: [String]] = [:]

    var naming: [URL]?

    @ObservationIgnored private let directory: () -> URL
    @ObservationIgnored private let folder: () -> URL?

    init(directory: URL, folder: URL) {
        self.directory = { directory }
        self.folder = { folder }
        load()
    }

    init(directory: URL, folderPath: String) {
        self.directory = { directory }
        self.folder = { URL(fileURLWithPath: folderPath) }
        load()
    }

    init(directory: @escaping () -> URL, folder: @escaping () -> URL?) {
        self.directory = directory
        self.folder = folder
        load()
    }

    private var folderPath: String { folder().map(Library.real) ?? "" }

    func load() {
        let base = folderPath
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                Log.playlists.error("list failed", metadata: ["directory": "\(directory().path)", "error": "\(error)"])
            }
            files = []
        }

        paths = [:]

        for file in files where file.pathExtension == "plist" {
            let name = file.deletingPathExtension().lastPathComponent
            guard !name.hasSuffix(".backup"), let list = Persist.read([String].self, from: file) else { continue }

            paths[name] = list.map { StoredPath.decode($0, relativeTo: base) }
        }

        names = paths.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        Log.playlists.info("load", metadata: ["directory": "\(directory().path)", "names": Log.list(names)])
    }

    func valid(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)

        return !name.isEmpty && !name.hasPrefix(".") && !name.hasSuffix(".backup") && !name.contains("/") && !name.contains(":")
            && !names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            && !FileManager.default.fileExists(atPath: file(name).path)
    }

    @discardableResult
    func create(_ name: String, _ urls: [URL]) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard valid(name) else {
            Log.playlists.warning("create rejected", metadata: ["name": "\(name)"])
            return nil
        }

        Log.playlists.info("create", metadata: ["name": "\(name)", "songs": "\(urls.count)"])
        names.append(name)
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        add(urls, to: name)

        return name
    }

    func add(_ urls: [URL], to name: String) {
        var metadata = Log.paths(urls.map(\.path))
        metadata["name"] = "\(name)"
        Log.playlists.info("add", metadata: metadata)
        var list = paths[name] ?? []
        var seen = Set(list)

        for url in urls where seen.insert(url.path).inserted {
            list.append(url.path)
        }

        save(name, list)
    }

    func remove(_ positions: Set<Int>, from name: String) {
        Log.playlists.info("remove", metadata: ["name": "\(name)", "count": "\(positions.count)", "positions": Log.list(positions.sorted().prefix(20))])
        var list = paths[name] ?? []
        guard positions.contains(where: list.indices.contains) else { return }

        list.removeSubranges(RangeSet(positions.filter(list.indices.contains).map { $0..<$0 + 1 }))
        save(name, list)
    }

    func duplicate(_ positions: Set<Int>, in name: String) {
        Log.playlists.info("duplicate", metadata: ["name": "\(name)", "count": "\(positions.count)", "positions": Log.list(positions.sorted().prefix(20))])
        let list = paths[name] ?? []
        guard positions.contains(where: list.indices.contains) else { return }

        var result: [String] = []
        result.reserveCapacity(list.count + positions.count)

        for (position, path) in list.enumerated() {
            result.append(path)
            if positions.contains(position) { result.append(path) }
        }

        save(name, result)
    }

    func reorder(_ order: [Int], in name: String) {
        Log.playlists.info("reorder", metadata: ["name": "\(name)", "count": "\(order.count)"])
        let list = paths[name] ?? []
        var result = list

        for (slot, position) in zip(order.sorted(), order) where list.indices.contains(position) && result.indices.contains(slot) {
            result[slot] = list[position]
        }

        save(name, result)
    }

    func delete(_ name: String) {
        Log.playlists.info("delete", metadata: ["name": "\(name)"])
        let backup = directory().appending(path: name + ".backup.plist", directoryHint: .notDirectory)

        guard Persist.move(file(name), to: backup) else { return }

        paths[name] = nil
        names.removeAll { $0 == name }
    }

    private func save(_ name: String, _ list: [String]) {
        paths[name] = list
        guard let folder = folder(), FileManager.default.fileExists(atPath: folder.path) else {
            return Log.playlists.error("save skipped", metadata: ["reason": "folder missing", "folder": "\(folder()?.path ?? "")"])
        }

        let base = folderPath
        guard let data = Persist.encode(list.map { StoredPath.encode($0, relativeTo: base) }, for: file(name)) else { return }

        Persist.write(data, to: file(name))
    }

    private func file(_ name: String) -> URL {
        directory().appending(path: name + ".plist", directoryHint: .notDirectory)
    }
}
