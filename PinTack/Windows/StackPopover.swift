import SwiftUI
import AppKit

/// The paperclip's popover: pick two to ten of the notes on the desk and name the stack.
/// SPEC.md §5.10. The note whose paperclip was clicked is checked already and becomes #1, in front.
struct StackCreatorView: View {

    struct Candidate: Identifiable, Equatable {
        let id: String
        let title: String
        /// The stack it is already in: a note belongs to one stack at a time.
        let stackName: String?
    }

    /// The open notes, the clicked one first and the rest front to back as they sit on the desk.
    static func candidates(for noteID: String) -> [Candidate] {
        // The window server's front-to-back order: NSApp.orderedWindows leaves note panels out.
        let open = WindowManager.shared.openPanels
        let ordered = (NSWindow.windowNumbers(options: []) ?? []).compactMap { n in open.first { $0.windowNumber == n.intValue } }
        let rest = open.filter { p in !ordered.contains { $0 === p } }
        var panels = ordered + rest
        if let i = panels.firstIndex(where: { $0.note.id == noteID }) { panels.insert(panels.remove(at: i), at: 0) }
        return panels.map { p in
            Candidate(id: p.note.id, title: p.note.title.isEmpty ? "Untitled" : p.note.title,
                      stackName: StackManager.shared.stack(containing: p.note.id)?.name)
        }
    }

    let current: String
    let candidates: [Candidate]
    let onCreate: (_ name: String, _ ids: [String]) -> Void

    @State private var chosen: Set<String>
    @State private var name = ""

    init(current: String, candidates: [Candidate], onCreate: @escaping (String, [String]) -> Void) {
        self.current = current
        self.candidates = candidates
        self.onCreate = onCreate
        _chosen = State(initialValue: [current])
    }

