import Foundation

nonisolated enum Similarity {
    static let threshold = 0.8

    nonisolated static func normal(_ text: String) -> String {
        normal(letters(text))
    }

    nonisolated static func normal(_ letters: [Unicode.Scalar]) -> String {
        String(String.UnicodeScalarView(letters))
    }

    nonisolated static func ratio(_ one: String, _ two: String) -> Double {
        ratio(letters(one), letters(two))
    }

    nonisolated static func ratio(_ one: [Unicode.Scalar], _ two: [Unicode.Scalar]) -> Double {
        guard !one.isEmpty, !two.isEmpty else { return 0 }
        return 1 - Double(distance(one, two)) / Double(max(one.count, two.count))
    }

    /// The ratio only when the names are close enough to matter. The walk stops as
    /// soon as no alignment of the rest can reach the line, so a name that is far
    /// away costs the length of the shorter one, not the product of both.
    nonisolated static func close(_ one: [Unicode.Scalar], _ two: [Unicode.Scalar]) -> Double? {
        guard !one.isEmpty, !two.isEmpty else { return nil }

        let longest = max(one.count, two.count)
        let limit = longest - Int((Double(longest) * threshold).rounded(.up))
        let found = distance(one, two, limit)
        return found <= limit ? 1 - Double(found) / Double(longest) : nil
    }

    nonisolated static func distance(_ one: [Unicode.Scalar], _ two: [Unicode.Scalar], _ limit: Int) -> Int {
        guard !one.isEmpty else { return two.count }
        guard !two.isEmpty else { return one.count }

        let (long, short) = one.count >= two.count ? (one, two) : (two, one)
        var row = Array(0...short.count)
        var next = [Int](repeating: 0, count: short.count + 1)

        for (index, left) in long.enumerated() {
            next[0] = index + 1
            var lowest = next[0]
            for (slot, right) in short.enumerated() {
                let cost = left == right ? 0 : 1
                next[slot + 1] = min(row[slot] + cost, next[slot] + 1, row[slot + 1] + 1)
                lowest = min(lowest, next[slot + 1])
            }
            guard lowest <= limit else { return limit + 1 }
            swap(&row, &next)
        }

        return row[short.count]
    }

    nonisolated static func distance(_ one: [Character], _ two: [Character]) -> Int {
        distance(scalars(one), scalars(two))
    }

    nonisolated static func scalars(_ text: [Character]) -> [Unicode.Scalar] {
        text.reduce(into: []) { $0 += $1.unicodeScalars }
    }

    nonisolated static func distance(_ one: [Unicode.Scalar], _ two: [Unicode.Scalar]) -> Int {
        distance(one, two, .max)
    }

    nonisolated static func letters(_ text: String) -> [Unicode.Scalar] {
        Array(Fuzzy.fold(text).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
