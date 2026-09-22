import AppKit

/// One floating note window. SPEC.md §5.1.
///
/// CRITICAL: the NSWindow is LARGER than the visible card by `margin` on every
/// side. macOS clips window content to window bounds, so the overhanging pushpin
/// and the pinned glow cannot be drawn at the card edge. The transparent margin
/// gives them somewhere to live. See SPEC.md §5.2 before changing anything here.
///
/// Consequences, all mandatory:
///   1. NoteCardView overrides hitTest to return nil outside the card, or every
///      note carries an invisible 24pt halo that swallows desktop clicks.
///   2. hasShadow = false; the system would draw it on the transparent box.
///   3. All persisted geometry is the CARD rect, not the window rect.
final class NotePanel: NSPanel {

    static let margin: CGFloat = 24
    static let headerHeight: CGFloat = 30
    static let footerHeight: CGFloat = 32         // room for ChromeSize's 24pt controls
    /// What one extra row of task-tracker squares adds to the action bar.
    static let footerRowHeight: CGFloat = TaskProgressStyle.square + TaskProgressStyle.gap
    static let minCardSize = NSSize(width: 190, height: 120)

    let note: Note
    private(set) var card: NoteCardView!

    init(note: Note) {
        self.note = note
        super.init(contentRect: NotePanel.windowRect(forCard: note.cardFrame),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = isOnTop ? .floating : .normal
        // .canJoinAllSpaces makes every note follow you across Spaces. SPEC.md §5.1.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false   // dragging is handled from the header
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false                     // drawn manually, see above
        alphaValue = effectiveOpacity
        isReleasedWhenClosed = false
        minSize = NSSize(width: NotePanel.minCardSize.width + 2 * NotePanel.margin,
                         height: NotePanel.headerHeight + 2 * NotePanel.margin)

        card = NoteCardView(note: note, panel: self)
        contentView = card
        ignoresMouseEvents = note.frozen
        // Without this AppKit gives the header's title field first responder, which
        // opens every note with its title text selected.
        initialFirstResponder = card.editor
        applyCollapsed(animated: false)
    }

    /// Borderless non-activating panels cannot take text input without this. SPEC.md §5.1.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        WindowManager.shared.noteBecameFocused(note)
        // A note behind the front of its stack that becomes the active window by ANY route — a click
        // on its title bar (macOS raises it on the press), Mission Control, ⌘` — comes to the front
        // of the pile properly, the others springing back behind it. Left alone, macOS raised just
        // that window and the rest of the pile stayed where it was (owner-reported, 2026-09-22).
        // Next turn of the run loop: re-ordering windows from inside becomeKey is asking for trouble.
        if StackManager.shared.stack(containing: note.id) != nil, !StackManager.shared.isFront(note.id) {
            DispatchQueue.main.async { [weak self] in
                // STILL key, and still not the front, by the time this runs. A click on a back note's
                // title bar is delivered to the window in FRONT of it (its margin covers most of that
                // title bar), and macOS makes THAT window key; the card hands the click on to the note
                // the pointer was actually over. Without this guard the stale key event then dragged
                // the wrong note forward a moment later — "it moves, but not the one I clicked"
                // (owner-reported, 2026-09-22).
                guard let self, self.isKeyWindow, !StackManager.shared.isFront(self.note.id) else {
                    StackManager.shared.record("became key", "ignored: the window is no longer key, or is already in front")
                    return
                }
                // A click already handed to the note under the pointer: this window became key only
                // because macOS raised whatever the press landed on, which is usually the note IN
                // FRONT of the one aimed at. Acting on it drags the wrong note forward.
                guard !StackManager.shared.isSettlingAClick else {
                    StackManager.shared.record("became key", "ignored: a click was just passed on to another note")
                    return
                }
                StackManager.shared.bringToFront(self.note.id, reason: "became key")
            }
        }
    }

    /// Immediate save on window blur. SPEC.md §4.5.
    override func resignKey() {
        super.resignKey()
        SaveCoordinator.shared.flush(noteID: note.id)
    }

    // MARK: Geometry

    static func windowRect(forCard card: NSRect) -> NSRect {
        card.insetBy(dx: -margin, dy: -margin)
    }

    static func cardRect(forWindow window: NSRect) -> NSRect {
        window.insetBy(dx: margin, dy: margin)
    }

    /// The visible card for the current state: full height, or header-only when collapsed.
    ///
    /// The stored `cardFrame` is always the expanded card with a PLAIN action bar. Two things
    /// change what is actually on screen, and both are re-derived rather than persisted, so the
    /// stored rect cannot drift: collapsing keeps the top edge and shows the header only, and a
    /// task tracker that has wrapped onto more rows pushes the BOTTOM edge down (owner decision,
    /// 2026-09-20) — down rather than up, so the text you are typing never moves.
    private var visibleCardRect: NSRect {
        let full = note.cardFrame
        guard !note.collapsed else {
            // A collapsed note in a stack keeps its stack bar, which holds the way back out.
            let height = NotePanel.headerHeight + (card?.stackBarHeight ?? 0)
            return NSRect(x: full.minX, y: full.maxY - height, width: full.width, height: height)
        }
        let extra = footerExtra
        guard extra > 0 else { return full }
        return NSRect(x: full.minX, y: full.minY - extra, width: full.width, height: full.height + extra)
    }

