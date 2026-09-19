import Foundation
import SQLite3

/// SQLite FTS5 search over title, body and tags. SPEC.md §3.6.
///
/// The index is DISPOSABLE: it is derived from the notes, lives in `.pintack/`,
/// and is rebuilt from scratch at launch. It is never a source of truth and
/// never blocks startup: if it cannot open, search falls back to a scan.
final class SearchIndex {

    private var db: OpaquePointer?
    private let url: URL

    init(url: URL) {
        self.url = url
        try? FileManager.default.removeItem(at: url)      // always rebuild, so no stale schema
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { db = nil; return }
        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
                id UNINDEXED, title, body, tags, tokenize = 'unicode61 remove_diacritics 2');
            """)
    }

    deinit { if let db { sqlite3_close(db) } }

    var isAvailable: Bool { db != nil }

    func rebuild(_ notes: [Note]) {
        exec("DELETE FROM fts;")
        exec("BEGIN;")
        notes.forEach { upsertWithoutTransaction($0) }
        exec("COMMIT;")
    }

    func upsert(_ note: Note) {
        remove(id: note.id)
        upsertWithoutTransaction(note)
    }

    func remove(id: String) {
        run("DELETE FROM fts WHERE id = ?;", [id])
    }

    /// Prefix-matches every whitespace-separated term, so typing "spri" finds
    /// "sprint". Returns note ids, best match first.
    func search(_ query: String) -> [String] {
        let terms = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty, let db else { return [] }
        let match = terms.map { "\"\($0)\"*" }.joined(separator: " ")

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM fts WHERE fts MATCH ? ORDER BY rank;", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { ids.append(String(cString: c)) }
        }
        return ids
    }

    // MARK: - Private

    private func upsertWithoutTransaction(_ note: Note) {
        run("INSERT INTO fts(id, title, body, tags) VALUES (?, ?, ?, ?);",
            [note.id, note.title, note.body, note.tags.joined(separator: " ")])
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func run(_ sql: String, _ args: [String]) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), a, -1, SQLITE_TRANSIENT) }
        sqlite3_step(stmt)
    }
}

// The C macro isn't imported into Swift; this is its definition.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
