import Foundation

nonisolated enum Similarity {
    /// How close two names must be to count as the same song.
    static let threshold = 0.8

    /// 1 minus the edit distance over the length of the longer name.
    /// Zero when either name has no letters or digits, so an empty answer
    /// from the internet never matches a song.
    nonisolated static func ratio(_ one: String, _ two: String) -> Double {
        let a = letters(one), b = letters(two)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return 1 - Double(distance(a, b)) / Double(max(a.count, b.count))
    }

    /// The Levenshtein distance, one row, the shorter name in the row.
    nonisolated static func distance(_ one: [Character], _ two: [Character]) -> Int {
        guard !one.isEmpty else { return two.count }
        guard !two.isEmpty else { return one.count }

        let (long, short) = one.count >= two.count ? (one, two) : (two, one)
        var row = Array(0...short.count)
        var next = [Int](repeating: 0, count: short.count + 1)

        for (index, left) in long.enumerated() {
            next[0] = index + 1
            for (slot, right) in short.enumerated() {
                let cost = left == right ? 0 : 1
                next[slot + 1] = min(row[slot] + cost, next[slot] + 1, row[slot + 1] + 1)
            }
            swap(&row, &next)
        }

        return row[short.count]
    }

    /// Folded, letters and digits only: case, accents, punctuation, and spacing
    /// never decide whether two names are the same song.
    nonisolated static func letters(_ text: String) -> [Character] {
        Array(Fuzzy.fold(text).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.flatMap { String($0) })
    }
}
