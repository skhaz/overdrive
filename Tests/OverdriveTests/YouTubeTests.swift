import Testing
@testable import Overdrive

@MainActor
struct YouTubeTests {
    private func item(_ id: String, _ title: String, _ channel: String) -> [String: Any] {
        ["id": ["videoId": id], "snippet": ["title": title, "channelTitle": channel]]
    }

    @Test func picksFirstMatch() {
        let items = [item("a", "Thunderstruck (Live at River Plate)", "Fan Channel"), item("b", "AC/DC - Thunderstruck (Official Video)", "AC/DC"), item("c", "AC/DC - Thunderstruck", "ACDCVEVO")]
        #expect(YouTube.match(items, "AC/DC", "Thunderstruck") == "b")
    }

    @Test func needsArtistInTitleOrChannel() {
        #expect(YouTube.match([item("a", "Thunderstruck (Official Video)", "Random")], "AC/DC", "Thunderstruck") == nil)
        #expect(YouTube.match([item("a", "Thunderstruck (Official Video)", "ACDCVEVO")], "AC/DC", "Thunderstruck") == "a")
    }

    @Test func skipsTopicChannels() {
        #expect(YouTube.match([item("a", "Thunderstruck", "AC/DC - Topic"), item("b", "AC/DC - Thunderstruck", "AC/DC")], "AC/DC", "Thunderstruck") == "b")
    }

    @Test func matchesWholeWords() {
        #expect(YouTube.match([item("a", "Lovely - Billie Eilish", "Billie Eilish")], "Billie Eilish", "Love") == nil)
    }

    @Test func ignoresCaseAccentsEntitiesAndSuffixes() {
        #expect(YouTube.match([item("a", "Beyoncé - Don&#39;t Hurt Yourself", "Beyonce")], "BEYONCE", "Don't Hurt Yourself (feat. Jack White)") == "a")
        #expect(YouTube.match([item("a", "The Beatles - Something", "The Beatles")], "The Beatles", "Something - Remastered 2009") == "a")
    }
}
