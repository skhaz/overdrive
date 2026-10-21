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

    init(directory: URL) {
        self.directory = { directory }
        load()
    }

    init(directory: @escaping () -> URL) {
        self.directory = directory
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []

        paths = [:]

        for file in files where file.pathExtension == "plist" {
            let name = file.deletingPathExtension().lastPathComponent
            guard !name.hasSuffix(".backup") else { continue }
            guard let data = try? Data(contentsOf: file), let list = try? PropertyListDecoder().decode([String].self, from: data) else { continue }

            paths[name] = list.map(StoredPath.decode)
        }

        names = paths.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func valid(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)

        return !name.isEmpty && !name.hasPrefix(".") && !name.hasSuffix(".backup") && !name.contains("/") && !name.contains(":")
            && !names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    @discardableResult
    func create(_ name: String, _ urls: [URL]) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard valid(name) else { return nil }

        names.append(name)
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        add(urls, to: name)

        return name
    }

    func add(_ urls: [URL], to name: String) {
        var list = paths[name] ?? []
        var seen = Set(list)

        for url in urls where seen.insert(url.path).inserted {
            list.append(url.path)
        }

        save(name, list)
    }

    func remove(_ positions: Set<Int>, from name: String) {
        var list = paths[name] ?? []
        guard positions.contains(where: list.indices.contains) else { return }

        list.removeSubranges(RangeSet(positions.filter(list.indices.contains).map { $0..<$0 + 1 }))
        save(name, list)
    }

    func duplicate(_ positions: Set<Int>, in name: String) {
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
        let list = paths[name] ?? []
        var result = list

        for (slot, position) in zip(order.sorted(), order) {
            result[slot] = list[position]
        }

        save(name, result)
    }

    func delete(_ name: String) {
        let backup = directory().appending(path: name + ".backup.plist", directoryHint: .notDirectory)

        guard Persist.move(file(name), to: backup) else { return }

        paths[name] = nil
        names.removeAll { $0 == name }
    }

    private func save(_ name: String, _ list: [String]) {
        paths[name] = list

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(list.map { StoredPath.encode($0) }) else { return }

        Persist.write(data, to: file(name))
    }

    private func file(_ name: String) -> URL {
        directory().appending(path: name + ".plist", directoryHint: .notDirectory)
    }
}
