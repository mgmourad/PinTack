import AppKit
import UniformTypeIdentifiers

/// Export/import as one JSON file. SPEC.md §14. A convenience layer: the vault
/// folder is already the real backup (zip it).
///
/// Each note travels as its complete file text, so unknown frontmatter keys and
/// the body survive the trip exactly. Attachments are base64.
enum ArchiveIO {

    // MARK: Export

    static func exportAll() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "pintack-archive.json"
        panel.title = "Export all notes"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try archiveData()
            try AtomicWriter.write(data, to: url)
            Toast.show("Exported \(VaultStore.shared.notes.count) notes")
        } catch {
            alert("Export failed", error.localizedDescription)
        }
    }

    static func archiveData(store: VaultStore = .shared) throws -> Data {
        SaveCoordinator.shared.flushAll()
        let root = store.vaultURL.standardizedFileURL.path
        let notes: [[String: Any]] = store.notes.map { n in
            let rel = String(n.fileURL.standardizedFileURL.path.dropFirst(root.count + 1))
            return ["id": n.id, "path": rel, "content": n.serialized()]
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: store.attachmentsURL, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let attachments: [[String: Any]] = files.compactMap { f in
            guard let data = try? Data(contentsOf: f) else { return nil }
            return ["name": f.lastPathComponent, "data": data.base64EncodedString()]
        }
        let doc: [String: Any] = [
            "app": "PinTack", "version": 1,
            "exported": ISO8601DateFormatter().string(from: Date()),
            "notes": notes, "attachments": attachments,
        ]
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Import

    static func importArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.title = "Import PinTack archive"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try importArchive(from: Data(contentsOf: url), askOnConflict: askForConflict)
            Toast.show("Imported \(result.added) new, \(result.replaced) replaced, \(result.skipped) skipped")
        } catch {
            alert("That file is not a PinTack archive", error.localizedDescription)
        }
    }

    enum ConflictChoice { case keep, replace, duplicate }
    struct ImportResult { var added = 0, replaced = 0, skipped = 0 }
    struct ArchiveError: LocalizedError { let errorDescription: String? }

    /// Merges rather than replaces, keyed on `id`. SPEC.md §14.
    static func importArchive(from data: Data, store: VaultStore = .shared,
                              askOnConflict: (Note) -> ConflictChoice) throws -> ImportResult {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              doc["app"] as? String == "PinTack",
              let notes = doc["notes"] as? [[String: Any]] else {
            throw ArchiveError(errorDescription: "Missing the PinTack archive header or notes list.")
        }
        var result = ImportResult()
        var written: [URL] = []

        for entry in notes {
            guard let content = entry["content"] as? String, let rel = entry["path"] as? String,
                  let dest = safeDestination(rel, in: store.vaultURL) else { result.skipped += 1; continue }

            let incoming = Note.parse(content, fileURL: dest)
            if let existing = store.note(id: incoming.id) {
                switch askOnConflict(existing) {
                case .keep: result.skipped += 1; continue
                case .replace:
                    try AtomicWriter.write(content, to: existing.fileURL)
                    written.append(existing.fileURL)
                    result.replaced += 1
                case .duplicate:
                    incoming.id = Note.newID()
                    let dup = dest.deletingLastPathComponent()
                        .appendingPathComponent(VaultStore.uniqueFilename(for: incoming.body, in: dest.deletingLastPathComponent()))
                    try FileManager.default.createDirectory(at: dup.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try AtomicWriter.write(incoming.serialized(), to: dup)
                    written.append(dup)
                    result.added += 1
                }
            } else {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let target = FileManager.default.fileExists(atPath: dest.path)
                    ? dest.deletingLastPathComponent().appendingPathComponent(
                        VaultStore.uniqueFilename(for: incoming.body, in: dest.deletingLastPathComponent()))
                    : dest
                try AtomicWriter.write(content, to: target)
                written.append(target)
                result.added += 1
            }
        }

        for att in (doc["attachments"] as? [[String: Any]]) ?? [] {
            guard let name = att["name"] as? String, !name.contains("/"), !name.hasPrefix("."),
                  let b64 = att["data"] as? String, let bytes = Data(base64Encoded: b64) else { continue }
            let dest = store.attachmentsURL.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.createDirectory(at: store.attachmentsURL, withIntermediateDirectories: true)
                try? AtomicWriter.write(bytes, to: dest)
            }
        }

        store.handleExternalChanges(written)
        return result
    }

    /// An archive is untrusted input: refuse anything that would land outside the
    /// vault, in a hidden or reserved folder, or that is not a Markdown file.
    static func safeDestination(_ relative: String, in vault: URL) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !relative.hasPrefix("/"), let last = parts.last, last.lowercased().hasSuffix(".md"),
              !parts.contains(where: { $0 == ".." || $0.hasPrefix(".") }),
              parts.first != "attachments", parts.first != "plugins" else { return nil }
        return parts.reduce(vault) { $0.appendingPathComponent($1) }
    }

    // MARK: UI helpers

    private static func askForConflict(_ existing: Note) -> ConflictChoice {
        let alert = NSAlert()
        alert.messageText = "“\(existing.title)” already exists"
        alert.informativeText = "A note with the same id is already in your vault."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .duplicate
        default: return .keep
        }
    }

    private static func alert(_ title: String, _ detail: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.runModal()
    }
}
