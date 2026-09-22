import SwiftUI
import AppKit

/// The paperclip's popover: pick two to five of the notes on the desk and name the stack.
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
            Text("Pick 2 to 5 open notes. This one stays in front as #1.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(candidates) { c in row(c) }
            }
            .padding(.vertical, 2)

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
