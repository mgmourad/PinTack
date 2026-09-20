import XCTest
@testable import PinTack

/// Palette modes, random new-note color, todo notes, and the action-bar settings.
final class FeatureTests: VaultTestCase {

    // MARK: Palette modes (Auto / Dark / Light)

    func testEveryPaletteHasSixDistinctSwatches() {
        for set in [NotePalette.auto, NotePalette.dark, NotePalette.light] {
            XCTAssertEqual(set.count, 6)
            XCTAssertEqual(Set(set.map(\.hex)).count, 6)
        }
        XCTAssertEqual(NotePalette.set(for: "auto").map(\.hex), NotePalette.auto.map(\.hex))
        XCTAssertEqual(NotePalette.set(for: "nonsense").map(\.hex), NotePalette.auto.map(\.hex), "unknown mode falls back to auto")
    }

    func testDarkSwatchesAlwaysGetLightTextAndLightSwatchesDarkText() {
        // The user has no control over text color, so the palettes themselves must be safe.
        for swatch in NotePalette.dark {
            let n = Note(fileURL: URL(fileURLWithPath: "/tmp/x.md")); n.colorHex = swatch.hex
            XCTAssertFalse(n.isDarkText, "\(swatch.name) \(swatch.hex) is a dark swatch and needs light text")
        }
        for swatch in NotePalette.light {
            let n = Note(fileURL: URL(fileURLWithPath: "/tmp/x.md")); n.colorHex = swatch.hex
            XCTAssertTrue(n.isDarkText, "\(swatch.name) \(swatch.hex) is a light swatch and needs dark text")
        }
    }

    func testSwitchingModeCarriesAPresetAcrossToTheSameNamedSwatch() {
        XCTAssertEqual(NotePalette.remap("#FFE38A", toMode: "dark"), "#A88418", "Butter → deep butter")
        XCTAssertEqual(NotePalette.remap("#FFE38A", toMode: "light"), "#FFF1B8")
        XCTAssertEqual(NotePalette.remap("#A88418", toMode: "auto"), "#FFE38A", "dark → auto returns to the standard set")
        XCTAssertEqual(NotePalette.remap("#a88418", toMode: "light"), "#FFF1B8", "hex matching ignores case")
        XCTAssertEqual(NotePalette.remap("#2C2C32", toMode: "light"), "#F5F5F7", "Graphite ↔ Cloud")
        XCTAssertNil(NotePalette.remap("#123456", toMode: "dark"), "a custom color is left alone")
    }

    func testModeRoundTripsThroughTheFile() throws {
        let n = store.createNote(body: "x"); n.theme = "dark"; n.colorHex = "#A88418"; store.save(n)
        let fresh = VaultStore(root: root); fresh.loadAll()
        let back = try XCTUnwrap(fresh.note(id: n.id))
        XCTAssertEqual(back.theme, "dark"); XCTAssertEqual(back.colorHex, "#A88418")
    }

    // MARK: New-note color: default vs random

    func testDefaultNewNoteColorIsFixedAndRandomStaysWithinThePastels() {
        let s = AppSettings()
        s.defaultColorHex = "#A3D5FF"
        s.newNoteColor = "default"
        XCTAssertEqual((0..<20).map { _ in s.noteDefaults.colorHex }, Array(repeating: "#A3D5FF", count: 20))

        s.newNoteColor = "random"
        let draws = (0..<200).map { _ in s.noteDefaults.colorHex }
        XCTAssertGreaterThan(Set(draws).count, 20, "random must actually vary (it is no longer a pick from five fixed colors)")
        XCTAssertFalse(draws.contains("#2C2C32"), "random never picks graphite")
        let n = Note(fileURL: URL(fileURLWithPath: "/tmp/x.md"))
        XCTAssertTrue(draws.allSatisfy { n.colorHex = $0; return n.isDarkText }, "random colors always take dark text")
    }

    // MARK: Todo notes

