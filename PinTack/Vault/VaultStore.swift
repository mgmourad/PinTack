import Foundation
import AppKit

extension Notification.Name {
    /// The set of notes changed: added, removed, moved, retitled, reloaded.
    static let vaultDidChange = Notification.Name("PinTack.vaultDidChange")
    /// A note's file was edited outside the app and reloaded. `object` is the Note.
    static let noteDidChangeExternally = Notification.Name("PinTack.noteDidChangeExternally")
    /// A note's file was deleted outside the app. `object` is the Note.
    static let noteWasRemoved = Notification.Name("PinTack.noteWasRemoved")
    /// An external edit landed while the note had unsaved in-app edits. SPEC.md §3.7.
    /// userInfo: ["note": Note, "disk": Note]
    static let vaultConflict = Notification.Name("PinTack.vaultConflict")
}

/// Defaults applied to a newly created note (from Settings → Appearance).
struct NoteDefaults {
    var colorHex = "#FFE38A"
    var opacity = 1.0
    var size = Note.defaultCardSize
}

/// Owns all file I/O against the vault. SPEC.md §3.
final class VaultStore {

    static let shared = VaultStore()

    private(set) var notes: [Note] = []

    private let rootOverride: URL?
    private var index: SearchIndex?
    private var watcher: VaultWatcher?

    /// `root` is for tests; the app uses the shared instance.
    init(root: URL? = nil) { rootOverride = root }

