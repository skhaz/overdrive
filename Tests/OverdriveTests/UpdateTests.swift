import Foundation
import Testing
@testable import Overdrive

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}

@MainActor
@Suite(.serialized)
struct UpdateTests {
    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/skhaz/overdrive/releases/tag/\#(tag)","draft":\#(draft),"prerelease":\#(prerelease)}"#.utf8)
    }

    private func answer(_ status: Int, _ data: Data, _ calls: Calls = Calls()) -> Update.Transport {
        { request in
            calls.add()
            #expect(request.url == Update.endpoint)
            #expect(request.timeoutInterval <= 10)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func versionsCompareAsNumbers() {
        #expect(Update.newer("1.0.10", than: "1.0.9"))
        #expect(Update.newer("v1.1", than: "1.0.9"))
        #expect(Update.newer("2.0.0", than: "1.9.99"))
        #expect(!Update.newer("1.0.2", than: "1.0.2"))
        #expect(!Update.newer("v1.0.2", than: "1.0.2.0"))
        #expect(!Update.newer("1.0.1", than: "1.0.2"))
        #expect(!Update.newer("latest", than: "1.0.0"), "an odd tag never asks for an update")
        #expect(!Update.newer("1.0.3", than: "dev"))
    }

    @Test func onlyAPublishedReleaseCounts() {
        #expect(Update.parse(release("v1.2.3")) == Update.Release(version: "1.2.3", url: URL(string: "https://github.com/skhaz/overdrive/releases/tag/v1.2.3")!))
        #expect(Update.parse(release("v1.2.3", draft: true)) == nil)
        #expect(Update.parse(release("v1.2.3", prerelease: true)) == nil)
        #expect(Update.parse(release("nightly")) == nil)
        #expect(Update.parse(Data("<html>down</html>".utf8)) == nil)
        #expect(Update.parse(Data()) == nil)
    }

    @Test func aNewerReleaseIsAvailable() async {
        Update.forget()
        let state = await Update.check(current: "1.0.2", transport: answer(200, release("v1.0.3")))
        #expect(state == .available(Update.Release(version: "1.0.3", url: URL(string: "https://github.com/skhaz/overdrive/releases/tag/v1.0.3")!)))
    }

    @Test func theSameReleaseIsCurrent() async {
        Update.forget()
        #expect(await Update.check(current: "1.0.2", transport: answer(200, release("v1.0.2"))) == .current)
    }

    @Test func anyFailureShowsNothing() async {
        for (status, data) in [(403, Data(#"{"message":"API rate limit exceeded"}"#.utf8)), (429, Data()), (500, Data()), (503, Data("<html>".utf8)), (200, Data("not json".utf8))] {
            Update.forget()
            #expect(await Update.check(current: "1.0.2", transport: answer(status, data)) == .unknown, "status \(status) must not break the About page")
        }

        Update.forget()
        let offline: Update.Transport = { _ in throw URLError(.notConnectedToInternet) }
        #expect(await Update.check(current: "1.0.2", transport: offline) == .unknown)
        let slow: Update.Transport = { _ in throw URLError(.timedOut) }
        #expect(await Update.check(current: "1.0.2", transport: slow) == .unknown)
    }

    @Test func oneAnswerServesForAnHour() async {
        Update.forget()
        let calls = Calls()
        let transport = answer(200, release("v1.0.3"), calls)

        _ = await Update.check(current: "1.0.2", transport: transport)
        _ = await Update.check(current: "1.0.2", transport: transport)
        _ = await Update.check(current: "1.0.3", transport: transport)
        #expect(calls.count == 1, "opening About again must not spend the anonymous rate limit")
        #expect(await Update.check(current: "1.0.3", transport: transport) == .current)

        Update.forget()
        let failing = Calls()
        _ = await Update.check(current: "1.0.2", transport: answer(403, Data(), failing))
        _ = await Update.check(current: "1.0.2", transport: answer(403, Data(), failing))
        #expect(failing.count == 2, "a failure is not kept, so the next visit can try again")
        Update.forget()
    }
}