    func testATodoNoteStartsAsAtTodoAndIsTaggedTodoInTheFile() throws {
        let n = store.createNote(body: "@Todo ", tags: ["todo"])
        XCTAssertEqual(n.title, "@Todo")
        XCTAssertEqual(n.tags, ["todo"])
        let text = try read(n.fileURL)
        XCTAssertTrue(text.contains("tags: [todo]"), text)
        XCTAssertTrue(text.hasSuffix("---\n@Todo "))
        XCTAssertTrue(n.fileURL.lastPathComponent.hasSuffix("-todo.md"), n.fileURL.lastPathComponent)
    }

    func testATodoNoteKeepsItsTagAndTheTypedTitleAfterEditing() throws {
        let n = store.createNote(body: "@Todo ", tags: ["todo"])
        n.body = "@Todo Groceries\n\n- [ ] milk\n- [x] eggs\n"
        store.save(n)
        let fresh = VaultStore(root: root); fresh.loadAll()
        let back = try XCTUnwrap(fresh.note(id: n.id))
        XCTAssertEqual(back.title, "@Todo Groceries")
        XCTAssertEqual(back.tags, ["todo"])
        XCTAssertEqual(store.tagCounts().first { $0.tag == "todo" }?.count, 1)
        XCTAssertEqual(fresh.search("groceries").map(\.id), [n.id], "searchable by the typed title")
    }

    // MARK: Action-bar and font settings

    func testNewSettingsPersistAndAreClamped() throws {
        let s = AppSettings()
        s.load(from: store.metaURL)
        XCTAssertEqual(s.fontFamily, "Comic Sans MS", "Comic Sans is the default note font")
        XCTAssertTrue(s.actionBarAutoCollapse)
        XCTAssertEqual(s.bulletEmoji, "")

        s.newNoteColor = "random"; s.actionBarAutoCollapse = false; s.actionBarCollapseSeconds = 9; s.bulletEmoji = "🍎"
        s.save()
        let again = AppSettings(); again.load(from: store.metaURL)
        XCTAssertEqual(again.newNoteColor, "random"); XCTAssertFalse(again.actionBarAutoCollapse)
        XCTAssertEqual(again.actionBarCollapseSeconds, 9); XCTAssertEqual(again.bulletEmoji, "🍎")

        let file = store.metaURL.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["actionBarCollapseSeconds": 9999]).write(to: file)
        let clamped = AppSettings(); clamped.load(from: store.metaURL)
        XCTAssertEqual(clamped.actionBarCollapseSeconds, 30)
        try JSONSerialization.data(withJSONObject: ["actionBarCollapseSeconds": 0]).write(to: file)
        let low = AppSettings(); low.load(from: store.metaURL)
        XCTAssertEqual(low.actionBarCollapseSeconds, 2)
    }

    func testAnExplicitFontChoiceIsRespected() throws {
        try JSONSerialization.data(withJSONObject: ["fontFamily": ""]).write(to: store.metaURL.appendingPathComponent("settings.json"))
        let s = AppSettings(); s.load(from: store.metaURL)
        XCTAssertEqual(s.fontFamily, "", "'System' must stay selectable")
    }
}

/// Renaming, folders and random colors (second round of owner feedback).
final class RenameFolderColorTests: VaultTestCase {

    // MARK: Renaming (All Notes pencil and the header both rewrite the title line)

    private func note(_ body: String) -> Note { Note(fileURL: URL(fileURLWithPath: "/tmp/x.md"), body: body) }

    func testRenameKeepsTheHeadingLevel() {
        let n = note("## Old title\n\nbody\n"); n.retitle(to: "  New title ")
        XCTAssertEqual(n.body, "## New title\n\nbody\n")
        XCTAssertEqual(n.title, "New title")
    }

    func testRenameAToDoKeepsItsMarker() {
        let n = note("@Todo Groceries\n\n- [ ] milk\n"); n.retitle(to: "Weekend shop")
        XCTAssertEqual(n.body, "@Todo Weekend shop\n\n- [ ] milk\n")
        n.retitle(to: "@Todo Again"); XCTAssertEqual(n.body.components(separatedBy: "\n")[0], "@Todo Again", "no doubled marker")
    }

