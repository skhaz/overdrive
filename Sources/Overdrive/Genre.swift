import Foundation

/// The ID3v1 genre names, which MP4 stores as a number (`gnre`) and ID3 as
/// `(number)text` in `TCON`. The list is the standard one plus the Winamp
/// extension, 0 through 147.
nonisolated enum Genre {
    static let names: [String] = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge",
        "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B",
        "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska",
        "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop",
        "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid",
        "House", "Game", "Sound Clip", "Gospel", "Noise", "AlternRock", "Bass", "Soul",
        "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic",
        "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance",
        "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap",
        "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychadelic",
        "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz",
        "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock", "Folk", "Folk-Rock",
        "National Folk", "Swing", "Fast Fusion", "Bebob", "Latin", "Revival", "Celtic",
        "Bluegrass", "Avantgarde", "Gothic Rock", "Progressive Rock", "Psychedelic Rock",
        "Symphonic Rock", "Slow Rock", "Big Band", "Chorus", "Easy Listening", "Acoustic",
        "Humour", "Speech", "Chanson", "Opera", "Chamber Music", "Sonata", "Symphony",
        "Booty Bass", "Primus", "Porn Groove", "Satire", "Slow Jam", "Club", "Tango",
        "Samba", "Folklore", "Ballad", "Power Ballad", "Rhythmic Soul", "Freestyle",
        "Duet", "Punk Rock", "Drum Solo", "A capella", "Euro-House", "Dance Hall", "Goa",
        "Drum & Bass", "Club-House", "Hardcore", "Terror", "Indie", "BritPop", "Negerpunk",
        "Polsk Punk", "Beat", "Christian Gangsta Rap", "Heavy Metal", "Black Metal",
        "Crossover", "Contemporary Christian", "Christian Rock", "Merengue", "Salsa",
        "Thrash Metal", "Anime", "Jpop", "Synthpop",
    ]

    static func id3(_ id: Int) -> String {
        id >= 0 && id < names.count ? names[id] : ""
    }

    /// The `TCON` style: "Rock", "(17)", or "(17)Rock". A leading run of
    /// numeric groups is a number, the text after it wins when present.
    static func name(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var cursor = trimmed.startIndex
        var id = -1

        while cursor < trimmed.endIndex, trimmed[cursor] == "(" {
            guard let close = trimmed[cursor...].firstIndex(of: ")") else { break }
            let inside = trimmed[trimmed.index(after: cursor)..<close]
            guard let number = Int(inside) else { break }
            id = number
            cursor = trimmed.index(after: close)
        }

        let rest = String(trimmed[cursor...]).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? (id >= 0 ? id3(id) : "") : rest
    }
}
