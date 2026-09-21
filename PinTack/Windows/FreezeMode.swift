import AppKit

/// Freeze mode: a note that sits on the desktop and lets the mouse straight through, so a cheat
/// sheet can stay visible over whatever you are working in. SPEC.md §5.1.
///
/// A window that ignores the mouse cannot be clicked to un-ignore it — not its snowflake, not its
/// right-click menu, and it can never become key so no keyboard shortcut reaches it. The way out
/// (an owner decision, 2026-09-20) is that the snowflake corner stays live: this watches where the
/// pointer is and lifts `ignoresMouseEvents` only while it is over that corner.
///
/// Polling rather than a global mouse monitor: `NSEvent.addGlobalMonitorForEvents` is the obvious
/// tool but it is the same API family that needs Accessibility permission, and a sticky-note app
/// should not ask for that. `NSEvent.mouseLocation` needs no permission at all. The timer only
/// runs while at least one note is frozen.
enum FreezeMode {

    private static var timer: Timer?

    /// Starts or stops the pointer watch to match how many notes are frozen.
    static func update() {
        let frozen = WindowManager.shared.openPanels.filter { $0.note.frozen }
        guard !frozen.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in tick() }
        // Keep working while a menu is open or a window is being dragged.
        RunLoop.main.add(timer!, forMode: .common)
    }

    private static func tick() {
        let pointer = NSEvent.mouseLocation
        var anyFrozen = false
        for panel in WindowManager.shared.openPanels where panel.note.frozen {
            anyFrozen = true
            panel.ignoresMouseEvents = !liveCornerRect(of: panel).contains(pointer)
        }
        if !anyFrozen { update() }
    }

    /// The live spot in screen coordinates: the snowflake button itself, with room around it for
    /// an imprecise pointer. It used to be a fixed box at the card's bottom-right, which stopped
    /// covering the snowflake once a todo's action bar grew tracker rows and lifted the controls
    /// to its top row — a frozen todo then could not be thawed from its own button.
    static func liveCornerRect(of panel: NotePanel) -> NSRect {
        guard let card = panel.card else { return .zero }
        let button = card.freezeButtonRectInWindow.insetBy(dx: -10, dy: -8)
        return panel.convertToScreen(button)
    }
}
