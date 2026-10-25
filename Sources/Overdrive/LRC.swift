import Foundation

nonisolated struct SyncedLine: Equatable, Sendable {
    let time: Double
    let text: String
}

nonisolated enum LRC {
    static func parse(_ text: String) -> [SyncedLine] {
        var offset = 0.0
        var lines: [SyncedLine] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            var times: [Double] = []
            var plain = true
            while line.first == "[", let close = line.firstIndex(of: "]") {
                let tag = String(line[line.index(after: line.startIndex)..<close])
                if let time = stamp(tag) {
                    times.append(time)
                } else if tag.hasPrefix("offset:") {
                    let value = -(Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0) / 1000
                    offset = value.isFinite ? value : 0
                } else if !tag.contains(":") {
                    plain = false
                    break
                }
                line = String(line[line.index(after: close)...])
            }
            let words = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard plain, !times.isEmpty, !words.isEmpty else { continue }
            for time in times where (time + offset).isFinite { lines.append(SyncedLine(time: max(time + offset, 0), text: words)) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    static func index(at position: Double, in lines: [SyncedLine]) -> Int? {
        var low = 0
        var high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= position {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? nil : low - 1
    }

    private static func stamp(_ tag: String) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, parts[0].allSatisfy(\.isNumber), let minutes = Double(parts[0]), let seconds = Double(parts[1]), seconds < 60 else { return nil }
        return minutes * 60 + seconds
    }
}
