import AppKit
import Foundation
import Testing
@testable import Overdrive

@MainActor
struct AboutTests {
    @Test func theAboutPageIsAPage() {
        #expect(Page(key: "about") == .about)
        #expect(Page.about.key == "about")
        #expect(Page.about.title == "About")
        #expect(!Navigation(page: .about).lyrics, "the About page has no song, so no lyrics")
    }

    @Test func theGitHubMarkIsAVectorTemplate() {
        let mark = About.mark

        #expect(mark.size.width > 0 && mark.size.height > 0, "macOS reads the official SVG mark")
        #expect(mark.isTemplate, "the mark takes the color of the theme")
        #expect(mark.representations.contains { String(describing: type(of: $0)).contains("SVG") || !($0 is NSBitmapImageRep) }, "the mark stays a vector, not a bitmap")
    }

    @Test func theLinksGoToTheRepository() {
        #expect(About.repository.absoluteString == "https://github.com/skhaz/overdrive")
        #expect(About.issues.absoluteString.hasPrefix(About.repository.absoluteString))
        #expect(About.releases.absoluteString.hasPrefix(About.repository.absoluteString))
    }

    @Test func theSidebarOpensAbout() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "Sources/Overdrive/Views.swift"), encoding: .utf8)

        #expect(source.contains("row(\"About\", \"info.circle\", .about)"))
        #expect(source.contains("case .about: AboutView()"))
    }
}
