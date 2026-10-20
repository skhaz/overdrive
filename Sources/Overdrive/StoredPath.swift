import Foundation

nonisolated enum StoredPath {
    nonisolated static let home = URL.homeDirectory.standardized.path

    static func encode(_ path: String) -> String {
        let path = URL(filePath: path).standardized.path

        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }

        return "~" + path.dropFirst(home.count)
    }

    static func decode(_ value: String) -> String {
        if value == "~" { return home }
        if value.hasPrefix("~/") { return URL(filePath: home + value.dropFirst(1)).standardized.path }

        return URL(filePath: value).standardized.path
    }

    static func normalizeID(_ id: String) -> String {
        guard let newline = id.firstIndex(of: "\n") else { return encode(decode(id)) }

        return encode(decode(String(id[..<newline]))) + id[newline...]
    }
}
