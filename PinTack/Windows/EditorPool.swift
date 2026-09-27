import AppKit

/// Which notes keep a live editor, and which are parked (SPEC.md §5.11).
///
/// WebKit gives every web view its own WebContent process — about 27 MB of the 31 MB an open note
/// costs — and nothing makes two views share one (see CLAUDE.md; a shared data store was measured
/// and changed nothing). The only lever left is having fewer live views, so PinTack keeps a few:
/// the note you are in and the last few you were in. Every other note is **parked**: its web view is
/// released, the process with it, and the card shows a picture of the page it had, with the note's
/// text underneath for VoiceOver and for anything else that reads the screen.
///
/// Waking is cheap because a **warm spare** page is kept ready: measured on this Mac, a brand-new
/// web view costs about 100 ms, loading the page again in a view that already exists costs 21 ms,
/// and the spare is what turns the first number into the second. The spare is a real cost — one
/// process, about 27 MB — and it is worth it: without it the first click on a parked note pays the
/// cold start every time.
///
/// Waking RELOADS the page rather than rebinding it in place (3 ms, and measured). A fresh page
/// means a fresh plugin session with fresh capability tokens, which is what the security model
/// already expects when a note opens; rebinding in place would hand a new note the previous note's
/// plugin session, and that is not a trade worth 18 ms.
final class EditorPool {

    static let shared = EditorPool()

    /// Notes that currently hold a live editor, most recently used first.
    private var live: [ObjectIdentifier] = []
    /// Weakly: a card whose note has been closed must be able to go. Held strongly, a closed note's
    /// card outlived its window and then read the window it still thought it had — the panel is an
    /// `unowned` reference, and reading it after the window went crashed the app (2026-09-27).
    private struct Weak { weak var card: NoteCardView? }
    private var entries: [ObjectIdentifier: Weak] = [:]
    private var cards: [ObjectIdentifier: NoteCardView] {
        entries.compactMapValues(\.card)
    }
    /// A page that has already started, waiting for whichever note needs it next.
    private var spare: NoteEditorView?

    var isEnabled: Bool { AppSettings.shared.parkIdleNotesEffective }
    var maxLive: Int { max(1, AppSettings.shared.editorPoolSizeEffective) }
    /// The warm spare is kept, and it is paid for out of the pool rather than on top of it.
    ///
    /// Measured (`PINTACK_WAKEPROBE`): a brand-new page costs **101 ms**, a spare one **21 ms**. A
    /// page costs about 34 MB whichever it is, so a spare and a pooled note cost the same; what
    /// differs is that the spare turns every wake into 21 ms instead of 101. Without it, clicking a
    /// parked note and typing measured 153 ms — past the 150 ms this was held to. Two live notes
    /// plus a spare cost exactly what three live notes cost, and are quicker.
    /// `PINTACK_SPARE=0` prices it the other way.
    var keepsSpare: Bool { ProcessInfo.processInfo.environment["PINTACK_SPARE"] != "0" }

    // MARK: - Bookkeeping

    /// This note is being used: it keeps its editor, and the oldest notes beyond the pool are parked.
    func used(_ card: NoteCardView) {
        let id = ObjectIdentifier(card)
        entries[id] = Weak(card: card)
        live.removeAll { $0 == id }
        live.insert(id, at: 0)
        prune()
        trim()
    }

    /// The card is gone (the note was closed).
    func forget(_ card: NoteCardView) {
        let id = ObjectIdentifier(card)
        live.removeAll { $0 == id }
        entries.removeValue(forKey: id)
    }

    /// Cards whose notes have been closed drop out on their own; their ids go with them.
    private func prune() {
        for (id, entry) in entries where entry.card == nil {
            entries.removeValue(forKey: id)
            live.removeAll { $0 == id }
        }
    }