    /// PINTACK_VAULT (used by automated runs so they never touch the real vault),
    /// then the user's chosen location, then ~/Documents/PinTack.
    var vaultURL: URL {
        if let rootOverride { return rootOverride }
        if let env = ProcessInfo.processInfo.environment["PINTACK_VAULT"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        if let saved = UserDefaults.standard.string(forKey: "vaultPath"), !saved.isEmpty {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/PinTack", isDirectory: true)
    }

    var attachmentsURL: URL { vaultURL.appendingPathComponent("attachments", isDirectory: true) }
    var metaURL: URL { vaultURL.appendingPathComponent(".pintack", isDirectory: true) }
    var pluginsURL: URL { vaultURL.appendingPathComponent("plugins", isDirectory: true) }

    // MARK: - Setup

    func bootstrap(watch: Bool = true) {
        let fm = FileManager.default
        for dir in [vaultURL, attachmentsURL, metaURL] where !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        loadAll()

        // One welcome note, ever. The marker stops it coming back after the user deletes it.
        let marker = metaURL.appendingPathComponent("welcomed")
        if notes.isEmpty && !fm.fileExists(atPath: marker.path) {
            _ = createNote(body: VaultStore.welcomeBody)
            try? Data().write(to: marker)
        }

        if watch {
            watcher = VaultWatcher(root: vaultURL) { [weak self] urls in self?.handleExternalChanges(urls) }
        }
    }

    static let welcomeBody = """
    # Welcome to PinTack

    Every note is a **plain Markdown file** in `~/Documents/PinTack/`.

    - [x] Notes float on your desktop
    - [ ] Type `/` for commands
    - [ ] Press ⌥⌘N to start a note from anywhere

    > Open the vault in any text editor. It is just Markdown.

    """

    // MARK: - Reading

    func loadAll() {
        notes = markdownFiles().compactMap { url in
            do {
                let note = try Note.load(from: url)
                note.lastWrittenHash = (try? String(contentsOf: url, encoding: .utf8))?.hashValue ?? 0
                return note
            } catch {
                NSLog("PinTack: failed to load \(url.lastPathComponent): \(error)")
                return nil
            }
        }
        resolveDuplicateIDs()
        notes.sort { $0.created < $1.created }
        index = SearchIndex(url: metaURL.appendingPathComponent("index.sqlite"))
        index?.rebuild(notes)
    }

    /// A copied file carries the original's id. Ids are the canonical identity
    /// (SPEC.md §3.4), so the later copy gets a fresh one.
    private func resolveDuplicateIDs() {
        var seen = Set<String>()
        for note in notes.sorted(by: { $0.created < $1.created }) {
            if !seen.insert(note.id).inserted {
                note.id = Note.newID()
                save(note)
            }
        }
    }

    func isNoteFile(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "md" else { return false }
        let root = vaultURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return false }
        let relative = path.dropFirst(root.count + 1)
        if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
        for reserved in ["attachments/", "plugins/"] where relative.hasPrefix(reserved) { return false }
        return true
    }

    private func markdownFiles() -> [URL] {
        guard let e = FileManager.default.enumerator(at: vaultURL,
                                                     includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { isNoteFile($0) }
    }

    func note(id: String) -> Note? { notes.first { $0.id == id } }

    // MARK: - Folders and tags

    /// Folders are directories; nesting is allowed. SPEC.md §3.2.
    func folders() -> [String] {
        guard let e = FileManager.default.enumerator(at: vaultURL,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        let root = vaultURL.standardizedFileURL.path
        var out: [String] = []
        for case let url as URL in e {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
            if rel == "attachments" || rel.hasPrefix("attachments/") || rel == "plugins" || rel.hasPrefix("plugins/") {
                e.skipDescendants(); continue
            }
            out.append(rel)
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Relative directory of the note; "" for a root-level note.
    func folder(of note: Note) -> String {
        let root = vaultURL.standardizedFileURL.path
        let dir = note.fileURL.deletingLastPathComponent().standardizedFileURL.path
        return dir == root ? "" : String(dir.dropFirst(root.count + 1))
    }

    /// Tag → count. Nested tags (`work/northwind`) also count under each ancestor. SPEC.md §3.5.
    func tagCounts() -> [(tag: String, count: Int)] {
        var counts: [String: (display: String, n: Int)] = [:]
        for note in notes {
            var seen = Set<String>()
            for tag in note.tags {
                var path = ""
                for part in tag.split(separator: "/") {
                    path += (path.isEmpty ? "" : "/") + part
                    let key = path.lowercased()
                    guard seen.insert(key).inserted else { continue }
                    counts[key, default: (path, 0)].n += 1
                }
            }
        }
        return counts.values.map { ($0.display, $0.n) }
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    func matches(tag: String, note: Note) -> Bool {
        let t = tag.lowercased()
        return note.tags.contains { $0.lowercased() == t || $0.lowercased().hasPrefix(t + "/") }
    }

    // MARK: - Search

    func search(_ query: String) -> [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return notes }
        if let index, index.isAvailable {
            let ids = index.search(q)
            let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
            return ids.compactMap { byID[$0] }
        }
        return notes.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.body.localizedCaseInsensitiveContains(q) }
    }

    // MARK: - Writing

    @discardableResult
    func createNote(body: String = "", folder: String? = nil, tags: [String] = [],
                    defaults: NoteDefaults = NoteDefaults(), frame: NSRect? = nil) -> Note {
        let dir = (folder?.isEmpty == false) ? vaultURL.appendingPathComponent(folder!, isDirectory: true) : vaultURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent(VaultStore.uniqueFilename(for: body, in: dir))
        let note = Note(fileURL: url, body: body,
                        cardFrame: frame ?? NSRect(origin: NSPoint(x: 200, y: 200), size: defaults.size))
        note.colorHex = defaults.colorHex
        note.opacity = defaults.opacity
        note.tags = tags
        note.hasFrame = frame != nil
        notes.append(note)
        save(note)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
        return note
    }

    /// Atomic write. SPEC.md §4.5.
    func save(_ note: Note) {
        note.mergeInlineTags()
        note.modified = Date()
        let text = note.serialized()
        do {
            try AtomicWriter.write(text, to: note.fileURL)
            note.lastWrittenHash = text.hashValue
            index?.upsert(note)
        } catch {
            NSLog("PinTack: save failed for \(note.fileURL.lastPathComponent): \(error)")
        }
    }

    func delete(_ note: Note) {
        SaveCoordinator.shared.discard(noteID: note.id)
        try? FileManager.default.trashItem(at: note.fileURL, resultingItemURL: nil)
        notes.removeAll { $0.id == note.id }
        index?.remove(id: note.id)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    @discardableResult
    func duplicate(_ note: Note) -> Note {
        let copy = createNote(body: note.body, folder: folder(of: note),
                              defaults: NoteDefaults(colorHex: note.colorHex, opacity: note.opacity, size: note.cardFrame.size),
                              frame: note.cardFrame.offsetBy(dx: 24, dy: -24))
        copy.tags = note.tags
        copy.theme = note.theme
        copy.unknownBlocks = note.unknownBlocks
        save(copy)
        return copy
    }

    /// Moves the file on disk. Filenames never change, only the directory. SPEC.md §3.4.
    func move(_ note: Note, toFolder folder: String) {
        guard folder != self.folder(of: note) else { return }
        SaveCoordinator.shared.flush(noteID: note.id)
        let dir = folder.isEmpty ? vaultURL : vaultURL.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var dest = dir.appendingPathComponent(note.fileURL.lastPathComponent)
        var n = 2
        let stem = dest.deletingPathExtension().lastPathComponent
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(stem)-\(n).md"); n += 1
        }
        do {
            try FileManager.default.moveItem(at: note.fileURL, to: dest)
            note.fileURL = dest
            NotificationCenter.default.post(name: .vaultDidChange, object: nil)
        } catch {
            NSLog("PinTack: move failed for \(note.fileURL.lastPathComponent): \(error)")
        }
    }

    // MARK: - Naming

    /// `YYYY-MM-DD-slug.md`, generated once and never auto-renamed. SPEC.md §3.4.
    static func uniqueFilename(for body: String, in dir: URL, date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let stamp = df.string(from: date)

        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        let slug = slug(from: firstLine)

        var candidate = "\(stamp)-\(slug).md"
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(stamp)-\(slug)-\(n).md"
            n += 1
        }
        return candidate
    }

    /// Lowercase ASCII alphanumerics and hyphens, collapsed and trimmed, max 60. SPEC.md §3.4.
    static func slug(from text: String) -> String {
        let stripped = text.drop(while: { $0 == "#" || $0 == " " })
        let folded = String(stripped).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var slug = folded
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "untitled" }
        slug = String(slug.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "untitled" : slug
    }

    // MARK: - External edits (SPEC.md §3.7)

    func handleExternalChanges(_ urls: [URL]) {
        var listChanged = false
        for url in Set(urls.map { $0.standardizedFileURL }) where isNoteFile(url) {
            let existing = notes.first { $0.fileURL.standardizedFileURL == url }
            let exists = FileManager.default.fileExists(atPath: url.path)

            switch (existing, exists) {
            case let (note?, false):
                notes.removeAll { $0.id == note.id }
                index?.remove(id: note.id)
                NotificationCenter.default.post(name: .noteWasRemoved, object: note)
                listChanged = true

            case let (note?, true):
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if text.hashValue == note.lastWrittenHash { continue }       // our own write
                let disk = Note.parse(text, fileURL: url)
                if SaveCoordinator.shared.hasPending(noteID: note.id) {
                    // Never silently overwrite either side. The UI asks. SPEC.md §3.7.
                    NotificationCenter.default.post(name: .vaultConflict, object: nil,
                                                    userInfo: ["note": note, "disk": disk])
                } else {
                    note.adopt(disk)
                    note.lastWrittenHash = text.hashValue
                    index?.upsert(note)
                    NotificationCenter.default.post(name: .noteDidChangeExternally, object: note)
                    listChanged = true
                }

            case (nil, true):
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let note = Note.parse(text, fileURL: url)
                note.lastWrittenHash = text.hashValue
                if notes.contains(where: { $0.id == note.id }) { note.id = Note.newID(); save(note) }
                notes.append(note)
                index?.upsert(note)
                listChanged = true

            case (nil, false):
                break
            }
        }
        if listChanged { NotificationCenter.default.post(name: .vaultDidChange, object: nil) }
    }

    /// Applies the "keep theirs" choice from a conflict prompt.
    func keepDiskVersion(of note: Note, disk: Note) {
        SaveCoordinator.shared.discard(noteID: note.id)
        note.adopt(disk)
        note.lastWrittenHash = disk.serialized().hashValue
        index?.upsert(note)
        NotificationCenter.default.post(name: .noteDidChangeExternally, object: note)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    /// The "open both" choice: keep this note, and add the disk version as a second note.
    @discardableResult
    func adoptDiskVersionAsCopy(_ disk: Note) -> Note {
        let copy = createNote(body: disk.body, folder: folder(of: disk))
        copy.tags = disk.tags; copy.colorHex = disk.colorHex; copy.unknownBlocks = disk.unknownBlocks
        save(copy)
        return copy
    }

    // MARK: - Attachments (SPEC.md §7)

    /// `attachments/YYYY-MM-DD-HHMMSS.ext`. Returns the vault-relative path.
    func writeAttachment(_ data: Data, ext: String) -> String? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        let safeExt = ext.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(5)
        let stem = df.string(from: Date())
        var name = "\(stem).\(safeExt.isEmpty ? "png" : String(safeExt))"
        var n = 2
        while FileManager.default.fileExists(atPath: attachmentsURL.appendingPathComponent(name).path) {
            name = "\(stem)-\(n).\(safeExt.isEmpty ? "png" : String(safeExt))"; n += 1
        }
        try? FileManager.default.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        do {
            try AtomicWriter.write(data, to: attachmentsURL.appendingPathComponent(name))
            return "attachments/\(name)"
        } catch {
            NSLog("PinTack: attachment write failed: \(error)")
            return nil
        }
    }

    /// Copies an existing file into `attachments/`. Returns the vault-relative path.
    func importAttachment(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return writeAttachment(data, ext: url.pathExtension)
    }

    /// Attachment files no note references. Listed for the user to delete; never
    /// deleted automatically. SPEC.md §7.
    func orphanedAttachments() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: attachmentsURL, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let allText = notes.map(\.body).joined(separator: "\n")
        return files.filter { !allText.contains($0.lastPathComponent) }
    }
}