    private var full: Bool { chosen.count >= NoteStack.maxMembers }
    private var ready: Bool { chosen.count >= NoteStack.minMembers }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color(nsColor: Brand.accentNS))
                Text("Make a stack").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(chosen.count) of \(NoteStack.maxMembers)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("Pick 2 to \(NoteStack.maxMembers) open notes. This one stays in front as #1.")
                .font(.caption).foregroundStyle(.secondary)

            // Ten members are allowed, and a busy desk has more notes than that open: the list
            // scrolls rather than growing the popover past the screen.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates) { c in row(c) }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 260)

            TextField("Stack name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if ready { create() } }

            HStack {
                if !ready {
                    Text("Check at least one more note.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("OK") { create() }
                    .buttonStyle(ChromeProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
                    .opacity(ready ? 1 : 0.45)
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private func row(_ c: Candidate) -> some View {
        let on = chosen.contains(c.id)
        // Already stacked elsewhere, or no room left: shown, so nobody wonders where a note went,
        // but not pickable.
        let locked = c.stackName != nil || (!on && full)
        return Button {
            if on { if c.id != current { chosen.remove(c.id) } } else if !locked { chosen.insert(c.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(on ? Color(nsColor: Brand.accentNS) : .secondary)
                Text(c.title).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 4)
                if let stack = c.stackName {
                    Text("in “\(stack)”").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else if c.id == current {
                    Text("#1").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(locked && !on ? 0.45 : 1)
        .disabled(locked && !on)
        .accessibilityLabel(c.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The clicked note first, then the rest in the order they are listed.
    private func create() {
        guard ready else { return }
        let ids = [current] + candidates.map(\.id).filter { $0 != current && chosen.contains($0) }
        onCreate(name, ids)
    }
}

/// `/addToStack`: which of the stacks already on the desk this note should join.
///
/// The creator above makes a NEW stack out of loose notes; this one joins an EXISTING pile, which
/// until now could only be done from the `+` beside that stack's own name — so a note could only be
/// added by going to the stack, never from the note itself.
struct StackJoinerView: View {

    struct Choice: Identifiable, Equatable {
        let id: String
        let name: String
        let members: Int
        /// A stack already holding `NoteStack.maxMembers` cannot take another note.
        var full: Bool { members >= NoteStack.maxMembers }
    }

    /// Every stack with a note on the desk, most recently touched first — the order they are stored
    /// in, which is the order they were made.
    static func choices() -> [Choice] {
        StackManager.shared.stacks.map { Choice(id: $0.id, name: $0.name, members: $0.members.count) }
    }

    let noteTitle: String
    let choices: [Choice]
    let onJoin: (_ stackID: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.stack.badge.plus").foregroundStyle(Color(nsColor: Brand.accentNS))
                Text("Add to a stack").font(.system(size: 13, weight: .semibold))
            }
            Text("“\(noteTitle)” joins the back of the pile.")
                .font(.caption).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(choices) { row($0) }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 220)
        }
        .padding(14)
        .frame(width: 270)
    }

    private func row(_ c: Choice) -> some View {
        Button { if !c.full { onJoin(c.id) } } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(c.full ? Color.secondary : Color(nsColor: Brand.accentNS))
                Text(c.name.isEmpty ? "Untitled stack" : c.name)
                    .font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 4)
                Text(c.full ? "full" : "\(c.members) of \(NoteStack.maxMembers)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(c.full ? 0.45 : 1)
        .disabled(c.full)
        .accessibilityLabel(c.name)
    }
}

/// The `+` beside a stack's name (owner, 2026-09-26): who is in the stack, and what it is called.
/// Ticking a note adds it to the back of the pile, unticking takes it out and puts it back where it
/// was, and the name field renames the stack — the same rename the bar's double-click does.
struct StackEditorView: View {

    let stackID: String
    /// Members first, in pile order, then the open notes that could join.
    let rows: [StackCreatorView.Candidate]
    let onDone: () -> Void

    @State private var chosen: Set<String>
    @State private var name: String

    init(stack: NoteStack, rows: [StackCreatorView.Candidate], onDone: @escaping () -> Void) {
        self.stackID = stack.id
        self.rows = rows
        self.onDone = onDone
        _chosen = State(initialValue: Set(stack.members))
        _name = State(initialValue: stack.name)
    }

    /// Every note of this stack, in the order the pile draws them, then everything else that is open
    /// and free to join.
    static func rows(for stack: NoteStack) -> [StackCreatorView.Candidate] {
        func candidate(_ id: String) -> StackCreatorView.Candidate? {
            guard let note = VaultStore.shared.note(id: id) else { return nil }
            return .init(id: id, title: note.title.isEmpty ? "Untitled" : note.title,
                         stackName: StackManager.shared.stack(containing: id)?.name)
        }
        let mine = stack.order.compactMap(candidate)
        let others = WindowManager.shared.openPanels
            .map(\.note.id)
            .filter { !stack.members.contains($0) }
            .compactMap(candidate)
        return mine + others
    }

    private var full: Bool { chosen.count >= NoteStack.maxMembers }
    /// Below two members there is no stack left; the choice is allowed, and it dissolves the stack
    /// with every note kept, exactly as Unstack does. The line under the list says so first.
    private var dissolves: Bool { chosen.count < NoteStack.minMembers }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color(nsColor: Brand.accentNS))
                Text("Edit stack").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(chosen.count) of \(NoteStack.maxMembers)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            TextField("Stack name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { apply() }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { r in row(r) }
                }
            }
            .frame(maxHeight: 260)

            HStack {
                Text(dissolves ? "Fewer than \(NoteStack.minMembers) leaves no stack: the notes are kept."
                               : "Ticked notes join the back of the pile.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { apply() }
                    .buttonStyle(ChromeProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func row(_ c: StackCreatorView.Candidate) -> some View {
        let on = chosen.contains(c.id)
        // In another stack already: shown, so nobody wonders where a note went, but not pickable.
        let elsewhere = c.stackName != nil && !chosen.contains(c.id)
        let locked = elsewhere || (!on && full)
        return Button {
            if on { chosen.remove(c.id) } else if !locked { chosen.insert(c.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(on ? Color(nsColor: Brand.accentNS) : .secondary)
                Text(c.title).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 4)
                if elsewhere, let stack = c.stackName {
                    Text("in “\(stack)”").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(locked ? 0.45 : 1)
        .disabled(locked)
        .accessibilityLabel(c.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// What changed, and nothing else: the removals first, so room is freed before anyone joins.
    private func apply() {
        let manager = StackManager.shared
        guard let stack = manager.stack(id: stackID) else { return onDone() }
        manager.rename(stackID, to: name)
        for id in stack.members where !chosen.contains(id) { manager.remove(id, from: stackID) }
        if manager.stack(id: stackID) != nil {
            let joining = rows.map(\.id).filter { chosen.contains($0) && !stack.members.contains($0) }
            manager.add(joining, to: stackID)
        }
        onDone()
    }
}
