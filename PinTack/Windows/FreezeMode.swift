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

    /// How big the live corner is, measured from the card's bottom-right. It has to be comfortably
    /// bigger than the snowflake itself or the note becomes hard to thaw.
    static let liveCorner = NSSize(width: 46, height: 34)

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

    /// The thaw corner in screen coordinates, at the bottom-right of the CARD (never the window:
    /// the window is 24pt larger on every side, SPEC.md §5.2).
    static func liveCornerRect(of panel: NotePanel) -> NSRect {
        let card = NotePanel.cardRect(forWindow: panel.frame)
        return NSRect(x: card.maxX - liveCorner.width, y: card.minY,
                      width: liveCorner.width, height: liveCorner.height)
    }
}