    func testRenamingAPlainFirstLineNeverDeletesUserText() {
        let n = note("buy milk\n- eggs\n"); n.retitle(to: "Shopping")
        XCTAssertEqual(n.body, "# Shopping\n\nbuy milk\n- eggs\n")
    }

    func testRenameSkipsLeadingBlankLinesAndHandlesEmptyNotes() {
        let n = note("\n\n# Real title\nx"); n.retitle(to: "Changed"); XCTAssertEqual(n.body, "\n\n# Changed\nx")
        let e = note(""); e.retitle(to: "First"); XCTAssertEqual(e.body, "# First\n")
        let blank = note("Keep"); blank.retitle(to: "   "); XCTAssertEqual(blank.body, "Keep", "an empty name changes nothing")
    }

    func testRenameThroughTheStoreSurvivesAReload() throws {
        let n = store.createNote(body: "# Before\n\ntext")
        n.retitle(to: "After"); store.save(n)
        let fresh = VaultStore(root: root); fresh.loadAll()
        XCTAssertEqual(try XCTUnwrap(fresh.note(id: n.id)).title, "After")
        XCTAssertTrue(n.fileURL.lastPathComponent.hasSuffix("-before.md"), "the file name is frozen at creation. SPEC.md §3.4")
    }

    // MARK: Folders

    func testCreateFolderMakesADirectoryThatIsListedEvenWhenEmpty() throws {
        XCTAssertEqual(store.createFolder("Work"), "Work")
        XCTAssertEqual(store.createFolder("Work/2026"), "Work/2026")
        XCTAssertEqual(store.folders(), ["Work", "Work/2026"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Work/2026").path))
    }

    func testFolderNamesAreSanitizedAndReservedNamesRefused() {
        XCTAssertEqual(store.createFolder("a:b\\c"), "a-b-c")
        XCTAssertEqual(store.createFolder("  ..hidden.. "), "hidden")
        XCTAssertNil(store.createFolder("attachments"))
        XCTAssertNil(store.createFolder("Plugins/x"), "reserved names are refused case-insensitively")
        XCTAssertNil(store.createFolder("   "))
        XCTAssertNil(store.createFolder("../.."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
    }

    func testAddSelectionToAFolderMovesEveryFile() throws {
        let a = store.createNote(body: "# A"), b = store.createNote(body: "# B"), c = store.createNote(body: "# C")
        let folder = try XCTUnwrap(store.createFolder("Project"))
        [a, b].forEach { store.move($0, toFolder: folder) }
        XCTAssertEqual([a, b, c].map { store.folder(of: $0) }, ["Project", "Project", ""])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.fileURL.path) && FileManager.default.fileExists(atPath: b.fileURL.path))
    }

    // MARK: Random colors

    private func hue(of hex: String) -> Double {
        var h: CGFloat = 0
        NSColor(hex: hex)!.usingColorSpace(.sRGB)!.getHue(&h, saturation: nil, brightness: nil, alpha: nil)
        return Double(h)
    }

    func testRandomColorsAreVariedNeverSimilarTwiceInARowAndAlwaysReadable() {
        var previous: String?
        var seen = Set<String>()
        for _ in 0..<400 {
            let hex = NotePalette.randomPastel
            seen.insert(hex)
            let n = Note(fileURL: URL(fileURLWithPath: "/tmp/x.md")); n.colorHex = hex
            XCTAssertTrue(n.isDarkText, "\(hex) is a pastel and must take dark text")
            if let previous {
                let d = abs(hue(of: hex) - hue(of: previous)), wheel = min(d, 1 - d)
                XCTAssertGreaterThan(wheel, 50.0 / 360.0, "\(previous) then \(hex) are too alike")
            }
            previous = hex
        }
        XCTAssertGreaterThan(seen.count, 100, "random must not be a handful of fixed colors (was 5)")
    }
}
