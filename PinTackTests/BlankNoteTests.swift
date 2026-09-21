import XCTest
@testable import PinTack

/// Closing a blank note discards its file (owner decision, 2026-09-21). This ends in a deleted
/// file, so every way a note can hold something worth keeping gets its own test.
final class BlankNoteTests: VaultTestCase {

    private func exists(_ note: Note) -> Bool { FileManager.default.fileExists(atPath: note.fileURL.path) }

    func testAnUntouchedNoteIsDiscarded() {
        let note = store.createNote()
        XCTAssertTrue(exists(note))
        XCTAssertTrue(store.discardIfBlank(note))
        XCTAssertFalse(exists(note), "a change of mind after ⌥⌘N must not leave a file behind")
        XCTAssertNil(store.note(id: note.id))
    }

    func testAnUntouchedTodoIsDiscardedToo() {
        // What New Todo makes: the @Todo marker, and the todo tag it adds by itself.
        let todo = store.createNote(body: "@Todo ", tags: ["todo"])
        XCTAssertTrue(todo.isBlank)
        XCTAssertTrue(store.discardIfBlank(todo))
        XCTAssertFalse(exists(todo))
    }

    func testWhitespaceIsNotContent() {
        XCTAssertTrue(store.createNote(body: "  \n\n\t ").isBlank)
    }

    // Each of these is somebody's data.

    func testWordsKeepIt() {
        let note = store.createNote(body: "x")
        XCTAssertFalse(store.discardIfBlank(note))
        XCTAssertTrue(exists(note))
    }

    func testATodoWithATitleKeepsIt() {
        XCTAssertFalse(store.createNote(body: "@Todo Rotate the certs", tags: ["todo"]).isBlank)
    }

    func testATagTheUserAddedKeepsIt() {
        let note = store.createNote(tags: ["intune"])
        XCTAssertFalse(store.discardIfBlank(note))
        XCTAssertTrue(exists(note))
    }

    func testANameOfItsOwnKeepsIt() {
        let note = store.createNote()
        note.customTitle = "Parking spot"
        store.save(note)
        XCTAssertFalse(store.discardIfBlank(note))
    }

    func testATemplateKeepsIt() {
        let note = store.createNote()
        note.templateName = "empty-form"
        store.save(note)
        XCTAssertFalse(store.discardIfBlank(note))
    }

    func testAReminderKeepsIt() {
        let note = store.createNote(body: "@Todo ", tags: ["todo"])
        note.due = Date().addingTimeInterval(3600)
        store.save(note)
        XCTAssertFalse(store.discardIfBlank(note))
    }

    func testSomethingAPluginStoredKeepsIt() throws {
        // Unknown frontmatter belongs to plugins. Losing it is data loss (CLAUDE.md constraint 4).
        let url = try writeFile("plugin.md", "---\nid: plug-1\nrunner-last-exit: 0\n---\n")
        store.loadAll()
        let note = try XCTUnwrap(store.notes.first { $0.fileURL.standardizedFileURL == url.standardizedFileURL })
        XCTAssertFalse(note.isBlank)
        XCTAssertFalse(store.discardIfBlank(note))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testWordsOnDiskThatTheAppHasNotReadYetKeepIt() throws {
        // Blank in memory, but another app (or a sync) has just written into the file.
        let note = store.createNote()
        try "Written in another editor a moment ago".write(to: note.fileURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(note.isBlank, "the app has not seen the edit yet")
        XCTAssertFalse(store.discardIfBlank(note))
        XCTAssertEqual(try read(note.fileURL), "Written in another editor a moment ago",
                       "a close must never throw away words that are on disk")
    }
}
