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
    static let footerHeight: CGFloat = 30
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
        level = note.pinned ? .floating : .normal
        // .canJoinAllSpaces makes every note follow you across Spaces. SPEC.md §5.1.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false   // dragging is handled from the header
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false                     // drawn manually, see above
        alphaValue = note.opacity
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
    /// The stored `cardFrame` is always the expanded rect; collapsing keeps the top edge fixed.
    private var visibleCardRect: NSRect {
        let full = note.cardFrame
        guard note.collapsed else { return full }
        return NSRect(x: full.minX, y: full.maxY - NotePanel.headerHeight,
                      width: full.width, height: NotePanel.headerHeight)
    }

    /// Persist the CARD rect, never the window rect. SPEC.md §5.2.
    func syncFrameToNote() {
        let visible = NotePanel.cardRect(forWindow: frame)
        if note.collapsed {
            note.cardFrame = NSRect(x: visible.minX, y: visible.maxY - note.cardFrame.height,
                                    width: visible.width, height: note.cardFrame.height)
        } else {
            note.cardFrame = visible
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

    func applyCardFrame(_ rect: NSRect, animated: Bool = false) {
        note.cardFrame = rect
        setFrame(NotePanel.windowRect(forCard: visibleCardRect), display: true, animate: animated)
    }

    /// Freeze mode. The note stops taking the mouse entirely; FreezeMode re-enables it while the
    /// pointer is over the snowflake corner, which is the only way back out.
    func applyFrozen() {
        ignoresMouseEvents = note.frozen
        card?.updateFrozenState()
        FreezeMode.update()
    }

    func applyPinned() {
        level = note.pinned ? .floating : .normal
        card?.applyColors()             // refreshes the header pin glyph and the redraw
        card?.updateLayoutForPin()
    }

    /// Brief attention bounce, used when the All Notes window points at a note. SPEC.md §8.
    /// A layer spring rather than two chained frame animations: the window's frame is the note's
    /// persisted geometry, and an interrupted frame animation could leave it a few points out.
    func pulse() { Motion.bounce(card) }
}
