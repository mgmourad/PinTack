import AppKit

/// Note Stacks (owner decision, 2026-09-22). SPEC.md §5.10.
///
/// Two to five open notes drawn as one fanned pile: every note's title bar shows, one above the
/// other, and only the front note's body. The point is a tidier desk, not a new kind of note, so a
/// stack is a relationship BETWEEN notes: it lives in `.pintack/stacks.json` and the notes
/// themselves stay ordinary Markdown files with nothing added to them.
struct NoteStack: Codable, Equatable, Identifiable {

    static let minMembers = 2
    static let maxMembers = 5

    var id: String
    var name: String
    /// Every member, in the order the stack was made.
    var members: [String]
    /// Front to back, as drawn, and the numbers: the front note is always #1, the back one #N
    /// (owner decision, 2026-09-22, replacing numbers that stayed with their notes). The number on a
    /// title bar is where that note sits, so reading it off tells you the key: ⌘3 = third from front.
    var order: [String]
    var pinned = false
    var collapsed = false
    /// Each note's own size, place and collapse state from before it joined, so unstacking gives
    /// the desk back the way it was.
    var before: [String: Before] = [:]

    struct Before: Codable, Equatable {
        var x, y, width, height: Double
        var collapsed: Bool
        var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }

    func number(of noteID: String) -> Int? { order.firstIndex(of: noteID).map { $0 + 1 } }
    var front: String? { order.first }
}

extension Notification.Name {
    /// A stack was made, changed or dissolved. Note cards and All Notes listen.
    static let stacksDidChange = Notification.Name("PinTack.stacksDidChange")
}

final class StackManager {

    static let shared = StackManager()

    private(set) var stacks: [NoteStack] = []
    private var fileURL: URL?

