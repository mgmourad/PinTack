import SwiftUI
import AppKit

/// Drives the All Notes window. Reloads whenever the vault changes.
final class AllNotesModel: ObservableObject {

    enum Mode: String { case folders = "Folders", tags = "Tags", todo = "Todo", templates = "Templates", stacks = "Stacks" }
    enum Selection: Hashable { case all, folder(String), tag(String) }

    /// How the todo tab is ordered. SPEC.md §6.
    enum TodoSort: String, CaseIterable, Identifiable {
        case created = "Date created"
        case mostDone = "Most done first"
        case leastDone = "Least done first"
        case due = "Due date (urgent first)"
        var id: String { rawValue }
    }

    /// One model for the window, so a shortcut can switch its tab while it is already open.
    static let shared = AllNotesModel()

    /// Which tab opens first. Resolved lazily on first use so it does not depend on when the
    /// self-test happens to run relative to the window being built.
    static var debugInitialMode: Mode = {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["PINTACK_ALLNOTES_TAB"] {
        case "todo":      return .todo
        case "templates": return .templates
        case "stacks":    return .stacks
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
    @Published var selectedStacks = Set<String>()     // ids of the checked stacks, in the Stacks tab

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .vaultDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.revision += 1
            // Forget checked notes that no longer exist (deleted, or removed outside the app).
            let alive = Set(VaultStore.shared.notes.map(\.id))
            self.selected.formIntersection(alive)
            self.selectedStacks.formIntersection(Set(StackManager.shared.stacks.map(\.id)))
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

    /// Every stack, found by its name or by the title of any note in it. SPEC.md §5.10.
    var stacks: [NoteStack] {
        _ = revision
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = StackManager.shared.stacks
        let found = q.isEmpty ? all : all.filter { s in
            s.name.lowercased().contains(q) || StackManager.shared.notes(of: s).contains { $0.title.lowercased().contains(q) }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    @ObservedObject private var model = AllNotesModel.shared
    @ObservedObject private var settings = AppSettings.shared
    @Namespace private var sidebarPill

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 208)
                .background(Color.chromeSidebar)
            Rectangle().fill(Color.chromeHairline).frame(width: 1)
            main
                .background(Color.chromeWindow)
        }
        .tint(Color.chromeHighlight)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Glyphs rather than words: three labelled tabs crowded the sidebar.
            // Each segment carries its own tip: one .help() on the Picker described all four at
            // once, which told you nothing about the icon under the pointer.
            GlyphTabs(selection: $model.mode, items: [
                .init(value: .folders, symbol: "folder.fill", text: "", help: Tip.text("Folders", "Your notes, by the folder they are filed in")),
                .init(value: .tags, symbol: "number", text: "", help: Tip.text("Tags", "Your notes, by #tag")),
                .init(value: .todo, symbol: nil, text: "@", help: Tip.text("Todos", "Every todo note and how done it is")),
                .init(value: .templates, symbol: "cube.box.fill", text: "", help: Tip.text("Templates", "Notes saved as @name, to drop into any note")),
                .init(value: .stacks, symbol: "square.stack.3d.up.fill", text: "", help: Tip.text("Stacks", "Temporary piles of open notes to save screen space.")),
            ])
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)

            if model.mode == .todo { todoControls }
            if model.mode == .templates { templateControls }
            if model.mode == .stacks { stackControls }

            if model.mode == .todo || model.mode == .templates || model.mode == .stacks { Spacer() } else {
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
                        .tip("New folder", "Make a folder in the vault to file notes in")
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

            Divider()
            HStack {
                settingsButton
                Spacer()
            }
            .padding(.horizontal, 6).padding(.bottom, 2)
        }
    }

