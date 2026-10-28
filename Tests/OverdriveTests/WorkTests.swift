import Foundation
import Testing
@testable import Overdrive

/// The state one screen shares between the `Discovery` pickers and the
/// `Infinity` mode: one spinner, one dim, one note, and a rule that says a quiet
/// top-up never takes any of them from the user.
///
/// Every mutating call is bound to a local first: `#expect` reads its arguments
/// in a closure of its own, and a mutating method cannot live there.
@MainActor
@Suite struct WorkTests {
    @Test func aTaskTheUserAskedForOpensDimsAndCloses() {
        var work = Work()
        let idle = !work.running && !work.spinning && work.note == nil
        #expect(idle, "nothing on its way at launch")

        let mine = work.begin()
        #expect(work.running, "the menus dim while the task runs")
        #expect(!work.spinning, "no spinner before the grace")
        #expect(work.note == nil, "a new task clears the note of the one before")
        #expect(mine == 1)

        let spun = work.spin(mine)
        #expect(spun, "the list may spin after the grace")
        #expect(work.spinning)

        let landed = work.end(mine, nil)
        #expect(landed, "the answer lands")
        let clean = !work.running && !work.spinning && work.note == nil
        #expect(clean, "the spinner and the dim leave together, and a good task leaves no note")
    }

    @Test func aLateAnswerCannotWriteOverTheTaskThatTookItsPlace() {
        var work = Work()
        let old = work.begin()
        let now = work.begin()
        #expect(now != old, "every task takes a new token")

        let spun = work.spin(old)
        #expect(!spun, "and the watch task of the one before cannot spin the new one")

        let dropped = work.end(old, "late")
        #expect(!dropped, "a dropped answer changes no state")
        #expect(work.running, "the dim of the current task stays")
        #expect(work.note == nil, "and no blame from the task that lost")

        let matched = work.end(now, "nothing matched")
        #expect(matched)
        #expect(work.note == "nothing matched", "the task that is current is the one that speaks")
    }

    @Test func aQuietTopUpTakesNothingFromTheUser() {
        var work = Work()
        let mine = work.claim()
        #expect(mine != nil, "with nothing on its way, a fill may run")
        #expect(!work.running, "a quiet task does not dim the menus")
        #expect(!work.spinning)

        let spun = work.spin(mine!)
        #expect(!spun, "and it never spins the list: the user is listening to something")

        let closed = work.end(mine!, nil)
        #expect(closed, "it closes on its own token")
        #expect(!work.spinning)

        var busy = Work()
        let user = busy.begin()
        let refused = busy.claim()
        #expect(refused == nil, "a fill never runs while the user has a task in flight: their click wins the requests")
        #expect(busy.running, "and the dim of the user task stays exactly as it was")

        let still = busy.spin(user)
        #expect(still, "the user task still spins")

        var note = Work()
        let claimed = note.claim()
        let quiet = note.end(claimed!, "nothing matched")
        #expect(quiet, "a quiet task closes")
        #expect(note.note == nil, "and it blames nothing: the user never asked for it")
    }

    @Test func aQuietTaskStillLosesToAUserClickAndToItsSuccessor() {
        var work = Work()
        let mine = work.claim()
        let user = work.begin()
        #expect(user != mine, "a click takes a new token even from a fill in flight")

        let replaced = work.end(mine!, nil)
        #expect(!replaced, "the fill that was replaced lands on nothing")
        #expect(work.running, "and it cannot close the task of the user")

        let clicked = work.end(user, nil)
        #expect(clicked, "the click closes on its own token")
        #expect(!work.running)
    }

    @Test func leavingTheModeClearsTheScreen() {
        var work = Work()
        let opened = work.begin()
        let spinning = work.spin(opened)
        #expect(spinning)
        work.end(opened, "a note")
        let shown = !work.running && work.note == "a note" && !work.spinning
        #expect(shown, "a task that added nothing leaves its note")

        work.reset()
        let cleared = !work.running && !work.spinning && work.note == nil
        #expect(cleared, "a mode that left leaves no spinner and no blame behind")

        var noted = Work()
        let last = noted.begin()
        noted.end(last, "a note")
        noted.dismiss()
        #expect(noted.note == nil, "and the user can clear a note on its own")
        #expect(!noted.running, "without starting anything")
    }

    @Test func theGraceIsTwoHundredMilliseconds() {
        #expect(Work.after == 200, "a faster answer never flickers a spinner")
        #expect(Work.opening == "open" && Work.done == "done", "the screen tells the two stages of a task apart")
    }

    @Test func oneScreenStateServesBothComponents() throws {
        let discovery = try source("Discovery.swift")
        let infinity = try source("Infinity.swift")
        let work = try source("Work.swift")

        #expect(discovery.contains("private(set) var work = Work()"), "the menu owns the state")
        #expect(!work.contains("import SwiftUI") && !work.contains("View"), "and it is a plain value, so both components and the tests read it")
        #expect(work.components(separatedBy: "struct Work").count - 1 == 1, "one definition, not one per component")
        #expect(!discovery.contains("nonisolated struct Work"), "the nested copy is gone")
        #expect(!infinity.contains("private var run"), "the mode has no second generation counter: the shared token is the only one")
        #expect(infinity.contains("discovery.begin()"), "the start of the mode is a task the user asked for")
        #expect(infinity.contains("discovery.claim()"), "and its top-up is a quiet one")
        #expect(infinity.contains("discovery.finish(mine"), "both close through the same door")
        #expect(body(infinity, "func off(_ reason: String) {").contains("discovery.reset()"), "leaving the mode takes its spinner and its note off the screen")
    }

    // MARK: - helpers

    private func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/\(name)"), encoding: .utf8)
    }

    private func body(_ source: String, _ signature: String) -> String {
        guard let start = source.range(of: signature) else { return "" }
        let rest = source[start.upperBound...]

        return String(rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)])
    }
}
