import AppKit

// MARK: - Panel

/// One floating note window.
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

    let note: Note

    init(note: Note) {
        self.note = note
        let windowRect = NotePanel.windowRect(forCard: note.cardFrame)

        super.init(contentRect: windowRect,
                   styleMask: [.borderless, .resizable, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = note.pinned ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false   // we drag from the header ourselves
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false                     // drawn manually, see above
        alphaValue = note.opacity
        isReleasedWhenClosed = false

        contentView = NoteCardView(note: note, panel: self)
    }

    /// Borderless non-activating panels cannot take text input without this.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: Geometry

    static func windowRect(forCard card: NSRect) -> NSRect {
        card.insetBy(dx: -margin, dy: -margin)
    }

    static func cardRect(forWindow window: NSRect) -> NSRect {
        window.insetBy(dx: margin, dy: margin)
    }

    /// Persist the CARD rect, never the window rect.
    func syncFrameToNote() {
        note.cardFrame = NotePanel.cardRect(forWindow: frame)
    }

    func applyPinned() {
        level = note.pinned ? .floating : .normal
        contentView?.needsDisplay = true
    }
}

// MARK: - Card view

final class NoteCardView: NSView {

    private let note: Note
    private unowned let panel: NotePanel

    private let headerHeight: CGFloat = 30
    private let cornerRadius: CGFloat = 12
    private let pinSize: CGFloat = 28

    private var titleLabel: NSTextField!
    private var pinButton: NSButton!
    private var closeButton: NSButton!
    private var textView: NSTextView!
    private var scrollView: NSScrollView!

    private var dragOrigin: NSPoint?

    init(note: Note, panel: NotePanel) {
        self.note = note
        self.panel = panel
        super.init(frame: .zero)
        wantsLayer = true
        buildSubviews()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Geometry

    /// The visible card, inset from the window by the transparent margin.
    private var cardRect: NSRect {
        bounds.insetBy(dx: NotePanel.margin, dy: NotePanel.margin)
    }

    /// The pushpin overhangs the card's top-left corner, into the margin.
    private var pinRect: NSRect {
        NSRect(x: cardRect.minX - pinSize * 0.30,
               y: cardRect.maxY - pinSize * 0.62,
               width: pinSize,
               height: pinSize)
    }

    private var headerRect: NSRect {
        NSRect(x: cardRect.minX, y: cardRect.maxY - headerHeight,
               width: cardRect.width, height: headerHeight)
    }

    // MARK: Hit testing

    /// Without this the transparent margin still receives clicks, so every note
    /// carries an invisible halo that eats clicks meant for the desktop or the
    /// app underneath. SPEC.md §5.2.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let parent = superview else { return super.hitTest(point) }
        let local = convert(point, from: parent)
        let card = NSBezierPath(roundedRect: cardRect,
                                xRadius: cornerRadius, yRadius: cornerRadius)
        if card.contains(local) { return super.hitTest(point) }
        if note.pinned && pinRect.contains(local) { return self }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let card = NSBezierPath(roundedRect: cardRect,
                                xRadius: cornerRadius, yRadius: cornerRadius)

        // Pinned glow: outer shadow in the accent color. SPEC.md §5.4.
        if note.pinned {
            ctx.saveGState()
            let glow = Settings.shared.outlineColor.withAlphaComponent(0.22)
            ctx.setShadow(offset: .zero, blur: 10, color: glow.cgColor)
            note.color.setFill()
            card.fill()
            ctx.restoreGState()
        }

        // Card shadow, drawn manually because hasShadow is false.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 12,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        note.color.setFill()
        card.fill()
        ctx.restoreGState()

        // Universal outline. Width and color are global settings. SPEC.md §9.
        if Settings.shared.outlineEnabled {
            Settings.shared.outlineColor.setStroke()
            card.lineWidth = Settings.shared.outlineWidth
            card.stroke()
        }

        // Header hairline.
        NSColor.black.withAlphaComponent(0.08).setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: cardRect.minX + 1, y: headerRect.minY))
        sep.line(to: NSPoint(x: cardRect.maxX - 1, y: headerRect.minY))
        sep.lineWidth = 1
        sep.stroke()

        if note.pinned { drawPin() }
    }

    /// Ships as a rendered PNG asset (SPEC.md §5.4). Until that asset exists,
    /// this is a vector stand-in so Phase 1 runs without it.
    private func drawPin() {
        if let image = NSImage(named: "pushpin") {
            image.draw(in: pinRect)
            return
        }
        let r = pinRect
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: NSRect(x: r.minX + 5, y: r.minY + 2,
                                    width: r.width * 0.55, height: r.height * 0.28)).fill()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: r.minX + r.width * 0.18, y: r.minY + r.height * 0.34,
                                    width: r.width * 0.64, height: r.height * 0.64)).fill()
        NSColor.systemRed.blended(withFraction: 0.35, of: .black)?.setStroke()
        let shaft = NSBezierPath()
        shaft.move(to: NSPoint(x: r.midX, y: r.minY + r.height * 0.42))
        shaft.line(to: NSPoint(x: r.midX + r.width * 0.16, y: r.minY + r.height * 0.04))
        shaft.lineWidth = 2.5
        shaft.stroke()
    }

    // MARK: Subviews

    private func buildSubviews() {
        titleLabel = NSTextField(labelWithString: note.title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        pinButton = NSButton(title: "", target: self, action: #selector(togglePin))
        pinButton.isBordered = false
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")
        addSubview(pinButton)

        closeButton = NSButton(title: "", target: self, action: #selector(closeNote))
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        addSubview(closeButton)

        // Phase 1 placeholder editor. Replaced by CodeMirror in a WKWebView
        // in Phase 2. SPEC.md §4.
        scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        textView = NSTextView()
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.string = note.body
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scrollView.documentView = textView
        addSubview(scrollView)

        applyTextColor()
    }

    private func applyTextColor() {
        let fg: NSColor = note.isDarkText ? .black : .white
        titleLabel.textColor = fg.withAlphaComponent(0.85)
        textView.textColor = fg.withAlphaComponent(0.92)
        textView.insertionPointColor = fg
        pinButton.contentTintColor = note.pinned ? Settings.shared.outlineColor : fg.withAlphaComponent(0.45)
        closeButton.contentTintColor = fg.withAlphaComponent(0.45)
    }

    override func layout() {
        super.layout()
        // Title is inset to clear the overhanging pin. SPEC.md §5.2.
        let leftInset: CGFloat = 34
        titleLabel.frame = NSRect(x: headerRect.minX + leftInset,
                                  y: headerRect.minY + 7,
                                  width: headerRect.width - leftInset - 52,
                                  height: 16)
        closeButton.frame = NSRect(x: headerRect.maxX - 24, y: headerRect.minY + 6, width: 18, height: 18)
        pinButton.frame   = NSRect(x: headerRect.maxX - 46, y: headerRect.minY + 6, width: 18, height: 18)
        scrollView.frame  = NSRect(x: cardRect.minX + 6,
                                   y: cardRect.minY + 6,
                                   width: cardRect.width - 12,
                                   height: cardRect.height - headerHeight - 12)
    }

    // MARK: Actions

    @objc private func togglePin() {
        note.pinned.toggle()
        panel.applyPinned()
        applyTextColor()
        VaultStore.shared.save(note)
        needsDisplay = true
    }

    @objc private func closeNote() {
        note.visible = false
        VaultStore.shared.save(note)
        WindowManager.shared.close(noteID: note.id)
    }

    // MARK: Dragging

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard headerRect.contains(local) || (note.pinned && pinRect.contains(local)) else {
            super.mouseDown(with: event)
            return
        }
        if note.pinned && pinRect.contains(local) { togglePin(); return }
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let window = self.window else {
            super.mouseDragged(with: event)
            return
        }
        let current = NSEvent.mouseLocation
        var frame = window.frame
        frame.origin = NSPoint(x: current.x - origin.x, y: current.y - origin.y)
        window.setFrameOrigin(frame.origin)
    }

    override func mouseUp(with event: NSEvent) {
        if dragOrigin != nil {
            dragOrigin = nil
            panel.syncFrameToNote()
            VaultStore.shared.save(note)
        }
        super.mouseUp(with: event)
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        guard headerRect.contains(local) else { return nil }

        let menu = NSMenu()
        menu.addItem(withTitle: note.pinned ? "Unpin" : "Pin on Top",
                     action: #selector(togglePin), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Note",
                     action: #selector(closeNote), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Delete Note",
                     action: #selector(deleteNote), keyEquivalent: "").target = self
        return menu
    }

    @objc private func deleteNote() {
        WindowManager.shared.close(noteID: note.id)
        VaultStore.shared.delete(note)
    }
}

// MARK: - Editing

extension NoteCardView: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        note.body = textView.string
        titleLabel.stringValue = note.title
        SaveCoordinator.shared.scheduleSave(note)
    }
}

/// Debounced save: 800ms after the last keystroke. SPEC.md §4.5.
final class SaveCoordinator {
    static let shared = SaveCoordinator()
    private var timers: [String: Timer] = [:]

    func scheduleSave(_ note: Note) {
        timers[note.id]?.invalidate()
        timers[note.id] = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
            VaultStore.shared.save(note)
        }
    }

    func flushAll() {
        for (_, t) in timers { t.fire(); t.invalidate() }
        timers.removeAll()
    }
}
