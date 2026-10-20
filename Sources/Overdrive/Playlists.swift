import Foundation

@Observable
final class Playlists {
    nonisolated static let directory = URL.homeDirectory.appending(path: "Music/Library/Playlists", directoryHint: .isDirectory)

    private(set) var names: [String] = []
    private(set) var paths: [String: [String]] = [:]
    var naming: [URL]?

    init() {
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []

        paths = [:]
        var migrated: [String] = []

        for file in files where file.pathExtension == "playlist" {
            guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { continue }
            var relative = false
            let name = file.deletingPathExtension().lastPathComponent

            paths[name] = text.split(whereSeparator: \.isNewline).map {
                guard !$0.hasPrefix("/") else { return String($0) }

                relative = true
                return Self.directory.appending(path: $0).standardized.path
            }

            if relative { migrated.append(name) }
        }

        names = paths.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        for name in migrated { save(name, paths[name] ?? []) }
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
        let backup = Self.directory.appending(path: name + ".backup", directoryHint: .notDirectory)

        try? FileManager.default.removeItem(at: backup)
        guard (try? FileManager.default.moveItem(at: file(name), to: backup)) != nil else { return }

        paths[name] = nil
        names.removeAll { $0 == name }
    }

    private func save(_ name: String, _ list: [String]) {
        paths[name] = list

        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? Data(list.map { $0 + "\n" }.joined().utf8).write(to: file(name), options: .atomic)
    }

    private func file(_ name: String) -> URL {
        Self.directory.appending(path: name + ".playlist", directoryHint: .notDirectory)
    }
}
