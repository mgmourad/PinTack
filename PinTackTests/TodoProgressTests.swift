import XCTest
@testable import PinTack

/// Task counting drives the progress squares, the "3/7", the done checkbox and two of the todo
/// tab's sort orders, so miscounting shows up in four places at once.
final class TodoProgressTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/x.md")
    private func note(_ body: String) -> Note { Note.parse("---\nid: A1\ntags: [todo]\n---\n" + body, fileURL: url) }

    // MARK: Counting

    func testCountsEveryTaskListFormCommonMarkAllows() {
        let n = note("- [ ] dash\n* [x] star\n+ [X] plus capital\n  - [ ] indented\n")
        XCTAssertEqual(n.taskCounts.total, 4)
        XCTAssertEqual(n.taskCounts.done, 2)
    }

    func testPlainBulletsAndTextAreNotTasks() {
        let n = note("# Heading\n\n- just a bullet\n- [ ] a real task\nsome [x] text in a line\n")
        XCTAssertEqual(n.taskCounts.total, 1)
        XCTAssertEqual(n.taskCounts.done, 0)
    }

    func testANoteIsDoneOnlyWhenItHasTasksAndAllAreTicked() {
        XCTAssertFalse(note("- [ ] a\n- [x] b\n").isDone)
        XCTAssertTrue(note("- [x] a\n- [X] b\n").isDone)
        XCTAssertFalse(note("no tasks at all\n").isDone, "a note with no tasks is not 'done'")
    }

    // MARK: The done checkbox

    func testMarkingAllDoneTicksEveryBoxAndLeavesEverythingElseAlone() {
        let n = note("@Todo Shop\n\nBuy before six\n\n- [ ] milk\n  * [ ] oat\n- [x] eggs\n\nnot a task\n")
        n.markAllTasks(done: true)
        XCTAssertEqual(n.taskCounts.done, 3)
        XCTAssertEqual(n.taskCounts.total, 3)
        XCTAssertTrue(n.body.contains("@Todo Shop"))
        XCTAssertTrue(n.body.contains("Buy before six"))
        XCTAssertTrue(n.body.contains("not a task"))
        XCTAssertTrue(n.body.contains("  * [x] oat"), "indentation and marker style must survive")
    }

    func testUnmarkingPutsThemAllBack() {
        let n = note("- [x] a\n- [X] b\n")
        n.markAllTasks(done: false)
        XCTAssertEqual(n.taskCounts.done, 0)
        XCTAssertEqual(n.taskCounts.total, 2)
        XCTAssertFalse(n.isDone)
    }

    func testMarkingIsIdempotent() {
        let n = note("- [ ] a\n- [x] b\n")
        n.markAllTasks(done: true)
        let once = n.body
        n.markAllTasks(done: true)
        XCTAssertEqual(n.body, once)
    }

    // MARK: The one-line preview

    func testPreviewSkipsTheTitleAndStripsMarkup() {
        XCTAssertEqual(note("@Todo Ship it\n\nFirst ring on Monday\n\n- [ ] one\n").previewLine, "First ring on Monday")
        XCTAssertEqual(note("# Heading\n\n- [ ] first task\n").previewLine, "first task", "a task's text still reads as a preview")
        XCTAssertEqual(note("# Heading\n\n## Subheading\n").previewLine, "Subheading")
        XCTAssertEqual(note("Only one line\n").previewLine, "", "nothing after the title means no preview")
    }

    // MARK: Sorting

    func testDueDateSortPutsUndatedNotesLastRatherThanFirst() {
        let soon = note("- [ ] a\n"); soon.due = Date().addingTimeInterval(60)
        let later = note("- [ ] b\n"); later.due = Date().addingTimeInterval(9999)
        let undated = note("- [ ] c\n")

        let sorted = [undated, later, soon].sorted {
            switch ($0.due, $1.due) {
            case let (a?, b?): return a < b
            case (nil, _?):    return false
            case (_?, nil):    return true
            default:           return $0.created < $1.created
            }
        }
        XCTAssertEqual(sorted.map { $0.taskCounts.total }, [1, 1, 1])
        XCTAssertEqual(sorted.last?.due, nil, "a note with no date is not urgent")
        XCTAssertEqual(sorted.first?.due, soon.due)
    }
}
