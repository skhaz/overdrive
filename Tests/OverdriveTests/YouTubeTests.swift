import Testing
@testable import Overdrive

@MainActor
struct YouTubeTests {
    private func runs(_ text: String) -> [String: Any] {
        ["runs": [["text": text]]]
    }

    private func video(_ id: String, _ title: String, _ channel: String) -> [String: Any] {
        ["videoRenderer": ["videoId": id, "title": runs(title), "ownerText": runs(channel)]]
    }

    @Test func readsSearchResults() {
        let json: [String: Any] = ["contents": ["twoColumnSearchResultsRenderer": ["primaryContents": ["sectionListRenderer": ["contents": [
            ["itemSectionRenderer": ["contents": [video("a", "First", "One"), ["adSlotRenderer": [:]], video("b", "Second", "Two")]]],
        ]]]]]]
        let results = YouTube.results(json)
        #expect(results.map(\.id) == ["a", "b"])
        #expect(results.map(\.title) == ["First", "Second"])
        #expect(results.map(\.channel) == ["One", "Two"])
    }

    @Test func keepsOrderOfMatches() {
        let results = [("a", "Thunderstruck (Live at River Plate)", "Fan Channel"), ("b", "AC/DC - Thunderstruck (Official Video)", "AC/DC"), ("c", "AC/DC - Thunderstruck", "ACDCVEVO")]
        #expect(YouTube.match(results, "AC/DC", "Thunderstruck") == ["b", "c"])
    }

    @Test func needsArtistInTitleOrChannel() {
        #expect(YouTube.match([("a", "Thunderstruck (Official Video)", "Random")], "AC/DC", "Thunderstruck").isEmpty)
        #expect(YouTube.match([("a", "Thunderstruck (Official Video)", "ACDCVEVO")], "AC/DC", "Thunderstruck") == ["a"])
    }

    @Test func skipsTopicChannels() {
        #expect(YouTube.match([("a", "Thunderstruck", "AC/DC - Topic"), ("b", "AC/DC - Thunderstruck", "AC/DC")], "AC/DC", "Thunderstruck") == ["b"])
    }

    @Test func matchesWholeWords() {
        #expect(YouTube.match([("a", "Lovely - Billie Eilish", "Billie Eilish")], "Billie Eilish", "Love").isEmpty)
    }

    @Test func ignoresCaseAccentsAndSuffixes() {
        #expect(YouTube.match([("a", "Beyoncé - Don't Hurt Yourself", "Beyonce")], "BEYONCE", "Don't Hurt Yourself (feat. Jack White)") == ["a"])
        #expect(YouTube.match([("a", "The Beatles - Something", "The Beatles")], "The Beatles", "Something - Remastered 2009") == ["a"])
    }
}
