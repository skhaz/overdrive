import Foundation

@Observable
final class Playlists {
    nonisolated static let directory = URL.homeDirectory.appending(path: "Music/Library/Playlists", directoryHint: .isDirectory)

    private(set) var names: [String] = []
    private(set) var paths: [String: [String]] = [:]
    var naming: [URL]?

    @ObservationIgnored private let directory: URL

    init(directory: URL = Playlists.directory) {
        self.directory = directory
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []

        paths = [:]
        var migrated: [String] = []
        var legacy: [(file: URL, name: String)] = []

        for file in files where file.pathExtension == "playlist" {
            guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            let name = file.deletingPathExtension().lastPathComponent

            paths[name] = text.split(whereSeparator: \.isNewline).map { stored(String($0)) }
            legacy.append((file, name))
            migrated.append(name)
        }

        for file in files where file.pathExtension == "plist" {
            let name = file.deletingPathExtension().lastPathComponent
            guard !name.hasSuffix(".backup") else { continue }
            guard let data = try? Data(contentsOf: file), let list = try? PropertyListDecoder().decode([String].self, from: data) else { continue }

            var changed = false
            paths[name] = list.map {
                let path = StoredPath.decode($0)
                if StoredPath.encode(path) != $0 { changed = true }
                return path
            }

            if changed { migrated.append(name) }
        }

        names = paths.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        for name in Set(migrated) { save(name, paths[name] ?? []) }

        for item in legacy where FileManager.default.fileExists(atPath: file(item.name).path) {
            try? FileManager.default.removeItem(at: item.file)
        }
    }

    nonisolated static func ignored(_ path: String) -> Bool {
        path.hasPrefix(directory.path + "/")
    }

    func valid(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)

        return !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":")
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
        let backup = directory.appending(path: name + ".backup.plist", directoryHint: .notDirectory)

        guard Persist.move(file(name), to: backup) else { return }

        paths[name] = nil
        names.removeAll { $0 == name }
    }

    private func save(_ name: String, _ list: [String]) {
        paths[name] = list

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(list.map { StoredPath.encode($0) }) else { return }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(name), options: .atomic)
    }

    private func stored(_ line: String) -> String {
        if line == "~" || line.hasPrefix("~/") { return StoredPath.decode(line) }
        if line.hasPrefix("/") { return line }

        return directory.appending(path: line).standardized.path
    }

    private func file(_ name: String) -> URL {
        directory.appending(path: name + ".plist", directoryHint: .notDirectory)
    }
}
