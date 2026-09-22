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
        nc.addObserver(self, selector: #selector(noteSaved(_:)), name: .noteDidSave, object: nil)
        nc.addObserver(self, selector: #selector(vaultChangedForPlugins), name: .vaultDidChange, object: nil)
        nc.addObserver(self, selector: #selector(pluginSettingChanged(_:)), name: .pluginSettingsDidChange, object: nil)
        // A display unplugged or rearranged while notes are open. Launch was already covered by
        // clampToScreen; this is the case of a note left pointing at a screen that has just gone.
        nc.addObserver(self, selector: #selector(screensChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - Plugins (SPEC.md §12.3 events)

    var allEditors: [NoteEditorView] { panels.values.map { $0.card.editor } }

    /// A plugin was switched on or off: reload every editor so the change takes effect everywhere.
    func reloadEditors() { allEditors.forEach { $0.reloadEditor() } }

    /// Pushes the vault's templates to every open note, so a newly saved one is recallable at once.
    func refreshTemplates() {
        let payload = NoteEditorView.templatePayload()
        allEditors.forEach { $0.send("templates.changed", ["templates": payload]) }
    }

    /// A plugin rewrote a note's text through the vault API.
    func noteChangedByPlugin(_ note: Note) {
        panels[note.id]?.card.editor.reloadBody()
        NotificationCenter.default.post(name: .noteBodyDidChange, object: note)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    @objc private func noteSaved(_ n: Notification) {
        guard let note = n.object as? Note else { return }
        panels[note.id]?.card.editor.sendPluginEvent("note:save", ["noteId": note.id])
    }

    private var vaultChangeWork: DispatchWorkItem?
    /// Debounced: a burst of file events must reach plugins as one `vault:change`.
    @objc private func vaultChangedForPlugins() {
        vaultChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.allEditors.forEach { $0.sendPluginEvent("vault:change") } }
        vaultChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    @objc private func pluginSettingChanged(_ n: Notification) {
        guard let id = n.userInfo?["id"] as? String else { return }
        allEditors.forEach { $0.sendPluginSettings(id) }
    }

    var openPanels: [NotePanel] { Array(panels.values) }
    func panel(for noteID: String) -> NotePanel? { panels[noteID] }

    // MARK: - Opening

    func restoreVisibleNotes() {
        for note in VaultStore.shared.notes where note.visible { open(note) }
    }

    @discardableResult
    func open(_ note: Note, focus: Bool = false, animated: Bool = false) -> NotePanel {
        if let existing = panels[note.id] {
            existing.orderFrontRegardless()
            if focus { existing.makeKeyAndOrderFront(nil); existing.card.focusEditor() }
            return existing
        }
        if !note.hasFrame { note.cardFrame = nextCardFrame(size: note.cardFrame.size); note.hasFrame = true }
        clampToScreen(note)

        let panel = NotePanel(note: note)
        panels[note.id] = panel
        // Restoring a deskful of notes at launch animates nothing: a dozen cards fading in at once
        // is a light show, not feedback.
        if animated { Motion.appear(window: panel, content: panel.card, to: panel.effectiveOpacity) }
        panel.orderFrontRegardless()
        if focus {
            panel.makeKeyAndOrderFront(nil)
            panel.card.focusEditor()
        }
        return panel
    }

    /// New note at the configured placement, ready to type in. SPEC.md §5.5.
    private var lastNewNote = Date.distantPast

    @discardableResult
    func newNote(body: String = "", folder: String? = nil, tags: [String] = []) -> Note {
        // A held or double-tapped shortcut must not spray empty notes across the desktop.
        if Date().timeIntervalSince(lastNewNote) < 0.35, let existing = VaultStore.shared.notes.last { return existing }
        lastNewNote = Date()
        let settings = AppSettings.shared
        let defaults = settings.noteDefaults
        let frame = nextCardFrame(size: defaults.size)
        let note = VaultStore.shared.createNote(body: body, folder: folder, tags: tags, defaults: defaults, frame: frame)
        open(note, focus: true, animated: true)
        return note
    }

    /// A todo note starts as "@Todo " with a greyed "todo title" hint after it; Enter after the
    /// title creates the first checkbox (the editor does that). Tagged #todo from the start.
    func newTodo() { newNote(body: "@Todo ", tags: ["todo"]) }

    /// Rename from anywhere (All Notes, the header). The body is not touched, so the open editor
    /// keeps whatever the note says and only the header and the lists need refreshing.
    func rename(_ note: Note, to title: String) {
        SaveCoordinator.shared.flush(noteID: note.id)
        note.retitle(to: title)
        VaultStore.shared.save(note)
        panels[note.id]?.card.refreshFromNote()
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    /// Moves notes to the Trash, closing any open windows first, and offers Undo for five seconds
    /// (owner decision, 2026-09-21). The Trash already made a delete recoverable, but only by way
    /// of Finder; an accidental ⌥⌘D deserves a one-click way back.
    /// `onUndo` runs after the notes are back, for whatever else the delete took with it (a stack).
    func delete(_ notes: [Note], onUndo: (() -> Void)? = nil) {
        var trashed: [(note: Note, url: URL, wasOpen: Bool)] = []
        for note in notes {
            let wasOpen = panels[note.id] != nil
            close(noteID: note.id)
            if let url = VaultStore.shared.delete(note) {
                trashed.append((note, url, wasOpen))
                StackManager.shared.forget(note.id)
            }
        }
        guard !trashed.isEmpty else { return }
        let message = trashed.count == 1 ? "Moved to Trash" : "Moved \(trashed.count) notes to Trash"
        Toast.show(message, action: "Undo", seconds: 5) { [weak self] in
            var back = 0
            for item in trashed where VaultStore.shared.restore(item.note, from: item.url) {
                back += 1
                if item.wasOpen { self?.open(item.note, animated: true) }
            }
            onUndo?()
            Toast.show(back == trashed.count ? "Restored" : "Restored \(back) of \(trashed.count)")
        }
    }

    /// Hide the window but keep the note ("Minimize to All Notes"). SPEC.md §8.
    func close(noteID: String) {
        guard let panel = panels.removeValue(forKey: noteID) else { return }
        // Tell plugins (best effort: the page is about to go away), and make sure that none of this
        // note's commands keep running whether or not they got the message.
        panel.card.editor.sendPluginEvent("note:close", ["noteId": noteID])
        PluginBridge.shared.cancelRuns(owner: panel.card.editor)
        Motion.dismiss(window: panel, content: panel.card) {
            panel.orderOut(nil)
            panel.close()
        }
        if lastFocusedID == noteID { lastFocusedID = nil }
    }

    func showAll() {
        for note in VaultStore.shared.notes {
            if !note.visible { note.visible = true; VaultStore.shared.save(note) }
            open(note)
        }
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    /// Clears the desktop: every open note is hidden, exactly as "Minimize to All Notes" does one.
    /// The notes are untouched — only `visible` changes — so the same key brings them all back.
    func hideAll() {
        for panel in openPanels {
            let note = panel.note
            if note.visible { note.visible = false; VaultStore.shared.save(note) }
            close(noteID: note.id)
        }
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    /// One key for both directions (an owner decision, 2026-09-20): if anything is on the desktop,
    /// clear it; otherwise put it all back.
    func toggleAllOnDesktop() {
        if openPanels.isEmpty {
            showAll()
            Toast.show("Showing every note")
        } else {
            let count = openPanels.count
            hideAll()
            Toast.show("Hid \(count) note\(count == 1 ? "" : "s") · still in All Notes")
        }
    }

    /// Show a note that was hidden, or raise and pulse one that is already open. SPEC.md §8.
    func reveal(_ note: Note) {
        // A note in a stack comes back with its stack, in front of it.
        if let stack = StackManager.shared.stack(containing: note.id) {
            StackManager.shared.show(stack.id, front: note.id)
            panels[note.id]?.pulse()
            return
        }
        let wasOpen = panels[note.id] != nil
        if !note.visible { note.visible = true; VaultStore.shared.save(note) }
        let panel = open(note, animated: !wasOpen)
        panel.orderFrontRegardless()
        panel.pulse()
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    // MARK: - Focus

    func noteBecameFocused(_ note: Note) { lastFocusedID = note.id }

    /// The note that actions like ⌥⌘P apply to, in order of certainty:
    /// the key window, a note that is key while the app is inactive, the note under the pointer,
    /// then the one focused last.
    var focusedPanel: NotePanel? {
        if let key = NSApp.keyWindow as? NotePanel { return key }
        // Notes are non-activating panels, so one can be the key window while the APP is inactive.
        // NSApp.keyWindow is nil then, and shortcuts used to find no target.
        if let key = panels.values.first(where: { $0.isKeyWindow }) { return key }
        let mouse = NSEvent.mouseLocation
        if let hovered = NSApp.orderedWindows.compactMap({ $0 as? NotePanel })
            .first(where: { NotePanel.cardRect(forWindow: $0.frame).contains(mouse) }) { return hovered }
        if let id = lastFocusedID, let p = panels[id] { return p }
        return nil
    }

    var focusedNote: Note? { focusedPanel?.note }

    /// The note that is the key window right now, and only that: no pointer or last-focused guess.
    var keyPanel: NotePanel? {
        if let key = NSApp.keyWindow as? NotePanel { return key }
        return panels.values.first(where: { $0.isKeyWindow })
    }

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
        if WindowManager.isReachable(note.cardFrame) { return }
        guard let main = NSScreen.main?.visibleFrame else { return }
        note.cardFrame.origin = NSPoint(x: main.midX - note.cardFrame.width / 2,
                                        y: main.midY - note.cardFrame.height / 2)
    }

    /// Enough of the card is on some screen to grab it: its title bar, not just one pixel.
    static func isReachable(_ card: NSRect, screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) -> Bool {
        let header = NSRect(x: card.minX, y: card.maxY - NotePanel.headerHeight,
                            width: card.width, height: NotePanel.headerHeight)
        return screens.contains { $0.intersection(header).width > 40 && $0.intersection(header).height > 10 }
    }

    /// Brings back every open note that is no longer on any screen. They land in a short cascade
    /// in the middle of the main screen, not in one pile, so each can be told apart and grabbed.
    @objc func screensChanged() {
        guard let main = NSScreen.main?.visibleFrame else { return }
        var step: CGFloat = 0
        for panel in openPanels.sorted(by: { $0.note.created < $1.note.created }) {
            let visible = NotePanel.cardRect(forWindow: panel.frame)
            guard !WindowManager.isReachable(visible) else { continue }
            let origin = NSPoint(x: main.midX - visible.width / 2 + step,
                                 y: min(main.maxY - visible.height, main.midY - visible.height / 2) - step)
            panel.setFrameOrigin(NSPoint(x: origin.x - NotePanel.margin, y: origin.y - NotePanel.margin))
            panel.syncFrameToNote()
            VaultStore.shared.save(panel.note)
            step += 28
        }
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
        guard let note = n.object as? Note else { return }
        if !note.visible { close(noteID: note.id); return }
        // A hidden note made visible by an outside edit (e.g. synced from another Mac)
        // has no window yet: open one.
        guard let panel = panels[note.id] else { open(note); return }
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
