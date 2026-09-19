import XCTest
@testable import PinTack

final class VaultStoreTests: VaultTestCase {

    // MARK: Create / save / reload

    func testBootstrapCreatesTheVaultLayoutAndOneWelcomeNoteOnly() throws {
        for d in ["attachments", ".pintack"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(d).path), d)
        }
        XCTAssertEqual(store.notes.count, 1)
        let welcome = try XCTUnwrap(store.notes.first)
        store.delete(welcome)                       // user deletes it...
        let second = VaultStore(root: root)
        second.bootstrap(watch: false)              // ...and relaunches
        XCTAssertEqual(second.notes.count, 0, "the welcome note must not come back")
    }

    func testCreatedNoteIsAReadableMarkdownFileWithTheDatePrefixedSlugName() throws {
        let n = store.createNote(body: "# Sprint Blockers!\n\n- [ ] one")
        XCTAssertTrue(n.fileURL.lastPathComponent.hasSuffix("-sprint-blockers.md"), n.fileURL.lastPathComponent)
        XCTAssertTrue(try read(n.fileURL).contains("# Sprint Blockers!"))
        XCTAssertTrue(try read(n.fileURL).hasPrefix("---\nid: \(n.id)\n"))
    }

    func testFilenameIsFrozenAtCreation() throws {
        let n = store.createNote(body: "# First title")
        let name = n.fileURL.lastPathComponent
        n.body = "# A completely different title"
        store.save(n)
        XCTAssertEqual(n.fileURL.lastPathComponent, name, "retitling must never rename the file. SPEC.md §3.4")
    }

    func testSaveThenReloadKeepsEverythingIncludingUnknownKeys() throws {
        let raw = "---\nid: KEEP1\ncreated: 2026-01-02T03:04:05Z\ntags: [a, b]\nplugin:\n  data:\n    - 1\n    - 2\n---\n# Note\n\nbody text\n"
        let url = try writeFile("2026-01-02-note.md", raw)
        store.loadAll()
        let note = try XCTUnwrap(store.notes.first { $0.id == "KEEP1" })
        note.body += "added\n"
        store.save(note)

        let fresh = VaultStore(root: root)
        fresh.loadAll()
        let reloaded = try XCTUnwrap(fresh.notes.first { $0.id == "KEEP1" })
        XCTAssertEqual(reloaded.body, "# Note\n\nbody text\nadded\n")
        XCTAssertEqual(reloaded.tags, ["a", "b"])
        XCTAssertTrue(try read(url).contains("plugin:\n  data:\n    - 1\n    - 2\n"))
    }

    func testSaveMergesInlineTagsIntoFrontmatter() throws {
        let n = store.createNote(body: "hello #Inbox and #work/todo")
        XCTAssertEqual(Set(n.tags), ["Inbox", "work/todo"])
        XCTAssertTrue(try read(n.fileURL).contains("tags: [Inbox, work/todo]"))
    }

    // MARK: Filenames

    func testSlugRules() {
        XCTAssertEqual(VaultStore.slug(from: "# Café: Crème Brûlée & Co."), "cafe-creme-brulee-co")
        XCTAssertEqual(VaultStore.slug(from: "   "), "untitled")
        XCTAssertEqual(VaultStore.slug(from: "日本語"), "untitled")
        XCTAssertEqual(VaultStore.slug(from: "a/b\\c:d"), "a-b-c-d")
        XCTAssertLessThanOrEqual(VaultStore.slug(from: String(repeating: "word ", count: 40)).count, 60)
        XCTAssertFalse(VaultStore.slug(from: String(repeating: "word ", count: 40)).hasSuffix("-"))
    }

    func testFilenameCollisionsGetNumericSuffixes() {
        let a = store.createNote(body: "# Same"), b = store.createNote(body: "# Same"), c = store.createNote(body: "# Same")
        XCTAssertTrue(a.fileURL.lastPathComponent.hasSuffix("-same.md"))
        XCTAssertTrue(b.fileURL.lastPathComponent.hasSuffix("-same-2.md"))
        XCTAssertTrue(c.fileURL.lastPathComponent.hasSuffix("-same-3.md"))
    }

    // MARK: Folders

    func testFoldersAreDirectoriesAndNotesCanMoveBetweenThem() throws {
        let n = store.createNote(body: "# Move me")
        XCTAssertEqual(store.folder(of: n), "")
        store.move(n, toFolder: "Work")
        XCTAssertEqual(store.folder(of: n), "Work")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Work").appendingPathComponent(n.fileURL.lastPathComponent).path))
        XCTAssertEqual(store.folders(), ["Work"])
        store.move(n, toFolder: "")
        XCTAssertEqual(store.folder(of: n), "")
    }

    func testFolderListingIgnoresReservedAndHiddenDirectories() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plugins/runner"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Personal/2026"), withIntermediateDirectories: true)
        XCTAssertEqual(store.folders(), ["Personal", "Personal/2026"])
    }

    func testMarkdownInReservedFoldersIsNotTreatedAsANote() throws {
        try writeFile("readme.md", "# plugin docs", in: "plugins/runner")
        try writeFile("x.md", "# attachment side file", in: "attachments")
        try writeFile("h.md", "# hidden", in: ".pintack")
        store.loadAll()
        XCTAssertEqual(store.notes.count, 1, "only the welcome note")
    }

    // MARK: Tags, search, duplicates

    func testNestedTagsCountUnderEveryAncestor() throws {
        let a = store.createNote(body: "x"); a.tags = ["work/northwind"]
        let b = store.createNote(body: "y"); b.tags = ["Work"]
        let counts = Dictionary(uniqueKeysWithValues: store.tagCounts().map { ($0.tag.lowercased(), $0.count) })
        XCTAssertEqual(counts["work"], 2)
        XCTAssertEqual(counts["work/northwind"], 1)
        XCTAssertTrue(store.matches(tag: "work", note: a))
        XCTAssertFalse(store.matches(tag: "work/northwind", note: b))
    }

    func testFullTextSearchFindsTitleBodyAndTagsWithPrefixMatching() throws {
        let a = store.createNote(body: "# Sprint blockers\nCert renewal on the build agent")
        let b = store.createNote(body: "# Groceries\noat milk, sourdough")
        b.tags = ["home"]; store.save(b)
        XCTAssertEqual(store.search("spri").map(\.id), [a.id])
        XCTAssertEqual(store.search("RENEWAL agent").map(\.id), [a.id])
        XCTAssertEqual(store.search("sourdough").map(\.id), [b.id])
        XCTAssertEqual(store.search("home").map(\.id), [b.id])
        XCTAssertTrue(store.search("nothingmatches").isEmpty)
        XCTAssertEqual(store.search("   ").count, store.notes.count, "blank query lists everything")
    }

    func testSearchSurvivesQuotesAndOperatorsInTheQuery() {
        _ = store.createNote(body: "# Quote \"test\"")
        XCTAssertNoThrow(store.search("\"unbalanced"))
        XCTAssertNoThrow(store.search("a AND OR NOT ("))
    }

    func testDuplicatedFilesGetADistinctID() throws {
        let raw = "---\nid: SAMEID\ncreated: 2026-01-01T00:00:00Z\n---\nfirst"
        try writeFile("2026-01-01-a.md", raw)
        try writeFile("2026-01-02-b.md", raw.replacingOccurrences(of: "2026-01-01", with: "2026-01-02"))
        store.loadAll()
        let ids = store.notes.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids are the canonical identity and must be unique. SPEC.md §3.4")
    }

    func testDuplicateNoteCopiesContentAndUnknownKeys() throws {
        let raw = "---\nid: ORIG\nplug: yes\n---\nbody"
        try writeFile("2026-01-01-orig.md", raw)
        store.loadAll()
        let orig = try XCTUnwrap(store.note(id: "ORIG"))
        let copy = store.duplicate(orig)
        XCTAssertNotEqual(copy.id, orig.id)
        XCTAssertEqual(copy.body, "body")
        XCTAssertTrue(try read(copy.fileURL).contains("plug: yes"))
    }

    // MARK: External edits (SPEC.md §3.7)

    func testExternalEditIsPickedUpSilentlyWhenThereAreNoUnsavedEdits() throws {
        let n = store.createNote(body: "# Original")
        let expect = expectation(forNotification: .noteDidChangeExternally, object: n)
        let edited = try read(n.fileURL).replacingOccurrences(of: "# Original", with: "# Edited elsewhere")
        try edited.write(to: n.fileURL, atomically: true, encoding: .utf8)
        store.handleExternalChanges([n.fileURL])
        wait(for: [expect], timeout: 1)
        XCTAssertEqual(n.body, "# Edited elsewhere")
    }

    func testOwnWritesAreNotMistakenForExternalEdits() throws {
        let n = store.createNote(body: "# Mine")
        var fired = false
        let token = NotificationCenter.default.addObserver(forName: .noteDidChangeExternally, object: nil, queue: nil) { _ in fired = true }
        defer { NotificationCenter.default.removeObserver(token) }
        store.save(n)
        store.handleExternalChanges([n.fileURL])
        XCTAssertFalse(fired)
    }

    func testAConflictIsReportedNotSilentlyOverwritten() throws {
        let n = store.createNote(body: "# Base")
        n.body = "# Unsaved local edit"
        SaveCoordinator.shared.scheduleSave(n)                  // pending, not yet on disk
        defer { SaveCoordinator.shared.discard(noteID: n.id) }

        let expect = expectation(forNotification: .vaultConflict, object: nil)
        let disk = try read(n.fileURL).replacingOccurrences(of: "# Base", with: "# Changed on disk")
        try disk.write(to: n.fileURL, atomically: true, encoding: .utf8)
        store.handleExternalChanges([n.fileURL])
        wait(for: [expect], timeout: 1)
        XCTAssertEqual(n.body, "# Unsaved local edit", "the local edit must not be replaced")
    }

    func testAFileDeletedExternallyRemovesTheNote() throws {
        let n = store.createNote(body: "# Doomed")
        let count = store.notes.count
        try FileManager.default.removeItem(at: n.fileURL)
        store.handleExternalChanges([n.fileURL])
        XCTAssertEqual(store.notes.count, count - 1)
    }

    func testANewFileAppearingExternallyBecomesANote() throws {
        let url = try writeFile("2026-05-05-from-windows.md", "---\r\nid: WIN1\r\n---\r\nwritten on windows\r\n")
        store.handleExternalChanges([url])
        let n = try XCTUnwrap(store.note(id: "WIN1"))
        XCTAssertEqual(n.body, "written on windows\n")
        XCTAssertTrue(n.usesCRLF)
    }

    // MARK: Attachments (SPEC.md §7)

    func testAttachmentsAreWrittenWithTimestampNamesAndOrphansAreListedNotDeleted() throws {
        let path = try XCTUnwrap(store.writeAttachment(Data([1, 2, 3]), ext: "PNG"))
        XCTAssertTrue(path.hasPrefix("attachments/") && path.hasSuffix(".png"), path)
        let second = try XCTUnwrap(store.writeAttachment(Data([4]), ext: "png"))
        XCTAssertNotEqual(path, second, "two attachments in the same second must not collide")

        _ = store.createNote(body: "![](\(path))")
        let orphans = store.orphanedAttachments().map(\.lastPathComponent)
        XCTAssertEqual(orphans, [String(second.dropFirst("attachments/".count))])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.attachmentsURL.appendingPathComponent(orphans[0]).path), "never deleted automatically")
    }

    func testAttachmentExtensionsAreSanitized() throws {
        let p = try XCTUnwrap(store.writeAttachment(Data([1]), ext: "../../evil"))
        XCTAssertFalse(p.contains(".."))
        XCTAssertTrue(p.hasPrefix("attachments/"))
    }
}
