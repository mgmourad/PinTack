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
        let pastels = Set(NotePalette.auto.prefix(5).map(\.hex))
        let draws = (0..<200).map { _ in s.noteDefaults.colorHex }
        XCTAssertTrue(draws.allSatisfy { pastels.contains($0) }, "random never picks graphite or a custom color")
        XCTAssertGreaterThan(Set(draws).count, 1, "random must actually vary")
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
