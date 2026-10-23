import AppKit
import Testing
@testable import Overdrive

@MainActor
struct FocusTests {
    @Test func theSyncedLyricsDoNotTakeTheTypedKeys() {
        let text = LyricsTextView(usingTextLayoutManager: false)
        text.isEditable = false
        text.isSelectable = true

        #expect(!Focus.typing(text), "letters typed after a click on the lyrics must go to the search field")
    }

    @Test func anEditableTextKeepsTheTypedKeys() {
        let text = NSTextView()
        text.isEditable = true

        #expect(Focus.typing(text))
    }

    @Test func aTableDoesNotTakeTheTypedKeys() {
        #expect(!Focus.typing(NSTableView()))
        #expect(!Focus.typing(nil))
    }
}
