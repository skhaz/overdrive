import Foundation
import Testing
@testable import Overdrive

@MainActor struct SummaryTests {
    private func track(_ name: String, _ artist: String, _ album: String, _ duration: Double) -> Track {
        Track(url: URL(fileURLWithPath: "/m/\(album)/\(name).mp3"), title: name, artist: artist, album: album, number: 1, disc: 1, albumArtist: "", year: 2000, duration: duration, albumID: album)
    }

    @Test func songsCountTheirDistinctArtists() {
        let tracks = [track("a", "One", "X", 60), track("b", "Two", "X", 60), track("c", "One", "Y", 60), track("d", "", "Y", 60)]
        #expect(summary(tracks) == "4 songs · 2 artists · 4:00")
        #expect(summary([track("a", "One", "X", 30)]) == "1 song · 1 artist · 0:30")
        #expect(summary([Track]()) == "0 songs · 0 artists · 0:00")
    }

    @Test func albumsCountTheirDistinctArtists() {
        let first = Album(id: "x", title: "X", artist: "One", year: 2000, tracks: [track("a", "One", "X", 60), track("b", "One", "X", 60)])
        let second = Album(id: "y", title: "Y", artist: "Two", year: 2001, tracks: [track("c", "Two", "Y", 60)])
        let third = Album(id: "z", title: "Z", artist: "One", year: 2002, tracks: [track("d", "One", "Z", 3600)])
        #expect(summary([first, second, third]) == "4 songs · 2 artists · 1:03:00")
    }

    @Test func everyPageCountsTheArtistsOfTheSongs() {
        let tracks = [track("a", "One", "X", 60), track("b", "Two", "X", 60), track("c", "Three", "Y", 60)]
        let mixed = Album(id: "x", title: "X", artist: "Various Artists", year: 2000, tracks: Array(tracks[0...1]))
        let single = Album(id: "y", title: "Y", artist: "Three", year: 2000, tracks: [tracks[2]])
        #expect(summary([mixed, single]) == summary(tracks), "the albums of the same songs give the same count as the songs")
        #expect(summary([mixed, single]) == "3 songs · 3 artists · 3:00")
    }
}
