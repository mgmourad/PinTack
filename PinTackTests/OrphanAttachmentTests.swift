import XCTest
@testable import PinTack

/// "Find unused attachments" offers to delete the user's pictures, so what it calls unused has to
/// be right. A false positive here is data loss.
final class OrphanAttachmentTests: VaultTestCase {

    /// The shared fixture bootstraps a welcome note. These tests count what they wrote, so start
    /// from an empty vault instead.
    override func setUpWithError() throws {
        try super.setUpWithError()
        for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "md" {
            try FileManager.default.removeItem(at: file)
        }
        store.loadAll()
        XCTAssertTrue(store.notes.isEmpty, "these tests start from an empty vault")
    }

    @discardableResult
    private func attachment(_ name: String, bytes: Int = 64) throws -> URL {
        try FileManager.default.createDirectory(at: store.attachmentsURL, withIntermediateDirectories: true)
        let url = store.attachmentsURL.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    func testAnAttachmentANoteRefersToIsNotOrphaned() throws {
        try attachment("keep-me.png")
        try writeFile("note.md", "---\nid: A1\n---\n# Shot\n\n![x](attachments/keep-me.png)\n")
        store.loadAll()

        let result = store.orphanedAttachments()
        XCTAssertEqual(result.scannedNotes, 1)
        XCTAssertTrue(result.orphans.isEmpty, "a referenced picture must never be offered for deletion")
    }

    func testAnUnreferencedAttachmentIsListedWithItsSize() throws {
        try attachment("nobody-wants-me.png", bytes: 1234)
        try writeFile("note.md", "---\nid: A1\n---\n# Empty\n")
        store.loadAll()

        let result = store.orphanedAttachments()
        XCTAssertEqual(result.orphans.map(\.name), ["nobody-wants-me.png"])
        XCTAssertEqual(result.orphans.first?.bytes, 1234)
    }

    /// The scan reads the .md files on DISK, not the notes held in memory. A note that failed to
    /// load, or one the app has not opened, must still protect its pictures.
    func testANoteThatIsNotLoadedInMemoryStillProtectsItsAttachment() throws {
        try attachment("referenced-only-on-disk.png")
        try writeFile("unloaded.md", "---\nid: A1\n---\n![x](attachments/referenced-only-on-disk.png)\n")
        // Deliberately do NOT load it, so `notes` stays empty and only the disk scan can save it.
        XCTAssertTrue(store.notes.isEmpty)

        let result = store.orphanedAttachments()
        XCTAssertEqual(result.scannedNotes, 1, "the file on disk must be read even when nothing is loaded")
        XCTAssertTrue(result.orphans.isEmpty, "an unloaded note's picture is not rubbish")
    }

    /// Unsaved edits exist only in memory, so a picture just pasted into an open note is protected
    /// before the file has been written.
    func testAPictureInAnUnsavedEditIsProtected() throws {
        try attachment("just-pasted.png")
        try writeFile("note.md", "---\nid: A1\n---\n# Nothing yet\n")
        store.loadAll()
        store.notes.first?.body = "# Nothing yet\n\n![x](attachments/just-pasted.png)\n"   // not saved

        XCTAssertTrue(store.orphanedAttachments().orphans.isEmpty)
    }

    /// With no notes at all there is nothing to compare against, so EVERY attachment would look
    /// unused. The count is what lets the sheet refuse to act. See OrphanSheet.
    func testAVaultWithNoNotesReportsZeroScannedSoTheSheetCanRefuse() throws {
        try attachment("a.png")
        try attachment("b.png")
        store.loadAll()

        let result = store.orphanedAttachments()
        XCTAssertEqual(result.scannedNotes, 0, "the sheet keys off this to refuse deleting anything")
        XCTAssertEqual(result.orphans.count, 2)
    }

    func testTheOldCopyLeftBehindByCroppingIsFound() throws {
        try attachment("2026-09-20-0101.png", bytes: 5000)      // the original
        try attachment("2026-09-20-0102.png", bytes: 3000)      // the crop the note now points at
        try writeFile("note.md", "---\nid: A1\n---\n![shot|318](attachments/2026-09-20-0102.png)\n")
        store.loadAll()

        let result = store.orphanedAttachments()
        XCTAssertEqual(result.orphans.map(\.name), ["2026-09-20-0101.png"])
    }

    func testNotesInSubfoldersCountToo() throws {
        try attachment("in-a-folder.png")
        try writeFile("deep.md", "---\nid: A1\n---\n![x](attachments/in-a-folder.png)\n", in: "Work/2026")
        store.loadAll()

        XCTAssertTrue(store.orphanedAttachments().orphans.isEmpty)
    }
}
