import AppKit

/// The single place every trigger lands: global hotkeys, the in-app key monitor,
/// menu items and the menu-bar item. Keeping one dispatch table means a shortcut
/// and its menu entry can never drift apart.
enum ActionRouter {

    /// The same action arriving twice inside this window is one key press seen by two paths (the
    /// Carbon global hotkey AND the in-app key monitor or menu key equivalent), or a double-fire. It
    /// must run once: run twice, a toggle like ⌥⌘H cancels itself and looks like "sometimes it works".
    static var dedupeInterval: TimeInterval = 0.25
    private static var lastPerformed: [ShortcutAction: Date] = [:]
    static func resetDedupeMemory() { lastPerformed = [:] }      // for the self-test

    static func perform(_ action: ShortcutAction) {
        if action != .lessOpaque && action != .moreOpaque {          // opacity is meant to repeat
            let now = Date()
            if let last = lastPerformed[action], now.timeIntervalSince(last) < dedupeInterval { return }
            lastPerformed[action] = now
        }
        let windows = WindowManager.shared
        let focused = windows.focusedPanel?.card

        switch action {
        case .newNote:        windows.newNote()
        case .newTodo:        windows.newTodo()
        case .toggleAllNotes: AllNotesWindowController.shared.toggle()
        case .autoArrange:    windows.autoArrange()
        case .showShortcuts:  ShortcutsOverlay.shared.toggle()
        case .toggleCorners:  windows.toggleCorners()
        case .exportAll:      ArchiveIO.exportAll()
        case .importArchive:  ArchiveIO.importArchive()

        case .pin, .collapse, .close, .toggleMode, .emoji, .lessOpaque, .moreOpaque,
             .color1, .color2, .color3, .color4, .color5, .color6:
            if let focused { focused.perform(action) } else { Toast.show("Click a note first") }
        }
    }

    /// Actions that only make sense with a focused note need one; used to disable menu items.
    static func needsFocusedNote(_ action: ShortcutAction) -> Bool {
        switch action {
        case .pin, .collapse, .close, .toggleMode, .emoji, .lessOpaque, .moreOpaque,
             .color1, .color2, .color3, .color4, .color5, .color6: return true
        default: return false
        }
    }
}
