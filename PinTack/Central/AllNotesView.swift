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

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .vaultDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.revision += 1
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var folders: [String] { _ = revision; return VaultStore.shared.folders() }
    var tags: [(tag: String, count: Int)] { _ = revision; return VaultStore.shared.tagCounts() }

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
        .frame(minWidth: 560, minHeight: 380)
        .tint(Color(nsColor: settings.outlineColor))
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
                                .dropDestination(for: String.self) { ids, _ in
                                    for id in ids { if let n = VaultStore.shared.note(id: id) { VaultStore.shared.move(n, toFolder: f) } }
                                    return !ids.isEmpty
                                }
                        }
                        // Dropping on "All notes" moves a note back to the vault root.
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
        .background(RoundedRectangle(cornerRadius: 6).fill(model.selection == sel ? Color.accentColor.opacity(0.28) : .clear))
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
            .padding(10)

            let notes = model.notes
            if notes.isEmpty {
                Spacer()
                Text(model.query.isEmpty ? "No notes here yet. Press \(ShortcutStore.shared.combo(for: .newNote).display) to start one."
                                         : "No notes match “\(model.query)”.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(notes, id: \.id) { note in NoteRow(note: note) }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }

            Divider()
            HStack {
                Button("New note") {
                    let folder: String? = { if case .folder(let f) = model.selection { return f }; return nil }()
                    WindowManager.shared.newNote(folder: folder)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Export all") { ArchiveIO.exportAll() }
                Button("Import") { ArchiveIO.importArchive() }
            }
            .padding(10)
        }
    }
}

private struct NoteRow: View {

    let note: Note
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(nsColor: note.color)).frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(note.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(snippet).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(note.visible ? 1 : 0.45)
            Spacer()
            Button {
                if note.visible { hide() } else { WindowManager.shared.reveal(note) }
            } label: {
                Image(systemName: note.visible ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(note.visible ? "Hide from desktop" : "Show on desktop")
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { WindowManager.shared.reveal(note) }
        .draggable(note.id)
        .contextMenu {
            Button("Show on Desktop") { WindowManager.shared.reveal(note) }
            Button("Duplicate") { WindowManager.shared.open(VaultStore.shared.duplicate(note), focus: true) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.fileURL]) }
            Divider()
            Button("Move to Trash", role: .destructive) {
                WindowManager.shared.close(noteID: note.id)
                VaultStore.shared.delete(note)
            }
        }
    }

    private var snippet: String {
        let cleaned = note.body
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 460),
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