    /// Parks whatever has fallen out of the pool. A note that is busy — being typed in, holding a
    /// vim prompt, cropping a picture, running a command, waiting to be saved — is never parked; it
    /// simply keeps its editor until it is idle again.
    func trim() {
        guard isEnabled else { return }
        prune()
        // The note with the keyboard is always one of the live ones, whether or not it has been
        // through `used` — at launch macOS gives a window the keyboard without anyone asking. Left
        // out, it sat outside the pool keeping a page of its own: five pages for a pool of four.
        if let keyCard = (NSApp.keyWindow as? NotePanel)?.card {
            let id = ObjectIdentifier(keyCard)
            entries[id] = Weak(card: keyCard)
            live.removeAll { $0 == id }
            live.insert(id, at: 0)
        }
        guard live.count > maxLive else { return }
        var skipped = false
        #if DEBUG
        var refusals: [String] = []
        defer {
            if !refusals.isEmpty, ProcessInfo.processInfo.environment["PINTACK_POOL_LOG"] != nil {
                NSLog("PinTack pool: kept awake — %@", refusals.prefix(5).joined(separator: "; "))
            }
        }
        #endif
        for id in live.dropFirst(maxLive) {
            guard let card = cards[id] else { continue }
            if let why = card.parkRefusal {
                skipped = true
                #if DEBUG
                refusals.append("\(card.debugNoteTitle): \(why)")
                #endif
                continue
            }
            card.park { [weak self] parked in
                guard let self else { return }
                // Only a park that actually happened takes the note off the list. A park that gave
                // up half way left the note holding a page that nothing tracked, for the rest of the
                // session (measured: five live pages for a pool of four).
                if parked { self.live.removeAll { $0 == id } } else { self.scheduleRetry() }
            }
        }
        // A note that was busy — being typed in, saving, running a command — keeps its editor, and
        // the pool comes back for it. Without this it kept that editor for the rest of the session:
        // one note in twenty, 34 MB, measured (2026-09-27).
        if skipped { scheduleRetry() }
    }

    private var retryScheduled = false

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.retryScheduled = false
            self?.trim()
        }
    }

    /// Everything parks that can: used when the setting is switched on, and when the app is hidden.
    func parkEverythingIdle() {
        guard isEnabled else { return }
        trim()
        #if DEBUG
        // After the parking that trim() just started has actually finished: park() takes a picture
        // of the page first, which is asynchronous.
        guard ProcessInfo.processInfo.environment["PINTACK_POOL_LOG"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let awake = self.cards.values.filter { !$0.isParked }
            NSLog("PinTack pool: %d cards, %d still have an editor (%@), pool holds %d, spare %@",
                  self.cards.count, awake.count,
                  awake.prefix(6).map(\.debugNoteTitle).joined(separator: ", "),
                  self.live.count, self.spare == nil ? "no" : "yes")
        }
        #endif
    }

    /// The setting changed: either park what no longer fits, or wake everything back up.
    func settingsChanged() {
        if isEnabled {
            trim()
        } else {
            for card in cards.values where card.isParked { card.wake(reason: "the setting was switched off") }
        }
    }

    // MARK: - Editors

    /// A page for a note that is waking. The spare if there is one, a new view if not.
    func takeEditor(for note: Note, card: NoteCardView) -> NoteEditorView {
        used(card)
        if let ready = spare {
            spare = nil
            ready.adopt(note)
            prepareSpare()
            return ready
        }
        prepareSpare()
        return NoteEditorView(note: note)
    }

    /// Called when a card gives its editor up. The first one back becomes the warm spare; the rest
    /// are released, which is the whole point.
    func give(up editor: NoteEditorView) {
        editor.removeFromSuperview()
        if spare == nil, isEnabled, keepsSpare {
            editor.prepareAsSpare()
            spare = editor
        }
    }

    /// Keeps one page warm and ready. Built on the next turn of the run loop so that waking a note
    /// never waits for the replacement.
    func prepareSpare() {
        guard isEnabled, spare == nil, keepsSpare else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled, self.spare == nil else { return }
            guard let host = NSApp.windows.first(where: { $0 is NotePanel }) ?? NSApp.windows.first else { return }
            guard let note = VaultStore.shared.notes.first else { return }
            let view = NoteEditorView(note: note)
            view.frame = NSRect(x: 0, y: 0, width: 360, height: 280)
            view.prepareAsSpare()
            // A web view outside a window does not load, so the spare lives behind the card of an
            // existing window until somebody needs it. It is never visible: zero alpha, no clicks.
            view.alphaValue = 0
            host.contentView?.addSubview(view, positioned: .below, relativeTo: nil)
            self.spare = view
        }
    }

    #if DEBUG
    var debugLiveCount: Int { live.count }
    var debugHasSpare: Bool { spare != nil }
    func debugReset() { live.removeAll(); entries.removeAll(); spare = nil }
    #endif
}
