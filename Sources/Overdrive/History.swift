nonisolated struct History<Place: Equatable> {
    private(set) var back: [Place] = []
    private(set) var forward: [Place] = []

    mutating func visit(from old: Place, to new: Place) {
        guard old != new else { return }

        back.append(old)
        forward.removeAll()
    }

    mutating func goBack(from current: Place) -> Place? {
        guard let place = back.popLast() else { return nil }

        forward.append(current)
        return place
    }

    mutating func goForward(from current: Place) -> Place? {
        guard let place = forward.popLast() else { return nil }

        back.append(current)
        return place
    }

    mutating func removeAll(where match: (Place) -> Bool) {
        back.removeAll(where: match)
        forward.removeAll(where: match)
    }
}

nonisolated enum Step {
    case up, down, left, right, extendUp, extendDown

    func index(first: Int?, last: Int?, count: Int, columns: Int) -> Int? {
        guard count > 0 else { return nil }

        switch self {
        case .up: return first.map { max($0 - columns, 0) } ?? count - 1
        case .down: return last.map { min($0 + columns, count - 1) } ?? 0
        case .left: return columns > 1 ? first.map { max($0 - 1, 0) } ?? count - 1 : nil
        case .right: return columns > 1 ? last.map { min($0 + 1, count - 1) } ?? 0 : nil
        case .extendUp: return first.flatMap { $0 > 0 ? $0 - 1 : nil }
        case .extendDown: return last.flatMap { $0 < count - 1 ? $0 + 1 : nil }
        }
    }
}
