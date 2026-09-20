import AppKit
import Carbon.HIToolbox

/// A key plus modifiers, stored in Carbon terms so it maps straight onto
/// `RegisterEventHotKey`. SPEC.md §10.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32          // Carbon: cmdKey | shiftKey | optionKey | controlKey

    static let optCmd = UInt32(cmdKey | optionKey)

    static func alt(_ key: Int) -> KeyCombo { KeyCombo(keyCode: UInt32(key), modifiers: optCmd) }
    /// ⌥⇧ combinations, for the second rank of window shortcuts.
    static func optShift(_ key: Int) -> KeyCombo {
        KeyCombo(keyCode: UInt32(key), modifiers: UInt32(optionKey | shiftKey))
    }

    /// Modifiers of an AppKit event, in Carbon terms.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    init(event: NSEvent) {
        self.init(keyCode: UInt32(event.keyCode),
                  modifiers: KeyCombo.carbonModifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask)))
    }

    /// Parses "Alt+Cmd+R" / "Ctrl+Shift+K" (as a plugin manifest may write a default hotkey).
    /// Returns nil unless there is one recognised modifier and exactly one recognised key.
    static func parse(_ text: String) -> KeyCombo? {
        var mods: UInt32 = 0
        var key: UInt32?
        for raw in text.split(whereSeparator: { $0 == "+" || $0 == "-" }) {
            switch raw.lowercased() {
            case "cmd", "command", "meta", "mod": mods |= UInt32(cmdKey)
            case "alt", "option", "opt":          mods |= UInt32(optionKey)
            case "shift":                         mods |= UInt32(shiftKey)
            case "ctrl", "control":               mods |= UInt32(controlKey)
            default:
                guard key == nil, let code = (0..<128).first(where: { keyName(UInt32($0)).lowercased() == raw.lowercased() && !keyName(UInt32($0)).hasPrefix("Key") })
                else { return nil }
                key = UInt32(code)
            }
        }
        guard let key, mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        return KeyCombo(keyCode: key, modifiers: mods)
    }

    /// e.g. "⌥⌘N"
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyCombo.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let table: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
            kVK_ANSI_9: "9", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        ]
        return table[Int(code)] ?? "Key\(code)"
    }
}

/// Every bindable action. Defaults are SPEC.md §10.2, plus the extras the
/// prototype shows (opacity, import, the shortcut list).
enum ShortcutAction: String, CaseIterable, Codable {
    case newNote, newTodo, toggleAllNotes, autoArrange, quickCapture
    case allNotesByTag, showTemplates, showTodos, showAllOnDesktop, deleteNote
    case pin, collapse, close, toggleMode, emoji, freeze
    case color1, color2, color3, color4, color5, color6
    case toggleCorners, lessOpaque, moreOpaque
    case exportAll, importArchive, showShortcuts

    var title: String {
        switch self {
        case .newNote: return "New note"
        case .newTodo: return "New todo note"
        case .toggleAllNotes: return "Show / hide All Notes"
        case .autoArrange: return "Auto-arrange notes"
        case .quickCapture: return "New note from the clipboard"
        case .allNotesByTag: return "All Notes, by tag"
        case .showTemplates: return "All Notes, templates"
        case .showTodos: return "All Notes, todos"
        case .showAllOnDesktop: return "Show every note on the desktop"
        case .deleteNote: return "Delete focused note" 
        case .pin: return "Pin / unpin focused note"
        case .collapse: return "Collapse / expand focused note"
        case .freeze: return "Freeze / thaw focused note"
        case .close: return "Close focused note"
        case .toggleMode: return "Toggle Live Preview / Source"
        case .emoji: return "Emoji picker"
        case .color1: return "Note color 1 (Butter)"
        case .color2: return "Note color 2 (Peach)"
        case .color3: return "Note color 3 (Mint)"
        case .color4: return "Note color 4 (Sky)"
        case .color5: return "Note color 5 (Lilac)"
        case .color6: return "Note color 6 (Graphite)"
        case .toggleCorners: return "Round / square corners"
        case .lessOpaque: return "Less opaque"
        case .moreOpaque: return "More opaque"
        case .exportAll: return "Export all notes"
        case .importArchive: return "Import archive"
        case .showShortcuts: return "Show shortcut list"
        }
    }

    var group: String {
        switch self {
        case .newNote, .newTodo, .close, .pin, .collapse, .toggleMode, .freeze: return "Notes"
        case .color1, .color2, .color3, .color4, .color5, .color6, .emoji, .lessOpaque, .moreOpaque, .toggleCorners: return "Appearance"
        case .toggleAllNotes, .autoArrange, .showShortcuts: return "Windows"
        case .allNotesByTag, .showTemplates, .showTodos, .showAllOnDesktop: return "Windows"
        case .deleteNote: return "Notes" 
        case .quickCapture: return "Notes"
        case .exportAll, .importArchive: return "Data"
        }
    }

