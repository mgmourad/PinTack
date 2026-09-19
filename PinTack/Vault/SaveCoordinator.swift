import Foundation

/// Debounced save. SPEC.md §4.5: N ms after the last keystroke, plus an
/// immediate flush on window blur, note close and app termination.
final class SaveCoordinator {

    static let shared = SaveCoordinator()

    private var timers: [String: Timer] = [:]
    private var notes: [String: Note] = [:]

    /// Seconds. Configurable in Settings → Notes.
    var delay: TimeInterval = 0.8

    func scheduleSave(_ note: Note) {
        timers[note.id]?.invalidate()
        notes[note.id] = note
        timers[note.id] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.flush(noteID: note.id)
        }
    }

    /// True while the note has edits that are not on disk yet. The watcher uses
    /// this to decide between silent reload and a conflict prompt. SPEC.md §3.7.
    func hasPending(noteID: String) -> Bool { timers[noteID] != nil }

    func flush(noteID: String) {
        timers[noteID]?.invalidate()
        timers.removeValue(forKey: noteID)
        if let note = notes.removeValue(forKey: noteID) { VaultStore.shared.save(note) }
    }

    func flushAll() {
        for id in Array(timers.keys) { flush(noteID: id) }
    }

    /// Drop pending edits without writing (used when the user picks "keep theirs").
    func discard(noteID: String) {
        timers[noteID]?.invalidate()
        timers.removeValue(forKey: noteID)
        notes.removeValue(forKey: noteID)
    }
}