    /// Internal rather than private so the unit tests can have a manager of their own.
    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(noteRemoved(_:)), name: .noteWasRemoved, object: nil)
    }

    // MARK: - Persistence

    private struct File: Codable { var version = 1; var stacks: [NoteStack] }

    /// The file is DISPOSABLE, like the search index (owner, 2026-09-22): missing, unreadable, corrupt
    /// or the wrong shape all mean "no stacks", never an error, never a blocked launch, and nothing
    /// read here is ever written into a note. A bad file is left alone until the next stack change
    /// replaces it.
    func load(from metaDirectory: URL, alive: Set<String>? = nil) {
        let url = metaDirectory.appendingPathComponent("stacks.json")
        fileURL = url
        stacks = []
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) {
            stacks = file.stacks
        }
        let before = stacks
        stacks = StackManager.pruned(stacks, alive: alive ?? Set(VaultStore.shared.notes.map(\.id)))
        if stacks != before { save() }
    }

    /// A note deleted while the app was closed (or on another Mac) leaves its stack, a note listed
    /// in two stacks stays in the first, and a stack left with fewer than two notes is no stack.
    static func pruned(_ stacks: [NoteStack], alive: Set<String>) -> [NoteStack] {
        var taken = Set<String>()
        return stacks.compactMap { s in
            var s = s
            var members: [String] = []
            for id in s.members where alive.contains(id) && !taken.contains(id) && !members.contains(id) { members.append(id) }
            s.members = Array(members.prefix(NoteStack.maxMembers))
            s.order = s.order.filter(s.members.contains)
            s.order = s.order.enumerated().filter { i, id in !s.order[..<i].contains(id) }.map(\.element)
            for id in s.members where !s.order.contains(id) { s.order.append(id) }
            s.before = s.before.filter { s.members.contains($0.key) }
            guard s.members.count >= NoteStack.minMembers else { return nil }
            taken.formUnion(s.members)
            return s
        }
    }

    /// Written atomically, like every other file in the vault (CLAUDE.md, hard constraint 5).
    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(File(stacks: stacks)) else { return }
        try? AtomicWriter.write(data, to: fileURL)
    }

    private func changed() {
        save()
        NotificationCenter.default.post(name: .stacksDidChange, object: nil)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    // MARK: - Lookup

    func stack(containing noteID: String) -> NoteStack? { stacks.first { $0.members.contains(noteID) } }
    func stack(id: String) -> NoteStack? { stacks.first { $0.id == id } }
    private func index(of id: String) -> Int? { stacks.firstIndex { $0.id == id } }

    func isFront(_ noteID: String) -> Bool { stack(containing: noteID)?.front == noteID }

    /// The notes of a stack that exist, in number order.
    func notes(of stack: NoteStack) -> [Note] { stack.members.compactMap { VaultStore.shared.note(id: $0) } }

    /// A stack is on the desk when any of its notes is.
    func isShown(_ stack: NoteStack) -> Bool { stack.members.contains { WindowManager.shared.panel(for: $0) != nil } }

    // MARK: - Making and dissolving

    /// `noteIDs` front first: the note whose paperclip was clicked is #1 and in front.
    @discardableResult
    func create(name: String, noteIDs: [String]) -> NoteStack? {
        var ids: [String] = []
        for id in noteIDs where !ids.contains(id) && stack(containing: id) == nil && VaultStore.shared.note(id: id) != nil {
            ids.append(id)
        }
        guard (NoteStack.minMembers...NoteStack.maxMembers).contains(ids.count) else { return nil }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = NoteStack(id: UUID().uuidString, name: title.isEmpty ? "Stack" : title, members: ids, order: ids)
        for id in ids {
            guard let note = VaultStore.shared.note(id: id) else { continue }
            let f = note.cardFrame
            s.before[id] = .init(x: f.minX, y: f.minY, width: f.width, height: f.height, collapsed: note.collapsed)
            if note.collapsed {
                note.collapsed = false
                VaultStore.shared.save(note)
            }
            // Every member is on the desk, so the stack is whole from the start.
            if !note.visible { note.visible = true; VaultStore.shared.save(note) }
            WindowManager.shared.open(note)
        }
        stacks.append(s)
        changed()
        refreshCards(of: s)
        layout(s, animated: true)
        focusFront(of: s)
        return s
    }

    /// The strike-through paperclip. Every note goes back to where and how big it was.
    func unstack(_ id: String) {
        guard let i = index(of: id) else { return }
        let s = stacks.remove(at: i)
        changed()
        for noteID in s.members {
            guard let note = VaultStore.shared.note(id: noteID) else { continue }
            if let b = s.before[noteID] {
                note.collapsed = b.collapsed
                if let panel = WindowManager.shared.panel(for: noteID) {
                    panel.placeCard(b.rect, animated: true)
                    panel.applyCollapsed(animated: true)
                } else {
                    note.cardFrame = b.rect
                }
            }
            VaultStore.shared.save(note)
            WindowManager.shared.panel(for: noteID)?.applyPinned()
        }
        refreshCards(of: s)
        Toast.show("Unstacked “\(s.name)”")
    }

    /// A member was deleted outside the app (the file watcher saw it go).
    @objc private func noteRemoved(_ n: Notification) {
        guard let note = n.object as? Note else { return }
        forget(note.id)
    }

    /// A member left the vault: it leaves the stack, and a stack of one dissolves.
    func forget(_ noteID: String) {
        guard let i = stacks.firstIndex(where: { $0.members.contains(noteID) }) else { return }
        stacks[i].members.removeAll { $0 == noteID }
        stacks[i].order.removeAll { $0 == noteID }
        stacks[i].before.removeValue(forKey: noteID)
        if stacks[i].members.count < NoteStack.minMembers {
            unstack(stacks[i].id)
        } else {
            let s = stacks[i]
            changed()
            refreshCards(of: s)
            layout(s, animated: true)
        }
    }

    // MARK: - The stack bar's controls

    func rename(_ id: String, to name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = index(of: id), !title.isEmpty, title != stacks[i].name else { return }
        stacks[i].name = title
        changed()
        refreshCards(of: stacks[i])
    }

    func togglePin(_ id: String) {
        guard let i = index(of: id) else { return }
        stacks[i].pinned.toggle()
        let s = stacks[i]
        changed()
        for noteID in s.members { WindowManager.shared.panel(for: noteID)?.applyPinned() }
        refreshCards(of: s)
        restack(s)
        Toast.show(s.pinned ? "📌 Stack pinned on top" : "Stack unpinned")
    }

    func toggleCollapse(_ id: String) {
        guard let i = index(of: id) else { return }
        stacks[i].collapsed.toggle()
        let s = stacks[i]
        changed()
        for note in notes(of: s) {
            note.collapsed = s.collapsed
            VaultStore.shared.save(note)
            WindowManager.shared.panel(for: note.id)?.applyCollapsed(animated: true)
        }
        refreshCards(of: s)
    }

    /// The stack bar's ✕: the whole stack leaves the desk, and stays in All Notes.
    func hide(_ id: String) {
        guard let s = stack(id: id) else { return }
        for note in notes(of: s) {
            SaveCoordinator.shared.flush(noteID: note.id)
            if note.visible { note.visible = false; VaultStore.shared.save(note) }
            WindowManager.shared.close(noteID: note.id)
        }
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
        Toast.show("Hid “\(s.name)” · still in All Notes")
    }

    /// Puts a stack back on the desk, with `front` (or its old front) in front.
    func show(_ id: String, front: String? = nil) {
        guard let i = index(of: id) else { return }
        if let front, let place = stacks[i].order.firstIndex(of: front), place != 0 {
            stacks[i].order.swapAt(0, place)          // the same swap a click makes
            save()
        }
        let s = stacks[i]
        for note in notes(of: s) {
            if !note.visible { note.visible = true; VaultStore.shared.save(note) }
            WindowManager.shared.open(note, animated: true)
        }
        refreshCards(of: s)
        layout(s, animated: false)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    /// All Notes' delete: the NOTES go to the Trash (owner decision, 2026-09-22), after the
    /// confirmation All Notes asks for. Undo brings the notes back and the stacks with them.
    func delete(_ ids: [String]) {
        let doomed = stacks.filter { ids.contains($0.id) }
        guard !doomed.isEmpty else { return }
        stacks.removeAll { ids.contains($0.id) }
        changed()
        let notes = doomed.flatMap { self.notes(of: $0) }
        WindowManager.shared.delete(notes) { [weak self] in
            guard let self else { return }
            for s in doomed where self.stack(id: s.id) == nil {
                self.stacks.append(s)
            }
            self.changed()
            for s in doomed { self.refreshCards(of: s); self.layout(s, animated: false) }
        }
    }

    /// "Add to Folder": every note of the stack moves into it, and stays stacked.
    func move(_ ids: [String], toFolder folder: String) {
        for s in stacks where ids.contains(s.id) {
            for note in notes(of: s) { VaultStore.shared.move(note, toFolder: folder) }
        }
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    // MARK: - Moving between notes

    /// ⌥Tab. The front note goes to the back, so pressing it N times walks the whole stack.
    func cycle(from noteID: String) {
        guard let i = stacks.firstIndex(where: { $0.members.contains(noteID) }), stacks[i].order.count > 1 else { return }
        let anchor = frontCard(of: stacks[i])
        let first = stacks[i].order.removeFirst()
        stacks[i].order.append(first)
        save()
        let s = stacks[i]
        layout(s, animated: true, anchor: anchor)
        focusFront(of: s)
        NotificationCenter.default.post(name: .stacksDidChange, object: nil)
    }

    /// ⌘1–⌘5: the note at that place trades places with the front one, and becomes #1.
    func bringToFront(number: Int, from noteID: String) {
        guard let s = stack(containing: noteID), s.order.indices.contains(number - 1) else { return }
        bringToFront(s.order[number - 1], reason: "⌘\(number)")
    }

    /// A note brought forward SWAPS places with the one in front (owner decision, 2026-09-22): the
    /// note that was in front drops into the place just vacated and nothing else moves, so clicking
    /// the same place twice puts the pile back exactly as it was. Taking the note out and pushing it
    /// onto the front instead rotated everything between them, and the pile reshuffled under the
    /// pointer — the note you clicked a moment ago was somewhere else by the time you looked.
    func bringToFront(_ noteID: String, reason: String = "?") {
        guard let i = stacks.firstIndex(where: { $0.members.contains(noteID) }) else {
            record(reason, "asked for a note that is in no stack"); return
        }
        guard let place = stacks[i].order.firstIndex(of: noteID), place != 0 else {
            record(reason, "\(title(noteID)) is already at the front — nothing to do")
            focusFront(of: stacks[i]); return
        }
        let before = stacks[i].order
        let anchor = frontCard(of: stacks[i])
        stacks[i].order.swapAt(0, place)
        save()
        let s = stacks[i]
        layout(s, animated: true, anchor: anchor)
        focusFront(of: s)
        NotificationCenter.default.post(name: .stacksDidChange, object: nil)
        record(reason, "place \(place + 1) (\(title(noteID))): \(before.map(title).joined(separator: ",")) → \(s.order.map(title).joined(separator: ","))")
    }

    // MARK: - The click log (SPEC.md §5.10)

    /// Every attempt to bring a note forward is written to `.pintack/stack-clicks.log`, in RELEASE
    /// builds too, because the fault the owner sees on his own Mac has never once appeared under the
    /// self-test's synthetic clicks (2026-09-22). It is a few lines per click, kept to the last 400,
    /// and written nowhere but the vault's own metadata folder.
    private var logURL: URL? { fileURL?.deletingLastPathComponent().appendingPathComponent("stack-clicks.log") }
    private static let logLimit = 400

    private func title(_ noteID: String) -> String {
        let name = VaultStore.shared.note(id: noteID)?.title ?? "?"
        return name.isEmpty ? "Untitled" : String(name.prefix(18))
    }

    func record(_ reason: String, _ what: String) {
        guard let logURL else { return }
        let stamp = Date().formatted(date: .omitted, time: .standard)
        var lines = ((try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? [])
        lines.append("\(stamp)  \(reason.padding(toLength: 16, withPad: " ", startingAt: 0)) \(what)")
        if lines.count > StackManager.logLimit { lines.removeFirst(lines.count - StackManager.logLimit) }
        try? AtomicWriter.write(lines.joined(separator: "\n") + "\n", to: logURL)
    }

    private func focusFront(of s: NoteStack) {
        guard let id = s.front, let panel = WindowManager.shared.panel(for: id) else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.card.focusEditor()
    }

    // MARK: - Geometry

    /// Where the front note's card sits: the pile is laid out from here.
    private func frontCard(of s: NoteStack) -> NSRect? {
        guard let id = s.front else { return nil }
        return WindowManager.shared.panel(for: id)?.note.cardFrame ?? VaultStore.shared.note(id: id)?.cardFrame
    }

    /// How much taller than its front card a stack stands on the desk: one title bar per note behind.
    func pileRise(of noteID: String) -> CGFloat {
        guard let s = stack(containing: noteID), s.front == noteID else { return 0 }
        let behind = s.order.dropFirst().filter { WindowManager.shared.panel(for: $0) != nil }.count
        return CGFloat(behind) * NotePanel.headerHeight
    }

    /// Every stack on the desk, laid out. At launch, after the notes are open.
    func layoutAll() {
        for s in stacks where isShown(s) { refreshCards(of: s); layout(s, animated: false) }
    }

    /// Fans the pile out from the front card: the same size for every note, each one a title bar
    /// higher than the one in front of it. Kept on the screen: a pile whose top would leave it is
    /// moved down as a whole, so every title bar can still be grabbed.
    func layout(_ s: NoteStack, animated: Bool, anchor: NSRect? = nil) {
        let panels = s.order.compactMap { WindowManager.shared.panel(for: $0) }
        guard let front = panels.first else { return }
        let base = anchor ?? front.note.cardFrame
        let step = NotePanel.headerHeight
        var minY = base.minY
        if let screen = (front.screen ?? NSScreen.main)?.visibleFrame {
            let top = base.maxY + CGFloat(panels.count - 1) * step
            if top > screen.maxY { minY -= top - screen.maxY }
        }
        for (depth, panel) in panels.enumerated() {
            let rect = NSRect(x: base.minX, y: minY + CGFloat(depth) * step, width: base.width, height: base.height)
            // Only a note that actually moved is written: laying the piles out at launch must not
            // rewrite every stacked note's file.
            let moved = panel.note.cardFrame != rect
            panel.placeCard(rect, animated: animated && moved)
            if moved { VaultStore.shared.save(panel.note) }
        }
        restack(s)
    }

    /// Window order: the back note first, the front note last, so it ends up on top.
    private func restack(_ s: NoteStack) {
        for id in s.order.reversed() { WindowManager.shared.panel(for: id)?.orderFrontRegardless() }
    }

    /// Dragging any note of the pile moves the whole pile.
    func drag(_ panel: NotePanel, to origin: NSPoint) {
        guard let s = stack(containing: panel.note.id) else { return }
        let dx = origin.x - panel.frame.minX, dy = origin.y - panel.frame.minY
        for id in s.members {
            guard let p = WindowManager.shared.panel(for: id) else { continue }
            p.setFrameOrigin(NSPoint(x: p.frame.minX + dx, y: p.frame.minY + dy))
        }
    }

    func dragEnded(_ panel: NotePanel) {
        guard let s = stack(containing: panel.note.id) else { return }
        for id in s.members {
            guard let p = WindowManager.shared.panel(for: id) else { continue }
            p.syncFrameToNote()
            VaultStore.shared.save(p.note)
        }
    }

    /// The front note was resized from its grip: the rest of the pile takes the same size.
    func resized(_ panel: NotePanel) {
        guard let s = stack(containing: panel.note.id), s.front == panel.note.id else { return }
        layout(s, animated: false)
    }

    private func refreshCards(of s: NoteStack) {
        for id in s.members { WindowManager.shared.panel(for: id)?.card.refreshStackState() }
    }
}

/// What All Notes asks before deleting stacks (owner decision, 2026-09-22). Deleting a stack deletes
/// its NOTES, so the safe answer is the default: Return unstacks, keeping every note; deleting
/// takes a deliberate click on the red button; Esc cancels.
enum StackDeleteAlert {

    enum Answer { case delete, unstack, cancel }

    static func make(for stacks: [NoteStack]) -> NSAlert {
        let notes = stacks.flatMap { StackManager.shared.notes(of: $0) }
        let n = notes.count
        let what = stacks.count == 1 ? "“\(stacks[0].name)”"
            : stacks.count == StackManager.shared.stacks.count ? "all \(stacks.count) stacks" : "\(stacks.count) stacks"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \(what) and \(n == 1 ? "its note" : "the \(n) notes in \(stacks.count == 1 ? "it" : "them")")?"
        alert.informativeText = "\(n == 1 ? "The note goes" : "The \(n) notes go") to the Trash\(folderClause(notes)), "
            + "so you can still get them back from there. Unstack keeps every note and only undoes the stack."
        // The FIRST button is the one Return presses: Unstack, the answer that loses nothing.
        alert.addButton(withTitle: "Unstack")
        let delete = alert.addButton(withTitle: "Delete \(n) Note\(n == 1 ? "" : "s")")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        // A button titled Cancel is the one Esc presses.
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    /// ", including 2 filed in Work", ", including 3 filed in 2 folders", or nothing.
    static func folderClause(_ notes: [Note]) -> String {
        let folders = notes.map { VaultStore.shared.folder(of: $0) }.filter { !$0.isEmpty }
        guard !folders.isEmpty else { return "" }
        let distinct = Set(folders)
        return ", including \(folders.count) filed in " + (distinct.count == 1 ? distinct.first! : "\(distinct.count) folders")
    }

    static func answer(_ response: NSApplication.ModalResponse) -> Answer {
        switch response {
        case .alertFirstButtonReturn:  return .unstack
        case .alertSecondButtonReturn: return .delete
        default:                       return .cancel
        }
    }

    /// Asks, then does what was answered.
    @discardableResult
    static func run(for stacks: [NoteStack]) -> Answer {
        guard !stacks.isEmpty else { return .cancel }
        NSApp.activate(ignoringOtherApps: true)
        let result = answer(make(for: stacks).runModal())
        switch result {
        case .unstack: stacks.forEach { StackManager.shared.unstack($0.id) }
        case .delete:  StackManager.shared.delete(stacks.map(\.id))
        case .cancel:  break
        }
        return result
    }
}
