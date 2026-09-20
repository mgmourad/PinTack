import SwiftUI
import AppKit

/// Drives the All Notes window. Reloads whenever the vault changes.
final class AllNotesModel: ObservableObject {

    enum Mode: String { case folders = "Folders", tags = "Tags" }
    enum Selection: Hashable { case all, folder(String), tag(String) }

    @Published var mode: Mode = .folders { didSet { selection = .all } }
    @Published var selection: Selection = .all
    @Published var query = ""
    @Published private(set) var revision = 0          // bumped on vault change to refresh derived data
    @Published var selected = Set<String>()           // ids of the checked notes
    @Published var renamingID: String?

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .vaultDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.revision += 1
            // Forget checked notes that no longer exist (deleted, or removed outside the app).
            let alive = Set(VaultStore.shared.notes.map(\.id))
            self.selected.formIntersection(alive)
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var folders: [String] { _ = revision; return VaultStore.shared.folders() }
    var tags: [(tag: String, count: Int)] { _ = revision; return VaultStore.shared.tagCounts() }

    var selectedNotes: [Note] { VaultStore.shared.notes.filter { selected.contains($0.id) } }

    func toggle(_ note: Note) {
        if selected.contains(note.id) { selected.remove(note.id) } else { selected.insert(note.id) }
    }

    func count(for sel: Selection) -> Int {
        _ = revision
        let all = VaultStore.shared.notes
        switch sel {
        case .all: return all.count
        case .folder(let f): return all.filter { VaultStore.shared.folder(of: $0) == f }.count
        case .tag(let t): return all.filter { VaultStore.shared.matches(tag: t, note: $0) }.count
        }
    }

    var notes: [Note] {
        _ = revision
        let base = VaultStore.shared.search(query)
        let store = VaultStore.shared
        let filtered: [Note]
        switch selection {
        case .all: filtered = base
        case .folder(let f): filtered = base.filter { store.folder(of: $0) == f }
        case .tag(let t): filtered = base.filter { store.matches(tag: t, note: $0) }
        }
        // While searching, keep the relevance order; otherwise newest first.
        return query.trimmingCharacters(in: .whitespaces).isEmpty ? filtered.sorted { $0.modified > $1.modified } : filtered
    }
}

struct AllNotesView: View {

