import XCTest
@testable import PinTack

final class ArchiveTests: VaultTestCase {

    func testExportThenImportIntoAnEmptyVaultKeepsUnknownKeysBodiesAndAttachments() throws {
        let raw = "---\nid: EXP1\ncreated: 2026-01-01T00:00:00Z\nplug:\n  n: [1, 2]\n---\n# Export me\n\n![](attachments/a.png)\n"
        try writeFile("2026-01-01-export-me.md", raw, in: "Work")
        try Data([9, 8, 7]).write(to: root.appendingPathComponent("attachments/a.png"))
        store.loadAll()
        let archive = try ArchiveIO.archiveData(store: store)

        let otherRoot = root.deletingLastPathComponent().appendingPathComponent("pintack-import-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let dest = VaultStore(root: otherRoot)
        dest.bootstrap(watch: false)
        let before = dest.notes.count
        let result = try ArchiveIO.importArchive(from: archive, store: dest, askOnConflict: { _ in .keep })

        XCTAssertEqual(result.added, store.notes.count)
        XCTAssertEqual(dest.notes.count, before + store.notes.count)
        let imported = try XCTUnwrap(dest.note(id: "EXP1"))
        XCTAssertEqual(imported.body, "# Export me\n\n![](attachments/a.png)\n")
        XCTAssertTrue(imported.serialized().contains("plug:\n  n: [1, 2]\n"))
        XCTAssertEqual(dest.folder(of: imported), "Work")
        XCTAssertEqual(try Data(contentsOf: otherRoot.appendingPathComponent("attachments/a.png")), Data([9, 8, 7]))
    }

    func testImportMergesByIDAndHonoursTheConflictChoice() throws {
        let n = store.createNote(body: "# Mine")
        let archive = try ArchiveIO.archiveData(store: store)

        var asked = 0
        let keep = try ArchiveIO.importArchive(from: archive, store: store, askOnConflict: { _ in asked += 1; return .keep })
        XCTAssertEqual(asked, store.notes.count)
        XCTAssertEqual(keep.skipped, store.notes.count)

        let count = store.notes.count
        let dup = try ArchiveIO.importArchive(from: archive, store: store, askOnConflict: { $0.id == n.id ? .duplicate : .keep })
        XCTAssertEqual(dup.added, 1)
        XCTAssertEqual(store.notes.count, count + 1)
        XCTAssertEqual(Set(store.notes.map(\.id)).count, store.notes.count, "duplicate must get a new id")
    }

    func testRejectsANonArchive() {
        XCTAssertThrowsError(try ArchiveIO.importArchive(from: Data("{\"hello\": 1}".utf8), store: store, askOnConflict: { _ in .keep }))
        XCTAssertThrowsError(try ArchiveIO.importArchive(from: Data("not json".utf8), store: store, askOnConflict: { _ in .keep }))
    }

    /// An archive is untrusted input (someone can send you one). It must not be able to
    /// write outside the vault or into reserved places.
    func testHostileArchivePathsAreRefused() throws {
        let bad = ["../escape.md", "/etc/evil.md", "a/../../escape.md", ".pintack/trust.json.md", "attachments/x.md",
                   "plugins/runner/main.md", "notes.txt", "Work/.hidden.md", ""]
        for p in bad { XCTAssertNil(ArchiveIO.safeDestination(p, in: root), "should refuse \(p)") }
        XCTAssertEqual(ArchiveIO.safeDestination("Work/a.md", in: root)?.path, root.appendingPathComponent("Work/a.md").path)
        XCTAssertNotNil(ArchiveIO.safeDestination("Personal/2026/b.MD", in: root))

        let archive: [String: Any] = ["app": "PinTack", "version": 1, "notes": [
            ["id": "X", "path": "../../pwned.md", "content": "---\nid: X\n---\nbad"],
            ["id": "Y", "path": "good.md", "content": "---\nid: Y\n---\nok"]], "attachments": [
            ["name": "../pwned.png", "data": Data([1]).base64EncodedString()]]]
        let data = try JSONSerialization.data(withJSONObject: archive)
        let r = try ArchiveIO.importArchive(from: data, store: store, askOnConflict: { _ in .keep })
        XCTAssertEqual(r.added, 1); XCTAssertEqual(r.skipped, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("pwned.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("pwned.png").path))
        XCTAssertNotNil(store.note(id: "Y")); XCTAssertNil(store.note(id: "X"))
    }
}
