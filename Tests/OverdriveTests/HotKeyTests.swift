import Carbon.HIToolbox
import Foundation
import Testing
@testable import Overdrive

struct HotKeyTests {
    @Test func theFindShortcutIsOptionSpace() {
        #expect(HotKey.key == UInt32(kVK_Space))
        #expect(HotKey.modifiers == UInt32(optionKey), "two keys only; Control-Command-F is full screen")
    }

    @Test func theDelegateRegistersTheShortcutAndShowsTheWindow() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appending(path: "Sources/Overdrive/Overdrive.swift"), encoding: .utf8)

        #expect(source.contains("hotKey = HotKey { [weak self] in self?.find() }"))
        #expect(source.contains("NSApp.activate()"))
        #expect(source.contains("open?(id: \"main\")"), "a closed main window must open again")
        #expect(source.contains(".keyboardShortcut(.space, modifiers: .option)"), "the menu shows the same shortcut")
    }
}