    /// The todo tab's ordering, and whether finished todos are shown at all.
    private var todoControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $model.todoSort) {
                ForEach(AllNotesModel.TodoSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .tip("Sort", "Order the todos by date, how done they are, or due date")
            Toggle("Show done todos", isOn: $model.showDoneTodos)
                .font(.system(size: 12))
                .tip("Show done todos", "List finished todos too, struck through")
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

    /// The Stacks tab's sidebar: what a stack is and how to make one.
    private var stackControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A stack piles 2 to 5 open notes into one, title bars showing. Click the paperclip on a note to make one.")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(model.stacks.count) stack\(model.stacks.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder private var stackList: some View {
        let stacks = model.stacks
        if stacks.isEmpty {
            Spacer()
            Text(model.query.isEmpty ? "No stacks yet. Click the paperclip on a note's title bar to stack it with others."
                                     : "No stacks match “\(model.query)”.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            Spacer()
        } else {
            HStack {
                Button(model.selectedStacks.isEmpty ? "Select all" : "Clear selection") {
                    model.selectedStacks = model.selectedStacks.isEmpty ? Set(stacks.map(\.id)) : []
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                .tip(model.selectedStacks.isEmpty ? "Select all" : "Clear selection", "Pick every stack listed, or none")
                Spacer()
                Text(model.selectedStacks.isEmpty ? "\(stacks.count) stack\(stacks.count == 1 ? "" : "s")" : "\(model.selectedStacks.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(stacks) { s in StackRow(stack: s, model: model) { deleteStacks([s.id]) } }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }

            Divider()
            HStack(spacing: 8) {
                Menu {
                    Button("Vault root (no folder)") { moveStacks(to: "") }
                    if !model.folders.isEmpty { Divider() }
                    ForEach(model.folders, id: \.self) { f in Button(f) { moveStacks(to: f) } }
                    Divider()
                    Button("New folder…") { if let f = newFolderName() { moveStacks(to: f) } }
                } label: {
                    Text("Add to Folder")
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(model.selectedStacks.isEmpty)
                .tip("Add to Folder", "Move every note of the selected stacks into a folder; they stay stacked")

                Button(role: .destructive) { deleteStacks(Array(model.selectedStacks)) } label: { Text("Delete selected") }
                    .fixedSize()
                    .disabled(model.selectedStacks.isEmpty)
                    .tip("Delete selected", "Delete the selected stacks and their notes, after asking")
                Spacer()
            }
            .padding(10)
        }
    }

    private func moveStacks(to folder: String) {
        let ids = Array(model.selectedStacks)
        StackManager.shared.move(ids, toFolder: folder)
        Toast.show("Moved \(ids.count) stack\(ids.count == 1 ? "" : "s") to " + (folder.isEmpty ? "the vault root" : folder))
        model.selectedStacks = []
    }

    /// Deleting a stack deletes its NOTES (owner decision, 2026-09-22), so it always asks first,
    /// and Return in that question unstacks instead. See `StackDeleteAlert`.
    private func deleteStacks(_ ids: [String]) {
        let doomed = StackManager.shared.stacks.filter { ids.contains($0.id) }
        // WindowManager.delete shows the Undo toast; a second toast here would replace it.
        if StackDeleteAlert.run(for: doomed) != .cancel { model.selectedStacks.subtract(ids) }
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
                .tip(model.selected.isEmpty ? "Select all" : "Clear selection", "Pick every template listed, or none")
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
                .tip("Add to Folder", "Move the selected templates into a folder")

                Button("Delete selected", role: .destructive) { deleteSelected() }
                    .disabled(model.selected.isEmpty)
                    .fixedSize()
                    .tip("Delete selected", "Move the selected templates to the Trash, after asking")
                Spacer()
            }
            .padding(10)
        }
    }

    /// Shortcut to Settings, in the sidebar's own bottom-left corner so it sits under the folder
    /// list rather than crowding the buttons that act on the notes.
    private var settingsButton: some View {
        Button { withAnimation(ChromeMotion.spring) { MainWindowModel.shared.tab = .settings } } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17, weight: .regular))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .tip("Settings", "Open PinTack's settings")
    }

    private func row(icon: String, title: String, sel: AllNotesModel.Selection, indent: Int) -> some View {
        let chosen = model.selection == sel
        return HStack(spacing: 9) {
            Image(systemName: icon).symbolVariant(chosen ? .fill : .none)
                .font(.system(size: 14, weight: .medium)).frame(width: 18)
                .foregroundStyle(chosen ? Color.chromeOnHighlight : .secondary)
            Text(title).lineLimit(1).font(.system(size: 13, weight: chosen ? .semibold : .medium))
            Spacer()
            Text("\(model.count(for: sel))").font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(chosen ? Color.chromeOnHighlight.opacity(0.7) : Color.secondary.opacity(0.8))
        }
        .foregroundStyle(chosen ? Color.chromeOnHighlight : Color.primary.opacity(0.85))
        .padding(.horizontal, 10).frame(height: 32)
        .padding(.leading, CGFloat(indent) * 14)
        .background {
            if chosen {
                RoundedRectangle(cornerRadius: 9).fill(Color.chromeHighlight)
                    .matchedGeometryEffect(id: "sidebarRow", in: sidebarPill)
                    .shadow(color: Color.chromeHighlight.opacity(0.3), radius: 6, y: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(ChromeMotion.spring) { model.selection = sel } }
        .tip(title, { switch sel {
            case .all: return "Every note in the vault"
            case .folder: return "The notes filed in this folder"
            case .tag: return "The notes tagged #" + title
        } }())
    }

    // MARK: Main

    private var main: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.mode == .stacks ? "Search stacks" : "Search notes", text: $model.query).textFieldStyle(.plain)
                    .tip("Search", model.mode == .stacks ? "Find a stack by its name or any note in it" : "Find notes by their words, title or tags")
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .tip("Clear search", "Show everything again")
                }
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.chromeSurface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.chromeHairline))
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 6)

            switch model.mode {
            case .todo:      todoList
            case .templates: templateList
            case .stacks:    stackList
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
            let chosen = todos.filter { model.selected.contains($0.id) }
            HStack {
                Button(chosen.isEmpty ? "Select all" : "Clear selection") {
                    if chosen.isEmpty { model.selected.formUnion(todos.map(\.id)) } else { model.selected.subtract(todos.map(\.id)) }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                .tip(chosen.isEmpty ? "Select all" : "Clear selection", chosen.isEmpty ? "Pick every todo listed" : "Unpick every todo")
                Spacer()
                Text(chosen.isEmpty ? "\(todos.count) todo\(todos.count == 1 ? "" : "s")" : "\(chosen.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(todos, id: \.id) { note in TodoRow(note: note, model: model) }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 8) {
                Button("New todo") { WindowManager.shared.newTodo() }.fixedSize()
                    .tip("New todo", "Start a todo note on the desktop")
                Spacer()
                // Finishing a todo ticks every box in it (owner, 2026-09-22: this replaced the
                // per-row checkbox, which is now a selection box).
                Button("Mark Complete") { markComplete(chosen) }
                    .buttonStyle(ChromeProminentButtonStyle())
                    .fixedSize()
                    .disabled(chosen.isEmpty)
                    .opacity(chosen.isEmpty ? 0.45 : 1)
                    .tip("Mark Complete", "Tick every task in the selected todos")
                Button(role: .destructive) { deleteTodos(chosen) } label: { Text("Delete selected") }
                    .fixedSize()
                    .disabled(chosen.isEmpty)
                    .tip("Delete selected", "Move the selected todos to the Trash, with Undo")
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
                .tip(model.selected.isEmpty ? "Select all" : "Clear selection", "Pick every note listed, or none")
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
                .buttonStyle(ChromeProminentButtonStyle())
                .fixedSize()
                .tip("New note", "Start a note on the desktop, in the folder you are looking at")
                Button("New folder") { newFolder() }.fixedSize()
                    .tip("New folder", "Make a folder in the vault to file notes in")
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
                .tip("Add to Folder", "Move the selected notes into a folder")

                Button(role: .destructive) { deleteSelected() } label: { Text("Delete selected") }
                    .fixedSize()
                    .disabled(model.selected.isEmpty)
                    .tip("Delete selected", "Move the selected notes to the Trash, after asking")

                Divider().frame(height: 18)
                Button("Export all") { ArchiveIO.exportAll() }.fixedSize()
                    .tip("Export all", "Save every note into one JSON archive")
                Button("Import") { ArchiveIO.importArchive() }.fixedSize()
                    .tip("Import", "Bring notes in from a PinTack archive")
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

    private func markComplete(_ todos: [Note]) {
        for note in todos { NoteRowActions.setAllDone(note, true) }
        Toast.show(todos.count == 1 ? "Marked complete" : "Marked \(todos.count) todos complete")
        model.selected.subtract(todos.map(\.id))
    }

    private func deleteTodos(_ todos: [Note]) {
        let n = todos.count
        guard n > 0, Prompt.confirm(title: "Move \(n) todo\(n == 1 ? "" : "s") to the Trash?",
                                    message: "The files go to the Trash, so you can still get them back from there.",
                                    button: "Move to Trash", destructive: true) else { return }
        // WindowManager.delete shows the toast, with Undo. A second toast here would replace it.
        WindowManager.shared.delete(todos)
        model.selected.subtract(todos.map(\.id))
    }

    private func deleteSelected() {
        let notes = model.selectedNotes
        guard !notes.isEmpty else { return }
        let n = notes.count
        guard Prompt.confirm(title: "Move \(n) note\(n == 1 ? "" : "s") to the Trash?",
                             message: "The files go to the Trash, so you can still get them back from there.",
                             button: "Move to Trash", destructive: true) else { return }
        // WindowManager.delete shows the toast, with Undo. A second toast here would replace it.
        WindowManager.shared.delete(notes)
        model.selected = []
    }
}

/// One stack in the Stacks tab: its name, its notes by number, and show/hide. SPEC.md §5.10.
private struct StackRow: View {

    let stack: NoteStack
    @ObservedObject var model: AllNotesModel
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var renaming = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    private var isSelected: Bool { model.selectedStacks.contains(stack.id) }
    private var shown: Bool { StackManager.shared.isShown(stack) }
    private var notes: [Note] { StackManager.shared.notes(of: stack) }
    private var inPileOrder: [Note] { stack.order.compactMap { VaultStore.shared.note(id: $0) } }

    var body: some View {
        HStack(spacing: 10) {
            Button { if isSelected { model.selectedStacks.remove(stack.id) } else { model.selectedStacks.insert(stack.id) } } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color(nsColor: Brand.accentNS) : Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Deselect" : "Select")

            // The notes' own colours, fanned the way the stack sits on the desk.
            ZStack(alignment: .topLeading) {
                ForEach(Array(notes.prefix(NoteStack.maxMembers).enumerated()), id: \.offset) { i, note in
                    RoundedRectangle(cornerRadius: 2.5).fill(Color(nsColor: note.color))
                        .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 16, height: 11)
                        .offset(y: CGFloat(i) * 3.5)
                }
            }
            .frame(width: 16, height: 26, alignment: .top)

            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Stack name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, weight: .semibold))
                        .focused($renameFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { renaming = false }
                } else {
                    HStack(spacing: 4) {
                        Text(stack.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        if stack.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    }
                    // Numbered by place in the pile, #1 in front, exactly as the title bars are.
                    Text(inPileOrder.enumerated().map { "#\($0.offset + 1) \($0.element.titleWithoutTodoMarker)" }.joined(separator: "  ·  "))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .opacity(shown ? 1 : 0.6)
            Spacer()

            HStack(spacing: 2) {
                RowIconButton("pencil", "Rename", "Change this stack's name") { beginRename() }
                RowIconButton(shown ? "eye" : "eye.slash", shown ? "Hide" : "Show",
                              shown ? "Take the whole stack off the desktop; it stays here" : "Put the whole stack back on the desktop") {
                    if shown { StackManager.shared.hide(stack.id) } else { StackManager.shared.show(stack.id) }
                }
                RowIconButton(image: NoteCardView.struckPaperclip(), "Unstack",
                              "Undo the stack; every note goes back where it was and is kept") {
                    StackManager.shared.unstack(stack.id)
                }
                RowIconButton("trash", "Delete", "Delete the stack and its notes, after asking") { onDelete() }
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(isSelected ? Color.chromeHighlight.opacity(0.2)
                                                            : hovering ? Color.chromeSurfaceHover : .clear))
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !renaming { StackManager.shared.show(stack.id) } }
        .contextMenu {
            Button("Show on Desktop") { StackManager.shared.show(stack.id) }
            Button("Hide from Desktop") { StackManager.shared.hide(stack.id) }
            Button("Rename…") { beginRename() }
            Button("Unstack") { StackManager.shared.unstack(stack.id) }
            Divider()
            Button("Delete Stack and Notes…", role: .destructive) { onDelete() }
        }
    }

    private func beginRename() {
        renameText = stack.name
        renaming = true
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        renaming = false
        StackManager.shared.rename(stack.id, to: renameText)
    }
}

/// One template in the templates tab: its @name, the note it came from, a checkbox so several can be
/// moved into a folder or deleted at once, and show / rename / delete at its right edge.
private struct TemplateRow: View {

    let note: Note
    @ObservedObject var model: AllNotesModel
    @State private var hovering = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    private var isSelected: Bool { model.selected.contains(note.id) }
    private var isRenaming: Bool { model.renamingID == note.id }

    var body: some View {
        HStack(spacing: 10) {
            Button { model.toggle(note) } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color(nsColor: Brand.accentNS) : .secondary)
            }
            .buttonStyle(.plain)
            .tip(isSelected ? "Deselect" : "Select", "Pick this template for Add to Folder or Delete selected")

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    // Renaming a template renames its @name: that is what this row shows and what
                    // recalls it. Same rules as /template.
                    TextField("template-name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .focused($renameFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { model.renamingID = nil }
                } else {
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
            }
            .opacity(note.visible ? 1 : 0.6)
            .contentShape(Rectangle())
            .onTapGesture { if !isRenaming { WindowManager.shared.reveal(note) } }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                RowIconButton(note.visible ? "eye" : "eye.slash",
                              note.visible ? "Hide" : "Show",
                              note.visible ? "Take this template off the desktop; it stays here" : "Put this template on the desktop") {
                    NoteRowActions.toggleShown(note)
                }
                RowIconButton("pencil", "Rename", "Change the @name this template is recalled by") { beginRename() }
                RowIconButton("trash", "Delete", "Move this template's note to the Trash, with Undo") {
                    WindowManager.shared.delete([note])
                }
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering ? Color.chromeSurfaceHover : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { WindowManager.shared.reveal(note) }
            Button("Rename…") { beginRename() }
            Button("Stop being a template") { unmark() }
            Divider()
            Button("Move to Trash", role: .destructive) { WindowManager.shared.delete([note]) }
        }
    }

    private func beginRename() {
        renameText = note.templateName
        model.renamingID = note.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        model.renamingID = nil
        guard renameText != note.templateName else { return }
        TemplateNaming.apply(renameText, to: note)
    }

    /// Keeps the note, drops the template marker — the harmless half of "delete".
    private func unmark() {
        note.templateName = ""
        VaultStore.shared.save(note)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }
}

