import XCTest
import Carbon.HIToolbox
@testable import PinTack

final class ShortcutAndSettingsTests: VaultTestCase {

    func testEveryActionHasAUniqueDefaultBinding() {
        let combos = ShortcutAction.allCases.map(\.defaultCombo)
        XCTAssertEqual(Set(combos).count, combos.count, "two actions share a default key combination")
    }

    func testSpecDefaultsAreBoundAsDocumented() {
        // SPEC.md §10.2
        XCTAssertEqual(ShortcutAction.newNote.defaultCombo.display, "⌥⌘N")
        XCTAssertEqual(ShortcutAction.newTodo.defaultCombo.display, "⌥⌘L")
        XCTAssertEqual(ShortcutAction.toggleAllNotes.defaultCombo.display, "⌥⌘H")
        XCTAssertEqual(ShortcutAction.pin.defaultCombo.display, "⌥⌘P")
        XCTAssertEqual(ShortcutAction.toggleMode.defaultCombo.display, "⌥⌘M")
        XCTAssertEqual(ShortcutAction.color6.defaultCombo.display, "⌥⌘6")
    }

    func testOnlyTheFourAppWideActionsAreGlobal() {
        // ⌥⌘W / ⌥⌘H style combos registered system-wide would steal them from every other app.
        XCTAssertEqual(Set(ShortcutAction.allCases.filter(\.isGlobal)), [.newNote, .newTodo, .toggleAllNotes, .autoArrange])
    }

    func testRebindingPersistsAndConflictsAreDetected() throws {
        let s = ShortcutStore()
        s.load(from: store.metaURL)
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_J), modifiers: KeyCombo.optCmd)
        XCTAssertNil(s.conflict(for: combo, excluding: .pin))
        s.set(combo, for: .pin)
        XCTAssertEqual(s.combo(for: .pin), combo)
        XCTAssertEqual(s.conflict(for: combo, excluding: .collapse), .pin)
        XCTAssertNil(s.conflict(for: combo, excluding: .pin), "an action does not conflict with itself")

        let reloaded = ShortcutStore()
        reloaded.load(from: store.metaURL)
        XCTAssertEqual(reloaded.combo(for: .pin), combo)
        reloaded.set(nil, for: .pin)
        XCTAssertEqual(reloaded.combo(for: .pin), ShortcutAction.pin.defaultCombo)
    }

    func testSettingsPersistAndPluginKeysSurvive() throws {
        let file = store.metaURL.appendingPathComponent("settings.json")
        let seed: [String: Any] = ["outlineWidth": 2.5, "spellcheck": true,
                                   "runner": ["timeout": 45, "shell": ""], "somePlugin": ["a": [1, 2]]]
        try JSONSerialization.data(withJSONObject: seed).write(to: file)

        let s = AppSettings()
        s.load(from: store.metaURL)
        XCTAssertEqual(s.outlineWidth, 2.5); XCTAssertTrue(s.spellcheck)
        s.fontSize = 15
        s.save()

        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(saved["fontSize"] as? Double, 15)
        XCTAssertEqual((saved["runner"] as? [String: Any])?["timeout"] as? Int, 45, "plugin settings must survive. SPEC.md §12.2")
        XCTAssertNotNil(saved["somePlugin"])
    }

    func testSettingsValuesAreClampedToSafeRanges() throws {
        try JSONSerialization.data(withJSONObject: ["defaultOpacity": 0.0, "outlineWidth": 99, "fontSize": 2])
            .write(to: store.metaURL.appendingPathComponent("settings.json"))
        let s = AppSettings()
        s.load(from: store.metaURL)
        XCTAssertEqual(s.defaultOpacity, 0.3, accuracy: 0.001)
        XCTAssertEqual(s.outlineWidth, 3, accuracy: 0.001)
        XCTAssertEqual(s.fontSize, 9, accuracy: 0.001)
    }

    func testAutomaticTextContrastForAnyColor() {
        let n = Note(fileURL: URL(fileURLWithPath: "/tmp/x.md"))
        n.colorHex = "#FFE38A"; XCTAssertTrue(n.isDarkText, "dark text on butter")
        n.colorHex = "#2C2C32"; XCTAssertFalse(n.isDarkText, "light text on graphite")
        n.colorHex = "#000000"; XCTAssertFalse(n.isDarkText)
        n.colorHex = "#FFFFFF"; XCTAssertTrue(n.isDarkText)
        n.theme = "dark"; XCTAssertFalse(n.isDarkText, "override wins")
    }
}
