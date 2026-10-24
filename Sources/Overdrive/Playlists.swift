import Foundation

@Observable
final class Playlists {
    nonisolated static func directory(in folder: URL?) -> URL {
        (folder ?? URL.homeDirectory.appending(path: "Music/Library", directoryHint: .isDirectory))
            .appending(path: "Playlists", directoryHint: .isDirectory)
    }

    private(set) var names: [String] = []
    private var storedPaths: [String: [String]] = [:]

    var paths: [String: [String]] {
        var result: [String: [String]] = [:]
        for (name, list) in storedPaths {
            result[name] = list.map { StoredPath.decode($0, relativeTo: folderPath) }
        }
        return result
    }

    var naming: [URL]?

    @ObservationIgnored private let directory: () -> URL
    @ObservationIgnored private let folder: () -> URL?
    private let folderPath: String

    init(directory: URL, folder: URL) {
        self.directory = { directory }
        self.folder = { folder }
        self.folderPath = folder.path
        load()
    }

    init(directory: URL, folderPath: String) {
        self.directory = { directory }
        self.folder = { URL(fileURLWithPath: folderPath) }
        self.folderPath = folderPath
        load()
    }

    init(directory: @escaping () -> URL, folder: @escaping () -> URL?) {
        self.directory = directory
        self.folder = folder
        self.folderPath = folder()?.path ?? ""
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []

        storedPaths = [:]

        for file in files where file.pathExtension == "plist" {
            let name = file.deletingPathExtension().lastPathComponent
            guard !name.hasSuffix(".backup") else { continue }
            guard let data = try? Data(contentsOf: file), let list = try? PropertyListDecoder().decode([String].self, from: data) else {
                Log.playlists.error("unreadable", metadata: ["file": "\(file.path)"])
                continue
            }

            storedPaths[name] = list.map { StoredPath.decode($0, relativeTo: folderPath) }
        }

        names = storedPaths.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        Log.playlists.info("load", metadata: ["directory": "\(directory().path)", "names": Log.list(names)])
    }

    func valid(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)

        return !name.isEmpty && !name.hasPrefix(".") && !name.hasSuffix(".backup") && !name.contains("/") && !name.contains(":")
            && !names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    @discardableResult
    func create(_ name: String, _ urls: [URL]) -> String? {
        Log.playlists.info("create", metadata: ["name": "\(name)", "songs": Log.list(urls.map(\.path))])
        let name = name.trimmingCharacters(in: .whitespaces)
        guard valid(name) else { return nil }

        names.append(name)
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        add(urls, to: name)

        return name
    }

    func add(_ urls: [URL], to name: String) {
        Log.playlists.info("add", metadata: ["name": "\(name)", "songs": Log.list(urls.map(\.path))])
        var list = storedPaths[name] ?? []
        var seen = Set(list.map { StoredPath.decode($0, relativeTo: folderPath) })

        for url in urls where seen.insert(url.path).inserted {
            list.append(StoredPath.encode(url.path, relativeTo: folderPath))
        }

        save(name, list)
    }

    func remove(_ positions: Set<Int>, from name: String) {
        Log.playlists.info("remove", metadata: ["name": "\(name)", "positions": Log.list(positions.sorted())])
        var list = storedPaths[name] ?? []
        guard positions.contains(where: list.indices.contains) else { return }

        list.removeSubranges(RangeSet(positions.filter(list.indices.contains).map { $0..<$0 + 1 }))
        save(name, list)
    }

    func duplicate(_ positions: Set<Int>, in name: String) {
        Log.playlists.info("duplicate", metadata: ["name": "\(name)", "positions": Log.list(positions.sorted())])
        let list = storedPaths[name] ?? []
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
        Log.playlists.info("reorder", metadata: ["name": "\(name)", "order": Log.list(order)])
        let list = storedPaths[name] ?? []
        var result = list

        for (slot, position) in zip(order.sorted(), order) {
            result[slot] = list[position]
        }

        save(name, result)
    }

    func delete(_ name: String) {
        Log.playlists.info("delete", metadata: ["name": "\(name)"])
        let backup = directory().appending(path: name + ".backup.plist", directoryHint: .notDirectory)

        guard Persist.move(file(name), to: backup) else { return }

        storedPaths[name] = nil
        names.removeAll { $0 == name }
    }

    private func save(_ name: String, _ list: [String]) {
        storedPaths[name] = list

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(list.map { StoredPath.encode($0, relativeTo: folderPath) }) else { return }

        Persist.write(data, to: file(name))
    }

    private func file(_ name: String) -> URL {
        directory().appending(path: name + ".plist", directoryHint: .notDirectory)
    }
}