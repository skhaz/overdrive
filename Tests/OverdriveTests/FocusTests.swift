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

@MainActor
struct TypingTests {
    @Test func aSpaceAfterALetterGoesToTheSearch() {
        #expect(Focus.types(" ", into: "black"), "a space typed outside the search field paused the song and the query became one word")
        #expect(Focus.types("-", into: "ac"))
        #expect(Focus.types("'", into: "guns n"))
    }

    @Test func anEmptySearchTakesOnlyLettersAndDigits() {
        #expect(Focus.types("b", into: ""))
        #expect(Focus.types("7", into: ""))
        #expect(Focus.types("é", into: ""))
        #expect(!Focus.types(" ", into: ""), "with no query, Space plays and pauses")
        #expect(!Focus.types("-", into: ""))
    }

    @Test func controlKeysNeverGoToTheSearch() {
        for scalar in [0x09, 0x0D, 0x1B, 0x7F, 0xF700, 0xF701, 0xF702, 0xF703] {
            #expect(!Focus.types(Character(UnicodeScalar(scalar)!), into: "black"))
        }
    }

    @Test func findsTheSearchFieldOfTheToolbar() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let toolbar = NSToolbar(identifier: "test")
        let item = NSSearchToolbarItem(itemIdentifier: NSToolbarItem.Identifier("search"))
        let delegate = ToolbarDelegate(item: item)
        toolbar.delegate = delegate
        window.toolbar = toolbar
        toolbar.insertItem(withItemIdentifier: item.itemIdentifier, at: 0)

        #expect(Focus.field(in: window) === item.searchField)
    }

    @Test func findsASearchFieldInTheWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let field = NSSearchField()
        window.contentView?.addSubview(field)

        #expect(Focus.field(in: window) === field)
        #expect(Focus.field(in: NSWindow()) == nil)
    }
}

private final class ToolbarDelegate: NSObject, NSToolbarDelegate {
    let item: NSToolbarItem

    init(item: NSToolbarItem) {
        self.item = item
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [item.itemIdentifier] }
}