/// One stack in the Stacks tab: its name, its notes by number, and show/hide. SPEC.md §5.10.

/// One todo note in the todo tab: a selection box, its title, a one-line preview, its progress as
/// squares with a count, and rename / show / delete at its right edge. SPEC.md §6.
private struct TodoRow: View {

    let note: Note
    @ObservedObject var model: AllNotesModel
    @State private var hovering = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    private var counts: (done: Int, total: Int) { note.taskCounts }
    private var isSelected: Bool { model.selected.contains(note.id) }
    private var isRenaming: Bool { model.renamingID == note.id }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // A SELECTION box (owner, 2026-09-22), like every other tab's: finishing happens with
            // Mark Complete at the bottom, for one todo or many.
            Button { model.toggle(note) } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color(nsColor: Brand.accentNS) : .secondary)
            }
            .buttonStyle(.plain)
            .tip(isSelected ? "Deselect" : "Select", "Pick this todo for Mark Complete or Delete selected")
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                if isRenaming {
                    TextField("Title", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, weight: .semibold))
                        .focused($renameFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { model.renamingID = nil }
                } else {
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
            .opacity(note.visible ? 1 : 0.6)
            // The title area opens the note; the checkbox above keeps its own click.
            .contentShape(Rectangle())
            .onTapGesture { if !isRenaming { WindowManager.shared.reveal(note) } }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                RowIconButton("pencil", "Rename", "Change this todo's title") { beginRename() }
                RowIconButton(note.visible ? "eye" : "eye.slash",
                              note.visible ? "Hide" : "Show",
                              note.visible ? "Take this todo off the desktop; it stays here" : "Put this todo on the desktop") {
                    NoteRowActions.toggleShown(note)
                }
                RowIconButton("trash", "Delete", "Move this todo to the Trash, with Undo") { WindowManager.shared.delete([note]) }
            }
        }
        .opacity(note.isDone ? 0.55 : 1)
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(isSelected ? Color.chromeHighlight.opacity(0.2)
                                                            : hovering ? Color.chromeSurfaceHover : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { WindowManager.shared.reveal(note) }
            Button("Rename…") { beginRename() }
            Button(note.isDone ? "Mark as not done" : "Mark all done") { NoteRowActions.setAllDone(note, !note.isDone) }
            Divider()
            Button("Move to Trash", role: .destructive) { WindowManager.shared.delete([note]) }
        }
    }

    private func beginRename() {
        renameText = note.titleWithoutTodoMarker
        model.renamingID = note.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        let text = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        model.renamingID = nil
        guard !text.isEmpty, text != note.titleWithoutTodoMarker else { return }
        WindowManager.shared.rename(note, to: text)
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
            .tip(isSelected ? "Deselect" : "Select", "Pick this note for Add to Folder or Delete selected")

            Circle().fill(Color(nsColor: note.color)).frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
                .tip("Colour", "The note's paper colour")

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
                        // The @Todo marker is how a todo note is WRITTEN, not what it is called.
                        // The todo tab has always stripped it; this list should read the same.
                        Text(note.titleWithoutTodoMarker).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
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
                            .tip("Thaw", "Frozen: clicks pass through it. Click to thaw.")
                        }
                    }
                    Text(snippet).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .opacity(note.visible ? 1 : 0.6)
            Spacer()

            HStack(spacing: 2) {
                RowIconButton(note.visible ? "eye" : "eye.slash", note.visible ? "Hide" : "Show",
                              note.visible ? "Take this note off the desktop; it stays here" : "Put this note on the desktop") {
                    NoteRowActions.toggleShown(note)
                }
                RowIconButton("pencil", "Rename", "Change this note's title") { beginRename() }
                RowIconButton("trash", "Delete", "Move this note to the Trash, with Undo") { WindowManager.shared.delete([note]) }
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(isSelected ? Color.chromeHighlight.opacity(0.2)
                                                            : hovering ? Color.chromeSurfaceHover : .clear))
        .animation(.easeOut(duration: 0.12), value: hovering)
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
}

/// Owns the All Notes window. SPEC.md §8.
/// The All Notes TAB of the one PinTack window (MainWindow.swift). Kept, with the same calls it
/// always had, so nothing that opens All Notes — shortcuts, menus, the Dock — had to change.
final class AllNotesWindowController {

    static let shared = AllNotesWindowController()
    private var main: MainWindowController { .shared }

    var window: NSWindow? { main.window }
    /// On screen AND showing All Notes. The window open on Settings is not All Notes being visible.
    var isVisible: Bool { main.isVisible && main.tab == .allNotes }

    func show() { main.show(.allNotes) }

    /// ⌥⌘H. Closes the window only when it is in front showing All Notes; from Settings it switches
    /// to All Notes, which is what the key is for.
    func toggle() {
        if isVisible && window?.isKeyWindow == true { main.close() } else { show() }
    }

    /// Opens on a particular All Notes tab, or switches to it. A second press of the same shortcut
    /// closes the window, so the key that showed your todos also puts them away.
    func show(mode: AllNotesModel.Mode) {
        if isVisible, window?.isKeyWindow == true, AllNotesModel.shared.mode == mode {
            main.close()
            return
        }
        AllNotesModel.shared.mode = mode
        show()
    }
}
