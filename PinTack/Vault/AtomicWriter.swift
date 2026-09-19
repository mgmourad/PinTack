import Foundation

/// Every write to the vault goes through here. SPEC.md §4.5.
///
/// Write to a temp file in the SAME directory (same volume, so the swap is a
/// rename, not a copy), then `replaceItemAt`. A crash or a full disk mid-write
/// leaves the original untouched; a partial file can never replace a note.
enum AtomicWriter {

    static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: [])
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)      // never leave debris in a synced folder
            throw error
        }
    }
}