    /// How much a wrapped task tracker adds to this note's height. Behind the front of a stack it
    /// adds nothing: only the front note's action bar is visible, and a taller card behind it poked
    /// its bar out under the pile as a stray strip of another colour (owner-reported, 2026-09-22).
    private var footerExtra: CGFloat {
        guard let stack = StackManager.shared.stack(containing: note.id) else { return card?.extraFooterHeight ?? 0 }
        return stack.front == note.id ? (card?.extraFooterHeight ?? 0) : 0
    }

    /// Persist the CARD rect, never the window rect. SPEC.md §5.2.
    func syncFrameToNote() {
        let visible = NotePanel.cardRect(forWindow: frame)
        if note.collapsed {
            note.cardFrame = NSRect(x: visible.minX, y: visible.maxY - note.cardFrame.height,
                                    width: visible.width, height: note.cardFrame.height)
        } else {
            // Take the tracker's extra rows back out: what is stored is the plain-bar card.
            let extra = footerExtra
            note.cardFrame = NSRect(x: visible.minX, y: visible.minY + extra, width: visible.width,
                                    height: max(NotePanel.headerHeight, visible.height - extra))
        }
    }

    func applyCollapsed(animated: Bool) {
        let target = NotePanel.windowRect(forCard: visibleCardRect)
        // NOT setFrame(_:display:animate:): that one spins a NESTED RUN LOOP until the animation
        // ends, stalling the main thread for ~270 ms mid-keystroke and letting the rest of the
        // press dispatch land outside any time-based de-dupe (see ActionRouter.perform).
        if animated { Motion.springFrame(self, to: target) } else { setFrame(target, display: true) }
        card?.updateCollapsedState()
    }

    /// The task tracker gained or lost a row, so the action bar is a row taller or shorter. Uses
    /// the same spring as collapsing, since the owner wants window movement lively (2026-09-20).
    func applyFooterHeight(animated: Bool) {
        guard !note.collapsed else { return }
        // A note low on the screen would otherwise grow off the bottom of it.
        if let limit = (screen ?? NSScreen.main)?.visibleFrame {
            let bottom = visibleCardRect.minY
            if bottom < limit.minY { note.cardFrame.origin.y += limit.minY - bottom }
        }
        let target = NotePanel.windowRect(forCard: visibleCardRect)
        guard target != frame else { return }
        if animated { Motion.springFrame(self, to: target) } else { setFrame(target, display: true) }
    }

    /// Moves the card, springing through `Motion` when animated: AppKit's own window animator does
    /// not run at all while the app is inactive, which is most of the time (CLAUDE.md).
    func placeCard(_ rect: NSRect, animated: Bool) {
        note.cardFrame = rect
        let target = NotePanel.windowRect(forCard: visibleCardRect)
        if animated { Motion.springFrame(self, to: target) } else { setFrame(target, display: true) }
    }

    func applyCardFrame(_ rect: NSRect, animated: Bool = false) {
        note.cardFrame = rect
        setFrame(NotePanel.windowRect(forCard: visibleCardRect), display: true, animate: animated)
    }

    /// How much a finished todo fades (owner decision, 2026-09-21): enough to read as put away,
    /// not so much that it cannot be read.
    static let doneDimming: CGFloat = 0.72

    /// What the window's opacity actually is. `note.opacity` is what the user set; a finished todo
    /// is dimmed on top of that, and the dimming is never written back into the note.
    var effectiveOpacity: CGFloat {
        if isHovered && AppSettings.shared.hoverRevealsNote { return 1 }
        let chosen = CGFloat(note.opacity)
        // Floored like the opacity setting itself (SPEC.md §3.3): dimming a note already set to 30%
        // must not take it past the point where it can be found again.
        return note.isTodo && note.isDone ? max(0.25, chosen * NotePanel.doneDimming) : chosen
    }

    /// Whether the pointer is over the card. Set by NoteCardView's tracking area.
    var isHovered = false

    /// The one place a note's window opacity is set, so the user's choice, the done-dimming and
    /// hover-to-reveal can never disagree about what it should be.
    func applyOpacity(animated: Bool = false) {
        let target = effectiveOpacity
        // Quick to show, slower to fade. Not animated, it still goes through Motion so that a fade
        // already running cannot carry on afterwards and overwrite the value set here.
        Motion.fade(self, to: target, duration: animated ? (target > alphaValue ? 0.16 : 0.32) : 0)
    }

    /// Freeze mode. The note stops taking the mouse entirely; FreezeMode re-enables it while the
    /// pointer is over the snowflake corner, which is the only way back out.
    func applyFrozen() {
        ignoresMouseEvents = note.frozen
        card?.updateFrozenState()
        FreezeMode.update()
    }

    /// In a stack, the STACK is pinned or not; the note's own pin waits until it is unstacked.
    var isOnTop: Bool { StackManager.shared.stack(containing: note.id)?.pinned ?? note.pinned }

    func applyPinned() {
        level = isOnTop ? .floating : .normal
        card?.applyColors()             // refreshes the header pin glyph and the redraw
        card?.updateLayoutForPin()
    }

    /// Brief attention bounce, used when the All Notes window points at a note. SPEC.md §8.
    /// A layer spring rather than two chained frame animations: the window's frame is the note's
    /// persisted geometry, and an interrupted frame animation could leave it a few points out.
    func pulse() { Motion.bounce(card) }
}
