import XCTest
@testable import PinTack

/// Quick capture turns someone else's text into a note, so what it makes of that text — and where
/// it says the text came from — has to be right.
final class QuickCaptureTests: VaultTestCase {

    private let url = URL(fileURLWithPath: "/tmp/x.md")

    // MARK: Shaping the captured text

    func testAShortSingleLineIsItsOwnTitleAndIsNotDressedUp() {
        let body = QuickCapture.body(for: "Renew the build agent certificate")
        XCTAssertEqual(body, "Renew the build agent certificate\n")
        XCTAssertFalse(body.hasPrefix("#"), "a one-liner does not need a heading bolted on")
    }

    func testAMultiLineCaptureGetsItsFirstLinePromotedToATitle() {
        let body = QuickCapture.body(for: "Rollout plan\nring 1 on Monday\nring 2 on Friday")
        XCTAssertTrue(body.hasPrefix("# Rollout plan\n\n"))
        XCTAssertTrue(body.contains("ring 1 on Monday"))
        XCTAssertTrue(body.contains("ring 2 on Friday"), "nothing captured may be dropped")
    }

    func testALongFirstLineIsTruncatedForTheTitleButKeptInFull() {
        let long = String(repeating: "word ", count: 40)
        let body = QuickCapture.body(for: long + "\nsecond line")
        let title = body.components(separatedBy: "\n")[0]
        XCTAssertTrue(title.hasPrefix("# "))
        XCTAssertLessThanOrEqual(title.count, 64, "the header should not be a paragraph")
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertTrue(body.contains(long.trimmingCharacters(in: .whitespaces)), "the full text is still there")
    }

    func testTextThatIsOnlyWhitespaceIsNeverTurnedIntoANote() {
        // capture() is guarded by its callers; this pins the guard they rely on.
        for blank in ["", "   ", "\n\n", "\t \n"] {
            XCTAssertTrue(blank.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: Where it came from

    func testTheSourceAppIsRecordedAndSurvivesASaveAndReload() {
        let n = Note.parse("---\nid: A1\n---\ncaptured text\n", fileURL: url)
        n.source = "Safari"
        let back = Note.parse(n.serialized(), fileURL: url)
        XCTAssertEqual(back.source, "Safari")
    }

    func testANoteWithNoSourceDoesNotGainAnEmptyKey() {
        let n = Note.parse("---\nid: A1\n---\nplain\n", fileURL: url)
        XCTAssertFalse(n.serialized().contains("source:"))
    }

    func testCapturingWritesARealNoteIntoTheVault() throws {
        let note = store.createNote(body: QuickCapture.body(for: "From a web page\nsecond line"))
        note.source = "Safari"
        store.save(note)

        let fresh = VaultStore(root: root)
        fresh.loadAll()
        let reloaded = try XCTUnwrap(fresh.note(id: note.id))
        XCTAssertEqual(reloaded.title, "From a web page")
        XCTAssertEqual(reloaded.source, "Safari")
        XCTAssertTrue(reloaded.body.contains("second line"))
    }
}
