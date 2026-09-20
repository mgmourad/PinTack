import XCTest
@testable import PinTack

/// Templates are ordinary notes carrying a name, recalled by typing @name. The name is parsed back
/// out of a note's text, so what counts as a legal name matters.
final class TemplateTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/x.md")

    // MARK: Names

    func testLegalNamesAreKeptAsTyped() {
        for name in ["meeting", "meeting-notes", "change_record", "v1.2", "Sprint2026", "a"] {
            XCTAssertEqual(Note.sanitizedTemplateName(name), name)
        }
    }

    /// Spaces and punctuation could not be parsed back out of "@name" in a note's text.
    func testAnythingThatIsNotALetterDigitHyphenDotOrUnderscoreIsStripped() {
        XCTAssertEqual(Note.sanitizedTemplateName("meeting notes"), "meetingnotes")
        XCTAssertEqual(Note.sanitizedTemplateName("change/record"), "changerecord")
        XCTAssertEqual(Note.sanitizedTemplateName("we!rd@name#"), "werdname")
        XCTAssertEqual(Note.sanitizedTemplateName("  padded  "), "padded")
        XCTAssertEqual(Note.sanitizedTemplateName("!!!"), "", "nothing usable means no name at all")
        XCTAssertEqual(Note.sanitizedTemplateName(""), "")
    }

    func testNamesAreCappedSoTheMenuStaysReadable() {
        XCTAssertEqual(Note.sanitizedTemplateName(String(repeating: "a", count: 200)).count, 40)
    }

    /// @todo already means "turn this note into a todo", so a template could never answer to it.
    func testTodoIsReserved() {
        XCTAssertTrue(Note.reservedTemplateNames.contains("todo"))
    }

    // MARK: Round trip

    func testATemplateNameSurvivesASaveAndReload() {
        let n = Note.parse("---\nid: A1\n---\n# Change record\n\n| Step | Owner |\n", fileURL: url)
        XCTAssertFalse(n.isTemplate)
        n.templateName = "change-record"

        let back = Note.parse(n.serialized(), fileURL: url)
        XCTAssertTrue(back.isTemplate)
        XCTAssertEqual(back.templateName, "change-record")
        XCTAssertTrue(back.body.contains("| Step | Owner |"), "a template is still just a note")
    }

    func testAnOrdinaryNoteDoesNotGainAnEmptyTemplateKey() {
        let n = Note.parse("---\nid: A1\n---\nplain\n", fileURL: url)
        XCTAssertFalse(n.serialized().contains("template:"))
    }

    func testAnIllegalNameInAFileIsCleanedOnLoadRatherThanTrusted() {
        let n = Note.parse("---\nid: A1\ntemplate: bad name/here\n---\nx\n", fileURL: url)
        XCTAssertEqual(n.templateName, "badnamehere")
    }

    func testUnmarkingRemovesTheKeyEntirely() {
        let n = Note.parse("---\nid: A1\ntemplate: thing\n---\nx\n", fileURL: url)
        n.templateName = ""
        XCTAssertFalse(n.serialized().contains("template:"))
    }

    // MARK: The todo marker in list titles

    func testTheTodoMarkerIsStrippedForListsThatAreAllTodos() {
        XCTAssertEqual(Note.parse("---\nid: A\n---\n@Todo Ship the pilot\n", fileURL: url).titleWithoutTodoMarker,
                       "Ship the pilot")
        XCTAssertEqual(Note.parse("---\nid: A\n---\n@Todo\n", fileURL: url).titleWithoutTodoMarker,
                       "Untitled todo", "a todo with no title still needs something to click")
        XCTAssertEqual(Note.parse("---\nid: A\n---\n# A normal note\n", fileURL: url).titleWithoutTodoMarker,
                       "A normal note", "a note that is not a todo is left alone")
    }

    func testARenamedTodoKeepsItsOwnTitle() {
        // A title: in the frontmatter wins over the body, and carries no marker to strip.
        let n = Note.parse("---\nid: A\ntitle: \"Pilot rollout\"\n---\n@Todo whatever\n", fileURL: url)
        XCTAssertEqual(n.titleWithoutTodoMarker, "Pilot rollout")
    }
}
