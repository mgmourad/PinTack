import XCTest
@testable import PinTack

/// Frontmatter parsing and writing. A bug here loses user data. SPEC.md §3.3.
final class NoteFormatTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/x.md")

    // MARK: Round trip

    func testRoundTripKeepsBodyByteForByte() {
        let body = "# Title\n\n- [ ] one\n- [x] two\n\n```sh\necho '---'\n```\n\ntrailing spaces   \n\n\n"
        let n = Note.parse("---\nid: A1\n---\n" + body, fileURL: url)
        XCTAssertEqual(n.body, body)
        let again = Note.parse(n.serialized(), fileURL: url)
        XCTAssertEqual(again.body, body)
        XCTAssertEqual(again.id, "A1")
    }

    func testBodyContainingHorizontalRulesIsNotMistakenForFrontmatter() {
        let n = Note.parse("---\nid: A1\n---\nabove\n\n---\n\nbelow\n---\nend\n", fileURL: url)
        XCTAssertEqual(n.body, "above\n\n---\n\nbelow\n---\nend\n")
    }

    func testFileWithNoFrontmatterIsAValidNote() {
        let n = Note.parse("just some text\nsecond line\n", fileURL: url)
        XCTAssertEqual(n.body, "just some text\nsecond line\n")
        XCTAssertEqual(n.colorHex, "#FFE38A")
        XCTAssertFalse(n.hasFrame)
        XCTAssertFalse(n.id.isEmpty)
    }

    func testUnterminatedFrontmatterIsTreatedAsBodyNotLost() {
        let raw = "---\nid: A1\ntags: [a]\nno closing fence\n"
        XCTAssertEqual(Note.parse(raw, fileURL: url).body, raw)
    }

    func testEmptyBodyAndEmptyFile() {
        XCTAssertEqual(Note.parse("---\nid: A1\n---\n", fileURL: url).body, "")
        XCTAssertEqual(Note.parse("", fileURL: url).body, "")
    }

    // MARK: Unknown keys (plugins own these; dropping them is data loss)

    func testUnknownScalarKeyIsPreserved() {
        let n = Note.parse("---\nid: A1\nruntime-cwd: ~/projects\n---\nbody", fileURL: url)
        XCTAssertTrue(n.serialized().contains("runtime-cwd: ~/projects\n"))
    }

    func testUnknownNestedMapAndListArePreservedVerbatim() {
        let plugin = "runner:\n  lastRun: 2026-09-19T10:00:00Z\n  history:\n    - exit: 0\n      ms: 120\n    - exit: 1\n      ms: 98\n# a comment the plugin wrote"
        let raw = "---\nid: A1\ntags: [x]\n\(plugin)\nother: 5\n---\nbody"
        let out = Note.parse(raw, fileURL: url).serialized()
        XCTAssertTrue(out.contains(plugin), "nested plugin block must survive verbatim, got:\n\(out)")
        XCTAssertTrue(out.contains("other: 5\n"))
    }

    func testUnknownKeysSurviveManySaves() {
        var text = "---\nid: A1\nplug:\n  a: 1\n  b: [1, 2]\n---\nbody"
        for _ in 0..<5 { text = Note.parse(text, fileURL: url).serialized() }
        XCTAssertTrue(text.contains("plug:\n  a: 1\n  b: [1, 2]\n"))
        XCTAssertEqual(text.components(separatedBy: "plug:").count, 2, "must not duplicate the block")
    }

    func testUnknownBlockListAtColumnZeroStaysAttachedToItsKey() {
        let raw = "---\nid: A1\naliases:\n- one\n- two\n---\nbody"
        let out = Note.parse(raw, fileURL: url).serialized()
        XCTAssertTrue(out.contains("aliases:\n- one\n- two\n"))
    }

    // MARK: Known fields

    func testKnownFieldsParse() {
        let raw = """
        ---
        id: 01J9X2K3M4N5P6Q7R8S9T0V1W2
        created: 2026-09-19T10:22:38Z
        tags: [work, urgent]
        pinned: true
        color: "#A3D5FF"
        theme: dark
        opacity: 0.92
        collapsed: true
        visible: false
        frame:
          x: 320
          y: 180
          w: 280
          h: 210
        ---
        hi
        """
        let n = Note.parse(raw, fileURL: url)
        XCTAssertEqual(n.id, "01J9X2K3M4N5P6Q7R8S9T0V1W2")
        XCTAssertEqual(n.tags, ["work", "urgent"])
        XCTAssertTrue(n.pinned); XCTAssertTrue(n.collapsed); XCTAssertFalse(n.visible)
        XCTAssertEqual(n.colorHex, "#A3D5FF")
        XCTAssertEqual(n.theme, "dark")
        XCTAssertEqual(n.opacity, 0.92, accuracy: 0.001)
        XCTAssertEqual(n.cardFrame, NSRect(x: 320, y: 180, width: 280, height: 210))
        XCTAssertTrue(n.hasFrame)
        XCTAssertEqual(Note.iso.string(from: n.created), "2026-09-19T10:22:38Z")
    }

    func testTagsInBlockListForm() {
        let n = Note.parse("---\nid: A\ntags:\n  - work\n  - \"two words\"\n---\nx", fileURL: url)
        XCTAssertEqual(n.tags, ["work", "two words"])
    }

    func testOpacityIsClampedToTheFloor() {
        // A 0 opacity would make an invisible, unrecoverable note. SPEC.md §3.3.
        XCTAssertEqual(Note.parse("---\nid: A\nopacity: 0.0\n---\n", fileURL: url).opacity, 0.3, accuracy: 0.001)
        XCTAssertEqual(Note.parse("---\nid: A\nopacity: 7\n---\n", fileURL: url).opacity, 1.0, accuracy: 0.001)
    }

    func testFrameIsTheCardRectAndRoundTrips() {
        // Persisting the window rect instead makes notes drift 24pt per launch. SPEC.md §5.2.
        let n = Note(fileURL: url, body: "x", cardFrame: NSRect(x: 100, y: 200, width: 280, height: 210))
        let back = Note.parse(n.serialized(), fileURL: url)
        XCTAssertEqual(back.cardFrame, NSRect(x: 100, y: 200, width: 280, height: 210))
        let window = NotePanel.windowRect(forCard: back.cardFrame)
        XCTAssertEqual(NotePanel.cardRect(forWindow: window), back.cardFrame, "window ↔ card must be a lossless pair")
        XCTAssertEqual(window.width, back.cardFrame.width + 48)
    }

    // MARK: Line endings (the vault is edited from Windows too)

    func testCRLFFilesKeepCRLF() {
        let raw = "---\r\nid: A1\r\ntags: [a]\r\n---\r\nline one\r\nline two\r\n"
        let n = Note.parse(raw, fileURL: url)
        XCTAssertTrue(n.usesCRLF)
        XCTAssertEqual(n.body, "line one\nline two\n")
        let out = n.serialized()
        XCTAssertFalse(out.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "no bare LF may remain")
        XCTAssertTrue(out.hasSuffix("line one\r\nline two\r\n"))
    }

    func testLFFilesStayLF() {
        XCTAssertFalse(Note.parse("---\nid: A\n---\nx\n", fileURL: url).serialized().contains("\r"))
    }

    // MARK: Title and tags

    func testTitleComesFromFirstHeadingElseFirstLine() {
        XCTAssertEqual(Note(fileURL: url, body: "\n\n## Sprint  \nrest").title, "Sprint")
        XCTAssertEqual(Note(fileURL: url, body: "plain first line\n# later").title, "plain first line")
        XCTAssertEqual(Note(fileURL: url, body: "").title, "Untitled")
        XCTAssertEqual(Note(fileURL: url, body: "#").title, "Untitled")
    }

    func testInlineTagsMergeIntoFrontmatterButNotFromCodeOrHeadings() {
        let n = Note(fileURL: url, body: "# Heading\nThis is #urgent and #Work/Backend.\n```\n#notatag\n```\nissue #123 and C# too\n")
        n.tags = ["work/backend"]
        n.mergeInlineTags()
        XCTAssertEqual(Set(n.tags.map { $0.lowercased() }), ["work/backend", "urgent"])
        XCTAssertEqual(n.tags.count, 2, "case-insensitive duplicate must not be added twice")
    }

    func testNoteIDsAreUniqueAndSortable() {
        let a = Note.newID(); Thread.sleep(forTimeInterval: 0.01); let b = Note.newID()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 26)
        XCTAssertLessThan(a.prefix(10), b.prefix(10))
    }

    // MARK: Title vs first line (owner decision, 2026-09-19)

    /// A new note has no `title:`, so its title simply is its first line and follows every edit.
    func testTitleFollowsTheFirstLineUntilTheNoteIsRenamed() {
        let n = Note.parse("---\nid: A1\n---\n# Draft\n\nbody\n", fileURL: url)
        XCTAssertEqual(n.title, "Draft")
        n.body = "# Draft two\n\nbody\n"
        XCTAssertEqual(n.title, "Draft two", "with no title: of its own the header must track the first line")
        XCTAssertNil(n.customTitle)
        XCTAssertFalse(n.serialized().contains("title:"), "an un-renamed note must not gain a title: key")
    }

    /// Renaming stores the name beside the note and leaves every byte of the body alone.
    func testRenamingStoresTitleInFrontmatterAndNeverTouchesTheBody() {
        let body = "# Draft\n\nbody text\n"
        let n = Note.parse("---\nid: A1\n---\n" + body, fileURL: url)
        n.retitle(to: "Q4 rollout")
        XCTAssertEqual(n.title, "Q4 rollout")
        XCTAssertEqual(n.body, body, "renaming must not rewrite the first line")

        let reloaded = Note.parse(n.serialized(), fileURL: url)
        XCTAssertEqual(reloaded.title, "Q4 rollout", "the name must survive a save and reload")
        XCTAssertEqual(reloaded.body, body)
    }

    /// The point of the split: after a rename the two are independent in BOTH directions.
    func testAfterRenamingTheFirstLineNoLongerRenamesTheNote() {
        let n = Note.parse("---\nid: A1\n---\n# Draft\n\nbody\n", fileURL: url)
        n.retitle(to: "Q4 rollout")
        n.body = "# Something else entirely\n\nbody\n"
        XCTAssertEqual(n.title, "Q4 rollout")
        XCTAssertEqual(n.titleFromBody, "Something else entirely")
    }

    /// Renaming back to what the first line says (or to nothing) re-links them.
    func testRenamingToTheFirstLineOrToNothingClearsTheOverride() {
        let n = Note.parse("---\nid: A1\n---\n# Draft\n\nbody\n", fileURL: url)
        n.retitle(to: "Q4 rollout")
        XCTAssertNotNil(n.customTitle)
        n.retitle(to: "Draft")
        XCTAssertNil(n.customTitle, "matching the first line puts the note back to following it")

        n.retitle(to: "Q4 rollout")
        n.retitle(to: "   ")
        XCTAssertNil(n.customTitle, "an empty rename clears the override")
        XCTAssertEqual(n.title, "Draft")
    }

    func testFreezeStateSurvivesASaveAndReload() {
        let n = Note.parse("---\nid: A1\n---\nbody\n", fileURL: url)
        XCTAssertFalse(n.frozen, "notes are not frozen by default")
        n.frozen = true
        let reloaded = Note.parse(n.serialized(), fileURL: url)
        XCTAssertTrue(reloaded.frozen, "a frozen note must come back frozen, or it silently starts taking clicks again")

        reloaded.frozen = false
        XCTAssertFalse(Note.parse(reloaded.serialized(), fileURL: url).frozen)
    }

    func testTitleWithQuotesAndColonsSurvivesARoundTrip() {
        let n = Note.parse("---\nid: A1\n---\nbody\n", fileURL: url)
        n.retitle(to: "He said \"hi\": a report")
        let reloaded = Note.parse(n.serialized(), fileURL: url)
        XCTAssertEqual(reloaded.title, "He said \"hi\": a report")
    }

    func testTitleDoesNotDisturbUnknownKeyPreservation() {
        let raw = "---\nid: A1\nplugin-thing:\n  a: 1\n  b: two\n---\nbody\n"
        let n = Note.parse(raw, fileURL: url)
        n.retitle(to: "Renamed")
        let out = Note.parse(n.serialized(), fileURL: url).serialized()
        XCTAssertTrue(out.contains("plugin-thing:"))
        XCTAssertTrue(out.contains("  a: 1"))
        XCTAssertTrue(out.contains("  b: two"))
        XCTAssertTrue(out.contains("title: \"Renamed\""))
    }
}