    /// Global actions are registered with Carbon and fire from any app. The rest
    /// act on the focused note, so they only fire while PinTack has a key
    /// window. Registering ⌥⌘W or ⌥⌘H system-wide would steal them from every
    /// other application, which is a worse trade than the spec's table implies.
    var isGlobal: Bool {
        switch self {
        case .newNote, .newTodo, .toggleAllNotes, .autoArrange, .quickCapture,
             .allNotesByTag, .showTemplates, .showTodos, .showAllOnDesktop: return true
        default: return false
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .newNote: return .alt(kVK_ANSI_N)
        case .newTodo: return .alt(kVK_ANSI_L)
        case .toggleAllNotes: return .alt(kVK_ANSI_H)
        case .autoArrange: return .alt(kVK_ANSI_A)
        case .quickCapture: return .alt(kVK_ANSI_C)
        case .allNotesByTag: return .alt(kVK_ANSI_T)
        case .deleteNote: return .alt(kVK_ANSI_D)
        case .showTemplates: return .optShift(kVK_ANSI_2)
        case .showTodos: return .optShift(kVK_ANSI_T)
        case .showAllOnDesktop: return .optShift(kVK_ANSI_Equal)
        case .pin: return .alt(kVK_ANSI_P)
        case .collapse: return .alt(kVK_ANSI_K)
        case .freeze: return .alt(kVK_ANSI_F)
        case .close: return .alt(kVK_ANSI_W)
        case .toggleMode: return .alt(kVK_ANSI_M)
        case .emoji: return .alt(kVK_ANSI_E)
        case .color1: return .alt(kVK_ANSI_1)
        case .color2: return .alt(kVK_ANSI_2)
        case .color3: return .alt(kVK_ANSI_3)
        case .color4: return .alt(kVK_ANSI_4)
        case .color5: return .alt(kVK_ANSI_5)
        case .color6: return .alt(kVK_ANSI_6)
        case .toggleCorners: return .alt(kVK_ANSI_R)
        case .lessOpaque: return .alt(kVK_ANSI_Comma)
        case .moreOpaque: return .alt(kVK_ANSI_Period)
        case .exportAll: return .alt(kVK_ANSI_X)
        case .importArchive: return .alt(kVK_ANSI_I)
        case .showShortcuts: return .alt(kVK_ANSI_Slash)
        }
    }
}

extension Notification.Name {
    static let shortcutsDidChange = Notification.Name("PinTack.shortcutsDidChange")
}

/// User bindings, persisted to `.pintack/hotkeys.json`. SPEC.md §10.2.
final class ShortcutStore {

    static let shared = ShortcutStore()

    private(set) var overrides: [ShortcutAction: KeyCombo] = [:]
    /// Bindings for plugin commands, stored under "plugin:<key>" in the same hotkeys.json. SPEC.md §10.2.
    private(set) var pluginOverrides: [String: KeyCombo] = [:]
    private var fileURL: URL?

    func load(from metaDirectory: URL) {
        let url = metaDirectory.appendingPathComponent("hotkeys.json")
        fileURL = url
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: KeyCombo].self, from: data) else { return }
        overrides = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in ShortcutAction(rawValue: k).map { ($0, v) } })
        pluginOverrides = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in
            k.hasPrefix("plugin:") ? (String(k.dropFirst("plugin:".count)), v) : nil
        })
    }

    // MARK: Plugin commands

    func pluginCombo(for command: PluginCommand) -> KeyCombo? {
        pluginOverrides[command.key] ?? command.defaultHotkey.flatMap(KeyCombo.parse)
    }

    func setPlugin(_ combo: KeyCombo?, for command: PluginCommand) {
        if let combo { pluginOverrides[command.key] = combo } else { pluginOverrides.removeValue(forKey: command.key) }
        save()
        NotificationCenter.default.post(name: .shortcutsDidChange, object: nil)
    }

    /// What already uses this key combination: an app action or another plugin command.
    func conflictTitle(for combo: KeyCombo, excludingAction action: ShortcutAction? = nil, excludingPlugin key: String? = nil) -> String? {
        if let a = ShortcutAction.allCases.first(where: { $0 != action && self.combo(for: $0) == combo }) { return a.title }
        if let c = PluginManager.shared.commands.first(where: { $0.key != key && pluginCombo(for: $0) == combo }) { return c.name }
        return nil
    }

    func pluginCommand(for event: NSEvent) -> PluginCommand? {
        let combo = KeyCombo(event: event)
        return PluginManager.shared.commands.first { pluginCombo(for: $0) == combo }
    }

    func combo(for action: ShortcutAction) -> KeyCombo { overrides[action] ?? action.defaultCombo }

    /// The other action already using this combo, if any. Surfaced in the recorder. SPEC.md §10.2.
    func conflict(for combo: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self.combo(for: $0) == combo }
    }

    func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        if let combo, combo != action.defaultCombo { overrides[action] = combo } else { overrides.removeValue(forKey: action) }
        save()
        NotificationCenter.default.post(name: .shortcutsDidChange, object: nil)
    }

    func resetAll() {
        overrides.removeAll()
        save()
        NotificationCenter.default.post(name: .shortcutsDidChange, object: nil)
    }

    private func save() {
        guard let fileURL else { return }
        var raw = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        for (key, combo) in pluginOverrides { raw["plugin:" + key] = combo }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        try? AtomicWriter.write(data, to: fileURL)
    }

    /// Action for a key event, if it matches any binding. Used by the local monitor.
    func action(for event: NSEvent) -> ShortcutAction? {
        let combo = KeyCombo(event: event)
        return ShortcutAction.allCases.first { self.combo(for: $0) == combo }
    }
}
