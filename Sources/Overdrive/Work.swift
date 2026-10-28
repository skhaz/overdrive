import Foundation

/// What the UI of a network task shows: the menus dim while a task the user
/// asked for runs, its list spins after `Work.after`, and a task that brought
/// nothing says why. One value per task, so a late answer of the task before
/// cannot write over the one that took its place: every method takes the token
/// of the run it began.
///
/// The `Discovery` menu and the `Infinity` mode share one of these, so there is
/// one spinner, one dim, and one request budget between them. A background
/// top-up of the mode is a *quiet* task: it takes a token and spends requests,
/// and it touches no screen, no dim, and no note, because the user is listening
/// to something and did not ask for anything.
struct Work {
    /// The milliseconds a task the user asked for may run before its list shows
    /// its spinner. A faster answer never flickers one.
    nonisolated static let after: UInt64 = 200

    /// The two stages a task announces: the one the user chose, and the songs
    /// that arrived. The screen opens on both, so a task that spends requests is
    /// on screen while it works.
    nonisolated static let opening = "open"
    nonisolated static let done = "done"

    private(set) var running = false
    private(set) var spinning = false
    private(set) var note: String?
    private(set) var generation = 0
    /// Whether the current generation is a task the user asked for. A quiet
    /// top-up is not, so it dims nothing, spins nothing, and blames nothing.
    private var visible = true

    /// A task the user asked for. It retires the one before it, quiet or not,
    /// and is the only kind that dims the menus.
    mutating func begin() -> Int {
        generation += 1
        running = true
        spinning = false
        note = nil
        visible = true

        return generation
    }

    /// A background top-up. Refused while the user has a task in flight: their
    /// click wins the requests, and the next trigger tries again. It never
    /// refuses a user click, because it dims nothing.
    mutating func claim() -> Int? {
        guard !running else { return nil }

        generation += 1
        visible = false
        spinning = false

        return generation
    }

    /// The list may show its spinner, and only for the task that is still
    /// current and that the user asked for.
    mutating func spin(_ mine: Int) -> Bool {
        guard mine == generation, running, visible else { return false }

        spinning = true
        return true
    }

    /// The task is over: songs went in the list, or the note says why they did
    /// not. False when a newer task took over, which keeps its state. A quiet
    /// task leaves no note behind: the user never asked for it.
    mutating func end(_ mine: Int, _ note: String?) -> Bool {
        guard mine == generation else { return false }

        let told = visible
        running = false
        spinning = false
        visible = true
        self.note = told ? note : nil

        return true
    }

    mutating func reset() {
        self = Work()
    }

    mutating func dismiss() {
        note = nil
    }
}