    @StateObject private var model = AllNotesModel()
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 176)
                .background(.thinMaterial)
            Divider()
            main
        }
        .frame(minWidth: 860, minHeight: 420)
        .tint(Color(nsColor: Brand.accentNS))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $model.mode) {
                Text("Folders").tag(AllNotesModel.Mode.folders)
                Text("Tags").tag(AllNotesModel.Mode.tags)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10).padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    row(icon: "note.text", title: "All notes", sel: .all, indent: 0)
                    if model.mode == .folders {
                        ForEach(model.folders, id: \.self) { f in
                            let depth = f.split(separator: "/").count - 1
                            row(icon: "folder", title: String(f.split(separator: "/").last ?? ""), sel: .folder(f), indent: depth)
                                .dropDestination(for: String.self) { payload, _ in
                                    // A drag carries one id, or several joined by commas when checked notes are dragged.
                                    let ids = payload.flatMap { $0.split(separator: ",").map(String.init) }
                                    for id in ids { if let n = VaultStore.shared.note(id: id) { VaultStore.shared.move(n, toFolder: f) } }
                                    return !ids.isEmpty
                                }
                        }
                        Button { newFolder() } label: {
                            Label("New folder", systemImage: "folder.badge.plus").font(.system(size: 12.5))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 8)
                    } else {
                        ForEach(model.tags, id: \.tag) { t in
                            let depth = t.tag.split(separator: "/").count - 1
                            row(icon: "number", title: String(t.tag.split(separator: "/").last ?? ""), sel: .tag(t.tag), indent: depth)
                        }
                        if model.tags.isEmpty {
                            Text("No tags yet. Type #tag in a note.")
                                .font(.caption).foregroundStyle(.secondary).padding(10)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private func row(icon: String, title: String, sel: AllNotesModel.Selection, indent: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(.secondary)
            Text(title).lineLimit(1)
            Spacer()
            Text("\(model.count(for: sel))").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .padding(.leading, CGFloat(indent) * 14)
        .background(RoundedRectangle(cornerRadius: 6).fill(model.selection == sel ? Color(nsColor: Brand.accentNS).opacity(0.28) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = sel }
    }

    // MARK: Main

    private var main: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search notes", text: $model.query).textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)

            let notes = model.notes
            HStack {
                Button(model.selected.isEmpty ? "Select all" : "Clear selection") {
                    if model.selected.isEmpty { model.selected = Set(notes.map(\.id)) } else { model.selected = [] }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.selected.isEmpty ? "\(notes.count) notes" : "\(model.selected.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.bottom, 4)

            if notes.isEmpty {
                Spacer()
                Text(model.query.isEmpty ? "No notes here yet. Press \(ShortcutStore.shared.combo(for: .newNote).display) to start one."
                                         : "No notes match “\(model.query)”.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(notes, id: \.id) { note in NoteRow(note: note, model: model) }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }

            Divider()
            HStack(spacing: 8) {
                Button("New note") {
                    let folder: String? = { if case .folder(let f) = model.selection { return f }; return nil }()
                    WindowManager.shared.newNote(folder: folder)
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                Button("New folder") { newFolder() }.fixedSize()
                Spacer()

                // Acts on the checked notes.
                Menu {
                    Button("Vault root (no folder)") { move(to: "") }
                    if !model.folders.isEmpty { Divider() }
                    ForEach(model.folders, id: \.self) { f in Button(f) { move(to: f) } }
                    Divider()
                    Button("New folder…") {
                        if let name = Prompt.text(title: "New folder", message: "The selected notes will be moved into it.",
                                                  placeholder: "Folder name", confirm: "Create and Move"),
                           let created = VaultStore.shared.createFolder(name) { move(to: created) }
                    }
                } label: {
                    Text("Add to Folder")
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(model.selected.isEmpty)

                Button(role: .destructive) { deleteSelected() } label: { Text("Delete selected") }
                    .fixedSize()
                    .disabled(model.selected.isEmpty)

                Divider().frame(height: 18)
                Button("Export all") { ArchiveIO.exportAll() }.fixedSize()
                Button("Import") { ArchiveIO.importArchive() }.fixedSize()
            }
            .padding(10)
        }
    }

    // MARK: Actions

    private func newFolder() {
        guard let name = Prompt.text(title: "New folder", message: "Folders are directories inside your vault. Use / for a nested folder.",
                                     placeholder: "Folder name", confirm: "Create"),
              let created = VaultStore.shared.createFolder(name) else { return }
        model.mode = .folders
        model.selection = .folder(created)
    }

    private func move(to folder: String) {
        let notes = model.selectedNotes
        for n in notes { VaultStore.shared.move(n, toFolder: folder) }
        Toast.show("Moved \(notes.count) note\(notes.count == 1 ? "" : "s") to " + (folder.isEmpty ? "the vault root" : folder))
        model.selected = []
    }

    private func deleteSelected() {
        let notes = model.selectedNotes
        guard !notes.isEmpty else { return }
        let n = notes.count
        guard Prompt.confirm(title: "Move \(n) note\(n == 1 ? "" : "s") to the Trash?",
                             message: "The files go to the Trash, so you can still get them back from there.",
                             button: "Move to Trash", destructive: true) else { return }
        WindowManager.shared.delete(notes)
        model.selected = []
        Toast.show("Moved \(n) to Trash")
    }
}

private struct NoteRow: View {

    let note: Note
    @ObservedObject var model: AllNotesModel
    @State private var hovering = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    private var isSelected: Bool { model.selected.contains(note.id) }
    private var isRenaming: Bool { model.renamingID == note.id }

    var body: some View {
        HStack(spacing: 10) {
            // Check circle: selects the note for Add to Folder / Delete selected.
            Button { model.toggle(note) } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color(nsColor: Brand.accentNS) : Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Deselect" : "Select")

            Circle().fill(Color(nsColor: note.color)).frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Title", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, weight: .semibold))
                        .focused($renameFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { model.renamingID = nil }
                } else {
                    HStack(spacing: 4) {
                        Text(note.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                        // A frozen note takes no clicks of its own, so this is the backstop for
                        // thawing one that has ended up somewhere awkward (off-screen, behind
                        // something). See FreezeMode.
                        if note.frozen {
                            Button { thaw() } label: {
                                Image(systemName: "snowflake").font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color(nsColor: Brand.accentNS))
                            .help("Frozen: clicks pass through it. Click to thaw.")
                        }
                    }
                    Text(snippet).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .opacity(note.visible ? 1 : 0.6)
            Spacer()

            HStack(spacing: 2) {
                iconButton(note.visible ? "eye" : "eye.slash", help: note.visible ? "Hide from desktop" : "Show on desktop") {
                    if note.visible { hide() } else { WindowManager.shared.reveal(note) }
                }
                iconButton("pencil", help: "Rename") { beginRename() }
                iconButton("trash", help: "Move to Trash") {
                    WindowManager.shared.delete([note])
                    Toast.show("Moved to Trash")
                }
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Color(nsColor: Brand.accentNS).opacity(0.16)
                                                            : hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // ⌘- or ⇧-click selects, a plain click brings the note forward. SPEC.md §8.
            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) { model.toggle(note) }
            else if !isRenaming { WindowManager.shared.reveal(note) }
        }
        // Dragging a checked note drags the whole selection.
        .draggable(isSelected ? model.selected.sorted().joined(separator: ",") : note.id)
        .contextMenu {
            Button("Show on Desktop") { WindowManager.shared.reveal(note) }
            Button("Rename") { beginRename() }
            Button("Duplicate") { WindowManager.shared.open(VaultStore.shared.duplicate(note), focus: true) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.fileURL]) }
            Divider()
            Button("Move to Trash", role: .destructive) { WindowManager.shared.delete([note]) }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    /// Thaws from the list, for a frozen note that cannot be clicked where it sits.
    private func thaw() {
        note.frozen = false
        WindowManager.shared.panel(for: note.id)?.applyFrozen()
        VaultStore.shared.save(note)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    private func beginRename() {
        renameText = note.title
        model.renamingID = note.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        let text = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        model.renamingID = nil
        guard !text.isEmpty, text != note.title else { return }
        WindowManager.shared.rename(note, to: text)
    }

    private var snippet: String {
        let cleaned = note.body
            .replacingOccurrences(of: #"\[[ xX]\]"#, with: "", options: .regularExpression)     // checkboxes
            .replacingOccurrences(of: #"[#>*`\-\[\]=~|]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // The title is the first line already; show what comes after it.
        let rest = cleaned.hasPrefix(note.title) ? String(cleaned.dropFirst(note.title.count)).trimmingCharacters(in: .whitespaces) : cleaned
        return String(rest.prefix(70)).isEmpty ? "Empty" : String(rest.prefix(70))
    }

    private func hide() {
        SaveCoordinator.shared.flush(noteID: note.id)
        note.visible = false
        VaultStore.shared.save(note)
        WindowManager.shared.close(noteID: note.id)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }
}

/// Owns the All Notes window. SPEC.md §8.
final class AllNotesWindowController {

    static let shared = AllNotesWindowController()
    private(set) var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "All Notes"
            w.contentViewController = NSHostingController(rootView: AllNotesView())
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("PinTackAllNotes")
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if isVisible && window?.isKeyWindow == true { window?.close() } else { show() }
    }
}
