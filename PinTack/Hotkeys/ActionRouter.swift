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
    /// Timestamp of the NSEvent that last drove each action. See `perform`.
    private static var lastEventStamp: [ShortcutAction: TimeInterval] = [:]
    static func resetDedupeMemory() { lastPerformed = [:]; lastEventStamp = [:] }      // for the self-test

    static func perform(_ action: ShortcutAction) {
        if action != .lessOpaque && action != .moreOpaque {          // opacity is meant to repeat
            // One press really does arrive here twice. AppKit hands the key event to the local
            // monitor as an *observer* (`_NSSendEventToObservers`), which cannot consume it, and
            // then the very same `-[NSApplication sendEvent:]` call carries it on to the main
            // menu's key equivalent. Returning nil from the monitor does not stop that.
            //
            // Elapsed time alone could not tell the two apart: ⌥⌘K collapses with an animated
            // setFrame that used to spin a nested run loop for ~270 ms, so the menu's copy landed
            // just OUTSIDE a 250 ms window and toggled the note straight back. Key off the identity
            // of the originating event instead — it is the same event on both paths, no matter how
            // long the action takes. Carbon hotkeys carry no NSEvent and keep the time window.
            if let event = NSApp.currentEvent, event.type == .keyDown {
                if lastEventStamp[action] == event.timestamp { return }
                lastEventStamp[action] = event.timestamp
            }
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
        case .quickCapture:   QuickCapture.shared.captureFromClipboard()
        case .showShortcuts:  ShortcutsOverlay.shared.toggle()
        case .toggleCorners:  windows.toggleCorners()
        case .exportAll:      ArchiveIO.exportAll()
        case .importArchive:  ArchiveIO.importArchive()

        case .pin, .collapse, .close, .toggleMode, .emoji, .freeze, .lessOpaque, .moreOpaque,
             .color1, .color2, .color3, .color4, .color5, .color6:
            if let focused { focused.perform(action) } else { Toast.show("Click a note first") }
        }
    }

    /// Actions that only make sense with a focused note need one; used to disable menu items.
    static func needsFocusedNote(_ action: ShortcutAction) -> Bool {
        switch action {
        case .pin, .collapse, .close, .toggleMode, .emoji, .freeze, .lessOpaque, .moreOpaque,
             .color1, .color2, .color3, .color4, .color5, .color6: return true
        default: return false
        }
    }
}
