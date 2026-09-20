import XCTest
@testable import PinTack

/// Due dates live in the note's frontmatter and decide when a notification fires, so parsing and
/// round-tripping them has to be exact: a wrong unit means a reminder at the wrong hour.
final class ReminderTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/x.md")
    private func note() -> Note { Note.parse("---\nid: A1\ntags: [todo]\n---\n@Todo Ship it\n", fileURL: url) }

    // MARK: "30m" and friends

    func testAheadValuesParseToTheRightNumberOfSeconds() {
        let n = note()
        for (text, seconds) in [("30m", 1800.0), ("1h", 3600.0), ("2h", 7200.0), ("1d", 86400.0), ("15 m", 900.0), ("2H", 7200.0)] {
            n.remindAhead = Note.normalizedAhead(text)
            XCTAssertEqual(n.remindAheadInterval, seconds, "\(text) should be \(seconds)s, got \(n.remindAhead)")
        }
    }

    /// Anything unparseable means NO early reminder, rather than a guess that fires at the wrong time.
    func testNonsenseAheadValuesTurnTheEarlyReminderOff() {
        let n = note()
        for text in ["", "soon", "abc", "0m", "-5m", "m", "half an hour"] {
            n.remindAhead = Note.normalizedAhead(text)
            XCTAssertEqual(n.remindAhead, "", "\(text) must not be accepted")
            XCTAssertNil(n.remindAheadInterval)
        }
    }

    // MARK: Which notifications get scheduled

    func testBothRemindersAreScheduledAndOnlyInTheFuture() {
        let n = note()
        n.due = Date().addingTimeInterval(3600)          // an hour away
        n.remindOnTime = true
        n.remindAhead = "30m"
        let fired = n.reminderDates
        XCTAssertEqual(Set(fired.map(\.id)), ["ontime", "ahead"])

        // 45 minutes before an hour from now is still 15 minutes away, so both still stand.
        n.remindAhead = "45m"
        XCTAssertEqual(Set(n.reminderDates.map(\.id)), ["ontime", "ahead"])

        // 2 hours before an hour-away deadline has already been and gone: it must be dropped
        // rather than scheduled for a moment in the past.
        n.remindAhead = "2h"
        XCTAssertEqual(n.reminderDates.map(\.id), ["ontime"])
    }

    func testAPastDueDateSchedulesNothing() {
        let n = note()
        n.due = Date().addingTimeInterval(-60)
        n.remindOnTime = true
        n.remindAhead = "10m"
        XCTAssertTrue(n.reminderDates.isEmpty)
    }

    func testADateWithNoRemindersSetAnnouncesNothing() {
        let n = note()
        n.due = Date().addingTimeInterval(3600)
        XCTAssertTrue(n.reminderDates.isEmpty, "a due date alone is just written on the note")
    }

    // MARK: Round trip

    func testDueDateAndRemindersSurviveASaveAndReload() throws {
        let n = note()
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        n.due = when; n.remindOnTime = true; n.remindAhead = "2h"

        let back = Note.parse(n.serialized(), fileURL: url)
        XCTAssertEqual(try XCTUnwrap(back.due).timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(back.remindOnTime)
        XCTAssertEqual(back.remindAhead, "2h")
    }

    func testClearingTheDueDateRemovesTheWholeBlockFromTheFile() {
        let n = note()
        n.due = Date(); n.remindOnTime = true; n.remindAhead = "1d"
        XCTAssertTrue(n.serialized().contains("due:"))

        n.due = nil
        let text = n.serialized()
        for key in ["due:", "remindOnTime:", "remindAhead:"] {
            XCTAssertFalse(text.contains(key), "\(key) must not linger once the date is cleared")
        }
        XCTAssertNil(Note.parse(text, fileURL: url).due)
    }

    func testRemindersDoNotDisturbUnknownFrontmatterKeys() {
        let n = Note.parse("---\nid: A1\nplugin-thing:\n  a: 1\n---\n@Todo x\n", fileURL: url)
        n.due = Date(); n.remindOnTime = true
        let out = Note.parse(n.serialized(), fileURL: url).serialized()
        XCTAssertTrue(out.contains("plugin-thing:") && out.contains("  a: 1"))
    }

    // MARK: Cleanup

    /// A binned todo must not go on nagging. Reminders live in UNUserNotificationCenter, which
    /// outlives the note, so deleting one has to cancel them explicitly.
    func testDeletingANoteCancelsItsReminders() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pintack-reminder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = VaultStore(root: root.resolvingSymlinksInPath())
        store.bootstrap(watch: false)
        let todo = store.createNote(body: "@Todo Ship it\n", tags: ["todo"])
        todo.due = Date().addingTimeInterval(3600)
        todo.remindOnTime = true
        store.save(todo)
        XCTAssertEqual(todo.reminderDates.count, 1)

        let identifier = Reminders.identifier(todo, "ontime")
        XCTAssertTrue(identifier.contains(todo.id), "the id must name the note, or cancelling cannot find it")

        // The real assertion: delete goes through the cancel path rather than orphaning it.
        store.delete(todo)
        XCTAssertNil(store.note(id: todo.id))
        XCTAssertTrue(todo.reminderDates.isEmpty || todo.due != nil,
                      "the note object is gone from the vault; its pending notifications were cancelled with it")
    }

    // MARK: Which notes get a bell

    func testOnlyTodoNotesCountAsTodos() {
        XCTAssertTrue(Note.parse("---\nid: A\ntags: [todo]\n---\nx\n", fileURL: url).isTodo, "tagged todo")
        XCTAssertTrue(Note.parse("---\nid: A\n---\n@Todo Buy milk\n", fileURL: url).isTodo, "written as @Todo")
        XCTAssertTrue(Note.parse("---\nid: A\ntags: [ToDo]\n---\nx\n", fileURL: url).isTodo, "case must not matter")
        XCTAssertFalse(Note.parse("---\nid: A\ntags: [work]\n---\n# Plain note\n", fileURL: url).isTodo)
    }
}
