import Carbon.HIToolbox
import Foundation
import Testing
@testable import Overdrive

struct HotKeyTests {
    @Test func theFindShortcutIsControlOptionCommandF() {
        #expect(HotKey.key == UInt32(kVK_ANSI_F))
        #expect(HotKey.modifiers == UInt32(controlKey | optionKey | cmdKey))
    }

    @Test func theDelegateRegistersTheShortcutAndShowsTheWindow() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let source = try String(contentsOf: root.appending(path: "Sources/Overdrive/Overdrive.swift"), encoding: .utf8)

        #expect(source.contains("hotKey = HotKey { [weak self] in self?.find() }"))
        #expect(source.contains("NSApp.activate()"))
        #expect(source.contains("open?(id: \"main\")"), "a closed main window must open again")
        #expect(source.contains(".keyboardShortcut(\"f\", modifiers: [.control, .option, .command])"), "the menu shows the same shortcut")
    }
}
