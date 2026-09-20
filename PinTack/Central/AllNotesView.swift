import SwiftUI
import AppKit

/// Drives the All Notes window. Reloads whenever the vault changes.
final class AllNotesModel: ObservableObject {

    enum Mode: String { case folders = "Folders", tags = "Tags", todo = "Todo", templates = "Templates" }
    enum Selection: Hashable { case all, folder(String), tag(String) }

    /// How the todo tab is ordered. SPEC.md §6.
    enum TodoSort: String, CaseIterable, Identifiable {
        case created = "Date created"
        case mostDone = "Most done first"
        case leastDone = "Least done first"
        case due = "Due date (urgent first)"
        var id: String { rawValue }
    }

    /// Which tab opens first. Resolved lazily on first use so it does not depend on when the
    /// self-test happens to run relative to the window being built.
    static var debugInitialMode: Mode = {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["PINTACK_ALLNOTES_TAB"] {
        case "todo":      return .todo
        case "templates": return .templates
        default:          break
        }
        #endif
        return .folders
    }()
    @Published var mode: Mode = AllNotesModel.debugInitialMode { didSet { selection = .all } }
    @Published var selection: Selection = .all
    @Published var query = ""
    @Published private(set) var revision = 0          // bumped on vault change to refresh derived data
    @Published var selected = Set<String>()           // ids of the checked notes
    @Published var renamingID: String?
    @Published var todoSort: TodoSort = .created
    @Published var showDoneTodos = false

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

    /// Todo notes for the todo tab, filtered and ordered. Finished ones are hidden unless asked
    /// for, and when shown they are struck through rather than removed.
    /// Every template in the vault, newest name order.
    var templateNotes: [Note] {
        _ = revision
        var notes = VaultStore.shared.notes.filter(\.isTemplate)
        if !query.isEmpty {
            let q = query.lowercased()
            notes = notes.filter { $0.templateName.lowercased().contains(q) || $0.title.lowercased().contains(q) }
        }
        return notes.sorted { $0.templateName.localizedStandardCompare($1.templateName) == .orderedAscending }
    }

    var todoNotes: [Note] {
        _ = revision
        var notes = VaultStore.shared.notes.filter(\.isTodo)
        if !query.isEmpty {
            let q = query.lowercased()
            notes = notes.filter { $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q) }
        }
        if !showDoneTodos { notes = notes.filter { !$0.isDone } }

