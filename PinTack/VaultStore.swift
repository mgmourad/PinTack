import Foundation
import AppKit

/// Owns all file I/O against the vault. SPEC.md §3.
/// Phase 1 scope: load, create, save, delete. No FSEvents watcher yet, no index.
final class VaultStore {

    static let shared = VaultStore()

    private(set) var notes: [Note] = []

    var vaultURL: URL {
        if let saved = UserDefaults.standard.string(forKey: "vaultPath") {
            return URL(fileURLWithPath: saved)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/PinTack", isDirectory: true)
    }

    var attachmentsURL: URL { vaultURL.appendingPathComponent("attachments", isDirectory: true) }
    var metaURL: URL { vaultURL.appendingPathComponent(".pintack", isDirectory: true) }

    // MARK: - Setup

    func bootstrap() {
        let fm = FileManager.default
        for dir in [vaultURL, attachmentsURL, metaURL] {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        loadAll()
        if notes.isEmpty { _ = createNote(body: "# Welcome to PinTack\n\nThis note is a file at:\n`~/Documents/PinTack/`\n\nOpen it in any text editor. It is just Markdown.\n") }
    }

    // MARK: - Reading

    func loadAll() {
        notes = markdownFiles().compactMap { url in
            do { return try Note.load(from: url) }
            catch {
                NSLog("PinTack: failed to load \(url.lastPathComponent): \(error)")
                return nil
            }
        }
        notes.sort { $0.created < $1.created }
    }

    private func markdownFiles() -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: vaultURL,
                                    includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            // Skip the app's own directories.
            if url.path.hasPrefix(attachmentsURL.path) { continue }
            if url.path.hasPrefix(vaultURL.appendingPathComponent("plugins").path) { continue }
            if url.pathExtension.lowercased() == "md" { out.append(url) }
        }
        return out
    }

    // MARK: - Writing

    func createNote(body: String = "", folder: String? = nil) -> Note {
        let dir = folder.map { vaultURL.appendingPathComponent($0, isDirectory: true) } ?? vaultURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent(uniqueFilename(for: body, in: dir))
        let note = Note(fileURL: url, body: body, cardFrame: nextCardFrame())
        notes.append(note)
        save(note)
        return note
    }

    /// Atomic write: temp file in the same directory, then replaceItem.
    /// A partial write must never be able to corrupt a note. SPEC.md §4.5.
    func save(_ note: Note) {
        let text = note.serialized()
        let dir = note.fileURL.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try text.write(to: temp, atomically: false, encoding: .utf8)
            if FileManager.default.fileExists(atPath: note.fileURL.path) {
                _ = try FileManager.default.replaceItemAt(note.fileURL, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: note.fileURL)
            }
            note.modified = Date()
        } catch {
            NSLog("PinTack: save failed for \(note.fileURL.lastPathComponent): \(error)")
            try? FileManager.default.removeItem(at: temp)
        }
    }

    func delete(_ note: Note) {
        try? FileManager.default.trashItem(at: note.fileURL, resultingItemURL: nil)
        notes.removeAll { $0.id == note.id }
    }

    // MARK: - Naming

    /// `YYYY-MM-DD-slug.md`, generated once and never auto-renamed. SPEC.md §3.4.
    private func uniqueFilename(for body: String, in dir: URL) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let date = df.string(from: Date())

        let firstLine = body
            .split(separator: "\n").first
            .map { $0.drop(while: { $0 == "#" || $0 == " " }) } ?? ""
        var slug = String(firstLine)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "untitled" }
        slug = String(slug.prefix(60))

        var candidate = "\(date)-\(slug).md"
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) {
            candidate = "\(date)-\(slug)-\(n).md"
            n += 1
        }
        return candidate
    }

    /// Cascade placement, reset when it would leave the visible screen. SPEC.md §5.5.
    private func nextCardFrame() -> NSRect {
        let size = NSSize(width: 280, height: 210)
        guard let screen = NSScreen.main?.visibleFrame else {
            return NSRect(origin: NSPoint(x: 200, y: 200), size: size)
        }
        let step: CGFloat = 24
        let index = CGFloat(notes.count % 12)
        var origin = NSPoint(x: screen.minX + 80 + index * step,
                             y: screen.maxY - size.height - 80 - index * step)
        if origin.y < screen.minY { origin.y = screen.maxY - size.height - 80 }
        return NSRect(origin: origin, size: size)
    }
}
