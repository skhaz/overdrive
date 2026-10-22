import Foundation

nonisolated enum StoredPath {
    nonisolated static let home = URL.homeDirectory.resolvingSymlinksInPath().path

    private static func resolvedPath(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().path
    }

    static func encode(_ path: String, relativeTo base: String? = nil) -> String {
        let path = resolvedPath(path)

        if let base {
            if path == base { return "." }
            if path.hasPrefix(base + "/") {
                return String(path.dropFirst(base.count + 1))
            }
        }

        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }

        return "~" + path.dropFirst(home.count)
    }

    static func decode(_ value: String, relativeTo base: String? = nil) -> String {
        if value == "~" { return home }
        if value.hasPrefix("~/") { return resolvedPath(home + value.dropFirst(1)) }
        if value == "." { return base ?? "" }
        if let base, !base.isEmpty, !value.hasPrefix("/"), !value.hasPrefix("~") {
            return (base as NSString).appendingPathComponent(value)
        }
        return resolvedPath(value)
    }
}