        switch todoSort {
        case .created:
            return notes.sorted { $0.created < $1.created }
        case .mostDone:
            return notes.sorted { fraction($0) > fraction($1) }
        case .leastDone:
            return notes.sorted { fraction($0) < fraction($1) }
        case .due:
            // Soonest first; anything with no date sits at the end rather than pretending to be urgent.
            return notes.sorted {
                switch ($0.due, $1.due) {
                case let (a?, b?): return a < b
                case (nil, _?):    return false
                case (_?, nil):    return true
                default:           return $0.created < $1.created
                }
            }
        }
    }

    private func fraction(_ note: Note) -> Double {
        let counts = note.taskCounts
        return counts.total == 0 ? 0 : Double(counts.done) / Double(counts.total)
    }

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
            // Glyphs rather than words: three labelled tabs crowded the sidebar.
            Picker("", selection: $model.mode) {
                Image(systemName: "folder").tag(AllNotesModel.Mode.folders)
                Image(systemName: "number").tag(AllNotesModel.Mode.tags)
                Text("@").tag(AllNotesModel.Mode.todo)
                Image(systemName: "cube.box").tag(AllNotesModel.Mode.templates)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10).padding(.top, 10)
            .help("Folders, tags, todos, or templates")

            if model.mode == .todo { todoControls }
            if model.mode == .templates { templateControls }

            if model.mode == .todo || model.mode == .templates { Spacer() } else {
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
    }

    /// The todo tab's ordering, and whether finished todos are shown at all.
    private var todoControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $model.todoSort) {
                ForEach(AllNotesModel.TodoSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            Toggle("Show done todos", isOn: $model.showDoneTodos)
                .font(.system(size: 12))
            Text("\(model.todoNotes.count) todo\(model.todoNotes.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }

    /// The templates tab's sidebar: what a template is, and what the checked ones can be done with.
    private var templateControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Templates are ordinary notes you have named. Type @name in any note to drop one in.")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(model.templateNotes.count) template\(model.templateNotes.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder private var templateList: some View {
        let templates = model.templateNotes
        if templates.isEmpty {
            Spacer()
            Text("No templates yet. Write a note the way you like it, then type /template to name it.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        } else {
            HStack {
                Button(model.selected.isEmpty ? "Select all" : "Clear selection") {
                    model.selected = model.selected.isEmpty ? Set(templates.map(\.id)) : []
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.selected.isEmpty ? "\(templates.count) templates" : "\(model.selected.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(templates, id: \.id) { note in TemplateRow(note: note, model: model) }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }

            Divider()
            HStack(spacing: 8) {
                settingsButton
                Menu {
                    Button("Vault root (no folder)") { move(to: "") }
                    if !model.folders.isEmpty { Divider() }
                    ForEach(model.folders, id: \.self) { f in Button(f) { move(to: f) } }
                    Divider()
                    Button("New folder…") { if let f = newFolderName() { move(to: f) } }
                } label: {
                    Label("Add to Folder", systemImage: "folder")
                }
                .disabled(model.selected.isEmpty)
                .fixedSize()

                Button("Delete selected", role: .destructive) { deleteSelected() }
                    .disabled(model.selected.isEmpty)
                    .fixedSize()
                Spacer()
            }
            .padding(10)
        }
    }

    /// Shortcut to Settings from the window everything else is managed in.
    private var settingsButton: some View {
        Button { SettingsWindowController.shared.show() } label: {
            Image(systemName: "gearshape").frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("PinTack Settings")
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

            switch model.mode {
            case .todo:      todoList
            case .templates: templateList
            default:         folderAndTagList
            }
        }
    }

    /// The todo tab's body: every todo note with its own progress, newest ordering rules applied
    /// in the sidebar. SPEC.md §6.
    @ViewBuilder private var todoList: some View {
        let todos = model.todoNotes
        if todos.isEmpty {
            Spacer()
            Text(model.showDoneTodos ? "No todo notes yet. Press \(ShortcutStore.shared.combo(for: .newTodo).display) to start one."
                                     : "Nothing left to do. Turn on “Show done todos” to see finished ones.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(todos, id: \.id) { note in TodoRow(note: note, model: model) }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 8) {
                settingsButton
                Button("New todo") { WindowManager.shared.newTodo() }.fixedSize()
                Spacer()
            }
            .padding(10)
        }
    }

    @ViewBuilder private var folderAndTagList: some View {
        VStack(spacing: 0) {
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
                settingsButton
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

    /// Creates a folder and returns its path, for menus that then move something into it.
    private func newFolderName() -> String? {
        guard let name = Prompt.text(title: "New folder", message: "Folders are directories inside your vault. Use / for a nested folder.",
                                     placeholder: "Folder name", confirm: "Create") else { return nil }
        return VaultStore.shared.createFolder(name)
    }

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

/// One todo note in the todo tab: a checkbox that finishes the whole note, its title, a one-line
/// preview, and its progress as squares with a count. SPEC.md §6.
/// One template in the templates tab: its @name, the note it came from, and a checkbox so several
/// can be moved into a folder or deleted at once.
private struct TemplateRow: View {

    let note: Note
    @ObservedObject var model: AllNotesModel
    @State private var hovering = false

    private var isSelected: Bool { model.selected.contains(note.id) }

    var body: some View {
        HStack(spacing: 10) {
            Button { model.toggle(note) } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color(nsColor: Brand.accentNS) : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("@" + note.templateName)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    let folder = VaultStore.shared.folder(of: note)
                    if !folder.isEmpty {
                        Text(folder).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(note.previewLine.isEmpty ? note.title : note.previewLine)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { WindowManager.shared.reveal(note) }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { WindowManager.shared.reveal(note) }
            Button("Stop being a template") { unmark() }
            Divider()
            Button("Move to Trash", role: .destructive) { WindowManager.shared.delete([note]) }
        }
    }

    /// Keeps the note, drops the template marker — the harmless half of "delete".
    private func unmark() {
        note.templateName = ""
        VaultStore.shared.save(note)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }
}

private struct TodoRow: View {

    let note: Note
    @ObservedObject var model: AllNotesModel
    @State private var hovering = false

    private var counts: (done: Int, total: Int) { note.taskCounts }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Ticks or unticks every box in the note at once.
            Button { setAllDone(!note.isDone) } label: {
                Image(systemName: note.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(note.isDone ? Color(nsColor: Brand.accentNS) : .secondary)
            }
            .buttonStyle(.plain)
            .help(note.isDone ? "Mark everything as not done" : "Mark everything as done")
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // Every row here is a todo, so the @Todo marker is noise.
                    Text(note.titleWithoutTodoMarker)
                        .font(.system(size: 12.5, weight: .semibold))
                        .strikethrough(note.isDone)
                        .lineLimit(1)
                    if let due = note.due {
                        Text(due.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(due < Date() ? .red : .secondary)
                    }
                    if note.frozen { Image(systemName: "snowflake").font(.caption2).foregroundStyle(.secondary) }
                }
                if !note.previewLine.isEmpty {
                    Text(note.previewLine)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                if counts.total > 0 {
                    TaskProgressBar(done: counts.done, total: counts.total)
                } else {
                    Text("No tasks yet").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            // The title area opens the note; the checkbox above keeps its own click.
            .contentShape(Rectangle())
            .onTapGesture { WindowManager.shared.reveal(note) }

            Spacer(minLength: 0)
        }
        .opacity(note.isDone ? 0.55 : 1)
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { WindowManager.shared.reveal(note) }
            Button(note.isDone ? "Mark as not done" : "Mark all done") { setAllDone(!note.isDone) }
            Divider()
            Button("Move to Trash", role: .destructive) { WindowManager.shared.delete([note]) }
        }
    }

    private func setAllDone(_ done: Bool) {
        // Flush first: the open window may hold edits this would otherwise overwrite.
        SaveCoordinator.shared.flush(noteID: note.id)
        note.markAllTasks(done: done)
        VaultStore.shared.save(note)
        WindowManager.shared.panel(for: note.id)?.card.editor.reloadBody()
        NotificationCenter.default.post(name: .noteBodyDidChange, object: note)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
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
