import Foundation
import Testing
@testable import Overdrive

struct AlbumStripTests {
    @Test func fewAlbumsFillTheWidth() {
        let width = AlbumStrip.width(of: 3, in: 1200)

        #expect(width > AlbumStrip.minimum)
        #expect(abs(3 * width + 2 * AlbumStrip.spacing + 2 * AlbumStrip.padding - 1200) < 0.001)
    }

    @Test func manyAlbumsKeepTheMinimumAndScroll() {
        #expect(AlbumStrip.width(of: 40, in: 1200) == AlbumStrip.minimum)
        #expect(AlbumStrip.width(of: 1, in: 0) == AlbumStrip.minimum)
        #expect(AlbumStrip.width(of: 0, in: 1200) == AlbumStrip.minimum)
    }
}
