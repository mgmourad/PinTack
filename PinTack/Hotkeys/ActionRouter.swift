import AppKit

/// The single place every trigger lands: global hotkeys, the in-app key monitor,
/// menu items and the menu-bar item. Keeping one dispatch table means a shortcut
/// and its menu entry can never drift apart.
enum ActionRouter {

    static func perform(_ action: ShortcutAction) {
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

        case .pin:            focused?.togglePin()
        case .collapse:       focused?.toggleCollapse()
        case .close:          focused?.closeNote()
        case .toggleMode:     focused?.toggleMode()
        case .emoji:          focused?.openEmoji()
        case .lessOpaque:     focused?.nudgeOpacity(by: -0.1)
        case .moreOpaque:     focused?.nudgeOpacity(by: 0.1)
        case .color1, .color2, .color3, .color4, .color5, .color6:
            if let i = [ShortcutAction.color1, .color2, .color3, .color4, .color5, .color6].firstIndex(of: action) {
                focused?.setColor(NotePalette.presets[i].hex)
            }
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
