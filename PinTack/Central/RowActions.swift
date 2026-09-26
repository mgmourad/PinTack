import SwiftUI
import AppKit

/// Tooltips in All Notes and Settings, all in the owner's format (2026-09-22): the control's name,
/// a bar, then what it does. One place, so the format can change in one place.
enum Tip {
    static func text(_ name: String, _ description: String) -> String { "\(name) | \(description)" }

    /// Tooltips wait 1 second (owner, 2026-09-22; first 2 s, which felt slow) so they never flash up
    /// while the pointer is merely passing. Registered, not written: it is a default, and nothing
    /// lands in the user's preferences file. The All Notes glyph tabs have their own, faster ones.
    static let delay: TimeInterval = 1.0
    static func registerDelay() {
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": Int(delay * 1000)])
    }
}

extension View {
    /// A tooltip in the owner's "Name | description" format.
    func tip(_ name: String, _ description: String) -> some View { help(Tip.text(name, description)) }
}

/// The small inline icons at the right edge of every All Notes row.
struct RowIconButton: View {
    var symbol: String?
    var image: NSImage?
    let name: String
    let description: String
    var tint: Color?
    var glowing = false
    let action: () -> Void

    init(_ symbol: String, _ name: String, _ description: String,
         tint: Color? = nil, glowing: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol; self.name = name; self.description = description
        self.tint = tint; self.glowing = glowing; self.action = action
    }

    init(image: NSImage?, _ name: String, _ description: String, action: @escaping () -> Void) {
        self.image = image; self.name = name; self.description = description; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let image { Image(nsImage: image).renderingMode(.template) }
                else if let symbol { Image(systemName: symbol) }
            }
            .frame(width: 22, height: 22).contentShape(Rectangle())
            .shadow(color: glowing ? (tint ?? .clear).opacity(0.7) : .clear, radius: 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? .secondary)
        .tip(name, description)
        .accessibilityLabel(name)
    }
}

/// What a row does to its note, shared by every tab so a note behaves the same wherever it is listed.
enum NoteRowActions {

    /// Off the desktop, still in All Notes. The window's own close, without the blank-note discard.
    static func hide(_ note: Note) {
        SaveCoordinator.shared.flush(noteID: note.id)
        note.visible = false
        VaultStore.shared.save(note)
        WindowManager.shared.close(noteID: note.id)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    static func toggleShown(_ note: Note) {
        if note.visible { hide(note) } else { WindowManager.shared.reveal(note) }
    }

    /// Ticks (or unticks) every checkbox in the note.
    static func setAllDone(_ note: Note, _ done: Bool) {
        // Flush first: the open window may hold edits this would otherwise overwrite.
        SaveCoordinator.shared.flush(noteID: note.id)
        note.markAllTasks(done: done)
        VaultStore.shared.save(note)
        WindowManager.shared.panel(for: note.id)?.card.editor.reloadBody()
        NotificationCenter.default.post(name: .noteBodyDidChange, object: note)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }
}

/// Naming a template, from the /template command or from the Templates tab: the same rules either
/// way. One word (the name is parsed back out of `@name`), `todo` reserved, and a clash asks first.
enum TemplateNaming {

    /// Returns true when the note now carries the name.
    @discardableResult
    static func apply(_ raw: String, to note: Note) -> Bool {
        let name = Note.sanitizedTemplateName(raw)
        guard !name.isEmpty else {
            Toast.show("A template name needs at least one letter or number")
            return false
        }
        guard !Note.reservedTemplateNames.contains(name.lowercased()) else {
            // @todo already means "turn this into a todo note"; a template of that name could
            // never be recalled.
            Toast.show("“\(name)” is reserved — @todo already converts a note")
            return false
        }
        if name == note.templateName { return true }
        if let clash = VaultStore.shared.notes.first(where: {
            $0.id != note.id && $0.templateName.caseInsensitiveCompare(name) == .orderedSame
        }) {
            guard Prompt.confirm(title: "Replace the “\(name)” template?",
                                 message: "“\(clash.title)” is already saved under that name. It stays a note, "
                                        + "but it stops being a template.",
                                 button: "Replace") else { return false }
            clash.templateName = ""
            VaultStore.shared.save(clash)
        }
        SaveCoordinator.shared.flush(noteID: note.id)
        note.templateName = name
        VaultStore.shared.save(note)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
        WindowManager.shared.refreshTemplates()
        Toast.show("Saved as @\(name)")
        return true
    }
}

/// Every All Notes row's icons, in ONE order everywhere (owner, 2026-09-22): show / hide, rename,
/// then anything particular to the tab (Unstack), and delete always last, furthest from the rest.
/// Rows build their icons through this, so the order cannot drift apart again.
struct RowActionIcons: View {
    let shown: Bool
    let showTip: String
    let hideTip: String
    let renameTip: String
    let deleteTip: String
    let onToggleShown: () -> Void
    let onRename: () -> Void
    var onUnstack: (() -> Void)? = nil
    let onDelete: () -> Void

    /// The eye's look, as data rather than as an expression buried in the view, so the self-test can
    /// assert it: on the desk it is lit in the app's orange, off the desk it is struck through and
    /// grey, so a glance down the list says which notes are out (owner, 2026-09-26).
    struct EyeStyle {
        let symbol: String
        let tint: NSColor
        let glowing: Bool

        static func of(shown: Bool) -> EyeStyle {
            shown ? EyeStyle(symbol: "eye", tint: Brand.accentNS, glowing: true)
                  : EyeStyle(symbol: "eye.slash", tint: .secondaryLabelColor, glowing: false)
        }
    }

    var body: some View {
        let eye = EyeStyle.of(shown: shown)
        return HStack(spacing: 2) {
            RowIconButton(eye.symbol, shown ? "Hide" : "Show", shown ? hideTip : showTip,
                          tint: Color(nsColor: eye.tint).opacity(eye.glowing ? 1 : 0.65),
                          glowing: eye.glowing, action: onToggleShown)
            RowIconButton("pencil", "Rename", renameTip, action: onRename)
            if let onUnstack {
                RowIconButton(image: NoteCardView.struckPaperclip(), "Unstack",
                              "Undo the stack; every note goes back where it was and is kept", action: onUnstack)
            }
            RowIconButton("trash", "Delete", deleteTip, action: onDelete)
        }
    }
}
