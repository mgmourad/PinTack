import AppKit

/// Owns every open note window. SPEC.md §5.
final class WindowManager {

    static let shared = WindowManager()

    private var panels: [String: NotePanel] = [:]
    private var lastFocusedID: String?

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(noteChangedExternally(_:)), name: .noteDidChangeExternally, object: nil)
        nc.addObserver(self, selector: #selector(noteRemoved(_:)), name: .noteWasRemoved, object: nil)
        nc.addObserver(self, selector: #selector(conflict(_:)), name: .vaultConflict, object: nil)
    }

    var openPanels: [NotePanel] { Array(panels.values) }
    func panel(for noteID: String) -> NotePanel? { panels[noteID] }

    // MARK: - Opening

    func restoreVisibleNotes() {
        for note in VaultStore.shared.notes where note.visible { open(note) }
    }

    @discardableResult
    func open(_ note: Note, focus: Bool = false) -> NotePanel {
        if let existing = panels[note.id] {
            existing.orderFrontRegardless()
            if focus { existing.makeKeyAndOrderFront(nil); existing.card.focusEditor() }
            return existing
        }
        if !note.hasFrame { note.cardFrame = nextCardFrame(size: note.cardFrame.size); note.hasFrame = true }
        clampToScreen(note)

        let panel = NotePanel(note: note)
        panels[note.id] = panel
        panel.orderFrontRegardless()
        if focus {
            panel.makeKeyAndOrderFront(nil)
            panel.card.focusEditor()
        }
        return panel
    }

    /// New note at the configured placement, ready to type in. SPEC.md §5.5.
    @discardableResult
    func newNote(body: String = "", folder: String? = nil) -> Note {
        let settings = AppSettings.shared
        let defaults = settings.noteDefaults
        let frame = nextCardFrame(size: defaults.size)
        let note = VaultStore.shared.createNote(body: body, folder: folder, defaults: defaults, frame: frame)
        open(note, focus: true)
        return note
    }

    func newTodo() { newNote(body: "# Todo\n\n- [ ] ") }

    /// Hide the window but keep the note ("Minimize to All Notes"). SPEC.md §8.
    func close(noteID: String) {
        guard let panel = panels.removeValue(forKey: noteID) else { return }
        panel.orderOut(nil)
        panel.close()
        if lastFocusedID == noteID { lastFocusedID = nil }
    }

    func showAll() {
        for note in VaultStore.shared.notes {
            if !note.visible { note.visible = true; VaultStore.shared.save(note) }
            open(note)
        }
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    /// Show a note that was hidden, or raise and pulse one that is already open. SPEC.md §8.
    func reveal(_ note: Note) {
        if !note.visible { note.visible = true; VaultStore.shared.save(note) }
        let panel = open(note)
        panel.orderFrontRegardless()
        panel.pulse()
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    // MARK: - Focus

    func noteBecameFocused(_ note: Note) { lastFocusedID = note.id }

    /// The note that actions like ⌥⌘P apply to: the key window's note, else the last one focused.
    var focusedPanel: NotePanel? {
        if let key = NSApp.keyWindow as? NotePanel { return key }
        if let id = lastFocusedID, let p = panels[id] { return p }
        return nil
    }

    var focusedNote: Note? { focusedPanel?.note }

    // MARK: - Placement (SPEC.md §5.5)

    private var activeScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }

    /// New-note placement: at cursor / centered / cascade, per setting. Works on the
    /// CARD rect; the window adds its margin later. SPEC.md §5.2.
    func nextCardFrame(size: NSSize) -> NSRect {
        guard let visible = activeScreen?.visibleFrame else {
            return NSRect(origin: NSPoint(x: 200, y: 200), size: size)
        }
        switch AppSettings.shared.placement {
        case "cursor":
            let m = NSEvent.mouseLocation
            return NSRect(x: m.x - size.width / 2, y: m.y - size.height / 2, width: size.width, height: size.height)
                .clamped(to: visible)
        case "centered":
            return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                          width: size.width, height: size.height)
        default:
            // Cascade with a 24pt step, reset when it would leave the visible screen.
            let step: CGFloat = 24
            var i = CGFloat(panels.count)
            var origin = NSPoint(x: visible.minX + 60 + i * step, y: visible.maxY - size.height - 60 - i * step)
            while (origin.y < visible.minY + 20 || origin.x + size.width > visible.maxX - 20) && i > 0 {
                i = 0
                origin = NSPoint(x: visible.minX + 60, y: visible.maxY - size.height - 60)
            }
            return NSRect(origin: origin, size: size)
        }
    }

    /// A frame restored from a disconnected display must come back on-screen. SPEC.md §5.5.
    private func clampToScreen(_ note: Note) {
        let screens = NSScreen.screens.map(\.visibleFrame)
        // Enough of the card must be reachable: its title bar, not just one pixel.
        let header = NSRect(x: note.cardFrame.minX, y: note.cardFrame.maxY - NotePanel.headerHeight,
                            width: note.cardFrame.width, height: NotePanel.headerHeight)
        if screens.contains(where: { $0.intersection(header).width > 40 && $0.intersection(header).height > 10 }) { return }
        guard let main = NSScreen.main?.visibleFrame else { return }
        note.cardFrame.origin = NSPoint(x: main.midX - note.cardFrame.width / 2,
                                        y: main.midY - note.cardFrame.height / 2)
    }

    // MARK: - Arrange (SPEC.md §5.5)

    /// Grid across the active screen, card rects, 18pt gutters, preserving z-order.
    func autoArrange() {
        guard let visible = activeScreen?.visibleFrame else { return }
        let gutter: CGFloat = 18
        // Front-to-back window order → left-to-right, top-to-bottom, so z-order is preserved
        // (the note that was on top lands first).
        let order = NSApp.orderedWindows.compactMap { $0 as? NotePanel }
        let rest = panels.values.filter { p in !order.contains { $0 === p } }
        let ordered = order + rest.sorted { $0.note.created < $1.note.created }
        guard !ordered.isEmpty else { return }

        var x = visible.minX + gutter, top = visible.maxY - gutter, rowHeight: CGFloat = 0
        for panel in ordered {
            let note = panel.note
            let w = note.cardFrame.width
            let h = note.collapsed ? NotePanel.headerHeight : note.cardFrame.height
            if x + w > visible.maxX - gutter && x > visible.minX + gutter {
                x = visible.minX + gutter
                top -= rowHeight + gutter
                rowHeight = 0
            }
            let expandedHeight = note.cardFrame.height
            panel.applyCardFrame(NSRect(x: x, y: top - expandedHeight, width: w, height: expandedHeight), animated: true)
            VaultStore.shared.save(note)
            x += w + gutter
            rowHeight = max(rowHeight, h)
        }
        Toast.show("Auto-arranged")
    }

    // MARK: - Settings fan-out

    func toggleCorners() {
        let s = AppSettings.shared
        s.cornerStyle = s.cornerStyle == "round" || s.cornerStyle == "rounded" ? "square" : "rounded"
        Toast.show(s.cornerStyle == "rounded" ? "Rounded corners" : "Square corners")
    }

    // MARK: - External changes (SPEC.md §3.7)

    @objc private func noteChangedExternally(_ n: Notification) {
        guard let note = n.object as? Note, let panel = panels[note.id] else { return }
        if !note.visible { close(noteID: note.id); return }
        panel.applyCardFrame(note.cardFrame)
        panel.card.refreshFromNote()
        panel.card.editor.reloadBody()
    }

    @objc private func noteRemoved(_ n: Notification) {
        guard let note = n.object as? Note else { return }
        close(noteID: note.id)
    }

    /// The file changed on disk while the note had unsaved edits: ask, never overwrite silently.
    @objc private func conflict(_ n: Notification) {
        guard let note = n.userInfo?["note"] as? Note, let disk = n.userInfo?["disk"] as? Note else { return }
        let alert = NSAlert()
        alert.messageText = "“\(note.title)” changed on disk"
        alert.informativeText = "The file was edited outside PinTack while you had unsaved changes here."
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Keep Theirs")
        alert.addButton(withTitle: "Keep Both")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            SaveCoordinator.shared.flush(noteID: note.id)          // mine wins, written over theirs
        case .alertSecondButtonReturn:
            VaultStore.shared.keepDiskVersion(of: note, disk: disk)
        default:
            SaveCoordinator.shared.flush(noteID: note.id)
            let copy = VaultStore.shared.adoptDiskVersionAsCopy(disk)
            open(copy)
        }
    }
}

private extension NSRect {
    func clamped(to bounds: NSRect) -> NSRect {
        var r = self
        r.origin.x = min(max(r.origin.x, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.origin.y, bounds.minY), bounds.maxY - r.height)
        return r
    }
}
