import AppKit
import SwiftUI

/// The note's visible card: chrome, header controls, editor, footer. SPEC.md §5.3.
///
/// The view is the full WINDOW size; the card is inset by `NotePanel.margin`
/// inside it. Everything below positions itself against `cardRect`, never `bounds`.
/// The note's controls, sized in one place. Bigger since 2026-09-21 — the owner could barely make
/// out the snowflake — but not so big that a narrow note runs out of room for its title.
enum ChromeSize {
    static let glyph: CGFloat = 13.5                        // SF Symbol point size
    static let headerButton: CGFloat = 24
    static let barButton = NSSize(width: 26, height: 24)    // palette, tag, bell, tools, snowflake
    static let chevron = NSSize(width: 20, height: 24)
    static let grip: CGFloat = 18
    /// From the bar's top edge down to the bottom of its row of controls.
    static let barRowDrop: CGFloat = 28
}

final class NoteCardView: NSView, NSTextFieldDelegate {

    private let note: Note
    private unowned let panel: NotePanel

    private let titleField = TitleField()
    private let pinButton = ToolButton()
    private let modeButton = ToolButton()
    private let collapseButton = ToolButton()
    private let closeButton = ToolButton()
    private let clipButton = ToolButton()          // paperclip: makes a stack (SPEC.md §5.10)
    // The stack bar, under the title bar of every note in a stack. Only the front note's shows.
    private let stackIcon = NSImageView()
    private let stackNameField = TitleField()
    /// The orange pill behind the stack's name (owner, 2026-09-22), as wide as the name needs.
    private let stackPill = NSView()
    private let unstackButton = ToolButton()
    private let stackPinButton = ToolButton()
    private let stackCollapseButton = ToolButton()
    private let stackCloseButton = ToolButton()
    private let appearanceButton = ToolButton()
    private let tagsButton = ToolButton()          // the tag ICON: the only thing that opens the tag editor
    private let bellButton = ToolButton()          // reminders; todo notes only
    private let taskProgress = TaskProgressView()  // 3/7 squares; todo notes only
    private let collapsedProgress = TaskProgressLineView()   // the same, as a bar, in a collapsed title bar
    private let tagPills = TagPillsView()                      // shows the tags; ignores the mouse so it drags
    private let grip = ResizeGripView()
    private let freezeButton = ToolButton()      // snowflake, beside the grip
    let editor: NoteEditorView

    // The action bar: a `>` in the footer that opens formatting tools. SPEC.md §5.3 keeps the
    // always-visible footer to three controls; everything else lives behind this one.
    private let expandButton = ToolButton()
    private let bulletButton = ToolButton()
    private let boldButton = ToolButton()
    private let italicButton = ToolButton()
    private let codeButton = ToolButton()
    private let opacitySlider = NSSlider()
    private var actionBarExpanded = false
    private var collapseTimer: Timer?
    /// How many times toggleCollapse has run. Only the self-test reads it, to prove one key
    /// press collapses a note once rather than collapsing and immediately expanding it again.
    static var collapseRunCount = 0
    private var footerTracking: NSTrackingArea?
    private var cardTracking: NSTrackingArea?

    private var popover: NSPopover?
    private var dragOrigin: NSPoint?

    // Vim mode (SPEC.md §4.6). The mode label sits in the action bar; the ":" / "/" prompt turns the
    // whole action bar into a command bar (owner, 2026-09-21), and vim's messages borrow it briefly.
    private let vimModeLabel = NSTextField(labelWithString: "")
    private let commandPrefix = NSTextField(labelWithString: ":")
    private let commandField = NSTextField()
    private let vimMessageLabel = NSTextField(labelWithString: "")
    private var vimMode: String?                      // nil while vim mode is off
    private enum BarOverlay { case none, command, message }
    private var barOverlay = BarOverlay.none
    private var messageTimer: Timer?
    /// Width the mode label takes out of the action bar. Fixed, so the bar does not shuffle
    /// sideways as NORMAL becomes INSERT becomes V-BLOCK.
    private static let vimLabelWidth: CGFloat = 60

    /// How much taller than `NotePanel.footerHeight` the action bar currently is, because the task
    /// tracker has wrapped onto more than one row (owner decision, 2026-09-20). The bar grows
    /// DOWNWARD — see `NotePanel.visibleCardRect` — so a checklist never shrinks the text area.
    private(set) var extraFooterHeight: CGFloat = 0
    /// Squares the tracker fits on one row at this note's width. Six at most.
    private var progressPerRow = TaskProgressStyle.perRow
    /// Whether there is room for the "3/7" count beside them.
    private var progressShowsLabel = true
    /// What the right-hand side of the action bar depends on. Rebuilding it on every keystroke
    /// would cut its fade animations short, so it is only rebuilt when one of these changes.
    private var todoSignature = ""

    private let pinSize: CGFloat = 28

    /// The stack this note is in, if any. SPEC.md §5.10.
    private var stack: NoteStack? { StackManager.shared.stack(containing: note.id) }
    static let stackBarHeight: CGFloat = 26
    var stackBarHeight: CGFloat { stack == nil ? 0 : NoteCardView.stackBarHeight }
    /// The note's own pushpin and glow. In a stack the STACK is pinned, from its bar, and a pin on
    /// every title bar of the pile would be clutter.
    private var showsOwnPin: Bool { note.pinned && stack == nil }

    init(note: Note, panel: NotePanel) {
        self.note = note
        self.panel = panel
        self.editor = NoteEditorView(note: note)
        super.init(frame: .zero)
        wantsLayer = true
        buildSubviews()
        // Before the panel first sizes itself: the stored card frame is the BASE card, and the
        // extra tracker rows are re-derived here, so the note comes back the height it was left.
        recomputeFooterGrid(cardWidth: note.cardFrame.width)
        todoSignature = currentTodoSignature

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(bodyChanged(_:)), name: .noteBodyDidChange, object: note)
        nc.addObserver(self, selector: #selector(settingsChanged), name: .settingsDidChange, object: nil)
        nc.addObserver(self, selector: #selector(tagsMayHaveChanged), name: .vaultDidChange, object: nil)
        nc.addObserver(self, selector: #selector(stacksChanged), name: .stacksDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Geometry

    /// The visible card, inset from the window by the transparent margin.
    private var cardRect: NSRect {
        bounds.insetBy(dx: NotePanel.margin, dy: NotePanel.margin)
    }

    private var headerRect: NSRect {
        NSRect(x: cardRect.minX, y: cardRect.maxY - NotePanel.headerHeight,
               width: cardRect.width, height: NotePanel.headerHeight)
    }

    /// The snowflake, in window coordinates. FreezeMode keeps THIS spot live on a frozen note, so
    /// it is needed in every build — not one of the debug-only accessors at the end of the file.
    var freezeButtonRectInWindow: NSRect { convert(freezeButton.frame, to: nil) }

    /// The action bar's current thickness: the base height plus a row per extra tracker row.
    var footerHeight: CGFloat { NotePanel.footerHeight + extraFooterHeight }

    /// Room the tracker has between the bell and the freeze button, and how much of it to keep
    /// clear for the tags — enough for a "+N" pill, so tasks can never crowd them off the bar.
    private func progressRoom(cardWidth: CGFloat) -> (width: CGFloat, keptForTags: CGFloat) {
        let bar = ChromeSize.barButton.width
        let left: CGFloat = 6 + bar + 2 + ChromeSize.chevron.width + 4 + bar + (note.isTodo ? 1 + bar : 0) + 2
        let right: CGFloat = (ChromeSize.grip + 4) + bar + 6 + (vimMode != nil ? NoteCardView.vimLabelWidth + 4 : 0)
        return (max(TaskProgressStyle.square, cardWidth - left - right), note.tags.isEmpty ? 0 : 34)
    }

    /// Re-derives how the tracker wraps at `cardWidth`. True when the action bar's height changed.
    @discardableResult
    private func recomputeFooterGrid(cardWidth: CGFloat) -> Bool {
        let total = note.isTodo ? note.taskCounts.total : 0
        let room = progressRoom(cardWidth: cardWidth)
        let grid = TaskProgressView.grid(total: total, room: room.width, reservedForTags: room.keptForTags)
        progressPerRow = max(1, grid.perRow)
        progressShowsLabel = grid.showsLabel
        let extra = CGFloat(max(0, grid.rows - 1)) * NotePanel.footerRowHeight
        guard abs(extra - extraFooterHeight) > 0.5 else { return false }
        extraFooterHeight = extra
        return true
    }

    /// Grows or shrinks the action bar to match the number of tasks. Cheap when nothing changed,
    /// so callers may fire it on every edit.
    func syncFooterHeight(animated: Bool = true) {
        let width = bounds.width > 0 ? cardRect.width : note.cardFrame.width
        guard recomputeFooterGrid(cardWidth: width) else { return }
        panel.applyFooterHeight(animated: animated)
        needsLayout = true
        needsDisplay = true
    }

    private var currentTodoSignature: String {
        let counts = note.taskCounts
        return "\(note.isTodo)/\(counts.done)/\(counts.total)"
    }

    /// Called whenever the note's text or tags changed: keeps the tracker and the bar's height in
    /// step with the checklist WITHOUT closing and reopening the note, which is what used to be
    /// needed before the tracker would appear at all.
    private func syncTodoState() {
        guard todoSignature != currentTodoSignature else { return }
        todoSignature = currentTodoSignature
        updateActionBar()
        syncFooterHeight()
        refreshTitle()
        panel.applyOpacity()
    }

    /// The pushpin art (assets: Pushpin). Its needle enters a crack in the paper, and that crack
    /// is anchored on the card's top-left corner while the head overhangs into the transparent
    /// margin. SPEC.md §5.4. The crack sits 74% across and 87% down the trimmed image.
    /// 40% smaller than it first was (owner, 2026-09-22): the height AND the crack's distance from
    /// the corner both scale by 0.6, so the pin sits exactly as before, only smaller. Its head's top
    /// is 0.87 × 27.6 − 10.2 ≈ 14pt above the card, well inside the 24pt margin.
    static let pinScale: CGFloat = 0.6
    private var pinImageRect: NSRect {
        let h: CGFloat = 46 * NoteCardView.pinScale
        let aspect: CGFloat = 188.0 / 285.0
        let w = h * aspect
        let crack = CGPoint(x: cardRect.minX + 24 * NoteCardView.pinScale, y: cardRect.maxY - 17 * NoteCardView.pinScale)
        return NSRect(x: crack.x - 0.74 * w, y: crack.y - 0.13 * h, width: w, height: h)
    }

    /// Where a click unpins.
    private var pinRect: NSRect { pinImageRect.insetBy(dx: -2, dy: -2) }

    private var cornerRadius: CGFloat { AppSettings.shared.cornerRadius }

    /// Notes are non-activating panels, so a click on one is usually the FIRST click on a window
    /// that is not key. Without this AppKit spends that click on activating the window and never
    /// delivers it, and dragging a note from its header silently does nothing until the second try.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Hit testing

    /// Without this the transparent margin still receives clicks, so every note
    /// carries an invisible halo that eats clicks meant for the desktop or the
    /// app underneath. The pin's own bounds are carved back in. SPEC.md §5.2.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let parent = superview else { return super.hitTest(point) }
        let local = convert(point, from: parent)
        let path = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)
        if path.contains(local) { return super.hitTest(point) }
        if showsOwnPin && pinRect.contains(local) { return self }
        return nil
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let settings = AppSettings.shared
        let rect = cardRect
        let card = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Pinned glow, in the NOTE's own color (owner's call; SPEC.md §5.4 said outline color at 22%,
        // which was too faint to see). Two passes, a wide soft halo and a tight bright one, both
        // inside the 24pt margin so the window never clips them.
        let glowing = showsOwnPin && settings.pinnedGlow
        if glowing {
            // Settings → Notes → Glow strength. Mostly brightness; the halo also widens a little, but
            // never past the 24pt margin, or the window edge would slice it off flat (SPEC.md §5.2).
            let strength = settings.pinnedGlowStrength
            for (blur, alpha) in [(22.0, 0.62), (9.0, 0.85)] {
                let spread = min(Double(NotePanel.margin), blur * (0.75 + 0.25 * strength))
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: CGFloat(spread),
                              color: note.color.withAlphaComponent(CGFloat(min(1, alpha * strength))).cgColor)
                note.color.setFill()
                card.fill()
                ctx.restoreGState()
            }
        }

        // Card shadow, drawn by hand because hasShadow is false. SPEC.md §5.2. Lighter while glowing,
        // or the black shadow muddies the halo.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 12,
                      color: NSColor.black.withAlphaComponent(glowing ? 0.16 : 0.34).cgColor)
        note.color.setFill()
        card.fill()
        ctx.restoreGState()

        // Universal outline. Width and color are global settings. SPEC.md §9.
        if settings.outlineEnabled {
            settings.outlineColor.setStroke()
            card.lineWidth = settings.outlineWidth
            card.stroke()
        }

        // Hairlines under the header and above the footer.
        let hairline = (note.isDarkText ? NSColor.black : NSColor.white).withAlphaComponent(note.isDarkText ? 0.09 : 0.16)
        hairline.setStroke()
        let sep = NSBezierPath()
        sep.lineWidth = 1
        sep.move(to: NSPoint(x: rect.minX + 1, y: headerRect.minY + 0.5))
        sep.line(to: NSPoint(x: rect.maxX - 1, y: headerRect.minY + 0.5))
        if !note.collapsed {
            sep.move(to: NSPoint(x: rect.minX + 1, y: rect.minY + footerHeight - 0.5))
            sep.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + footerHeight - 0.5))
        }
        sep.stroke()

        // The stack bar: a faint band under the title bar, with its own hairline below it.
        if stack != nil {
            let band = NSRect(x: rect.minX + 1, y: headerRect.minY - NoteCardView.stackBarHeight,
                              width: rect.width - 2, height: NoteCardView.stackBarHeight)
            (note.isDarkText ? NSColor.black : NSColor.white).withAlphaComponent(note.isDarkText ? 0.06 : 0.09).setFill()
            band.fill()
            hairline.setStroke()
            let under = NSBezierPath()
            under.lineWidth = 1
            under.move(to: NSPoint(x: rect.minX + 1, y: band.minY + 0.5))
            under.line(to: NSPoint(x: rect.maxX - 1, y: band.minY + 0.5))
            under.stroke()
        }

        if showsOwnPin {
            if let art = NSImage(named: "Pushpin") { art.draw(in: pinImageRect) } else { drawPin(in: ctx) }
        }
    }

    /// Fallback vector pushpin, used only if the Pushpin asset is missing.
    private func drawPin(in ctx: CGContext) {
        let tip = CGPoint(x: cardRect.minX + 21, y: cardRect.maxY - 12)
        ctx.saveGState()
        ctx.translateBy(x: tip.x, y: tip.y)
        ctx.rotate(by: .pi / 4)          // needle axis +y now points up-left

        // Contact shadow on the paper.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.fillEllipse(in: CGRect(x: -1, y: -3.5, width: 10, height: 5))

        // Needle.
        ctx.setStrokeColor(NSColor(white: 0.55, alpha: 1).cgColor)
        ctx.setLineWidth(1.8)
        ctx.setLineCap(.round)
        ctx.move(to: .zero)
        ctx.addLine(to: CGPoint(x: 0, y: 12))
        ctx.strokePath()

        // Collar, stem, head.
        ctx.setFillColor(NSColor(srgbRed: 0.68, green: 0.09, blue: 0.10, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: -6, y: 9, width: 12, height: 5))            // collar
        ctx.fill(CGRect(x: -2.6, y: 12, width: 5.2, height: 8))                   // stem
        let head = CGRect(x: -8.5, y: 18, width: 17, height: 11)
        let colors = [NSColor(srgbRed: 1.0, green: 0.36, blue: 0.34, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.72, green: 0.10, blue: 0.12, alpha: 1).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.saveGState()
            ctx.addEllipse(in: head)
            ctx.clip()
            ctx.drawLinearGradient(gradient, start: CGPoint(x: head.minX, y: head.maxY),
                                   end: CGPoint(x: head.maxX, y: head.minY), options: [])
            ctx.restoreGState()
        }
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)          // specular
        ctx.fillEllipse(in: CGRect(x: -5.5, y: 23.5, width: 6, height: 3.2))
        ctx.restoreGState()
    }

    // MARK: - Subviews

    private func buildSubviews() {
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.usesSingleLineMode = true
        titleField.cell?.isScrollable = true
        titleField.delegate = self
        addSubview(titleField)
        addSubview(collapsedProgress)

        configure(pinButton, symbol: "pin", tip: "Pin on top", action: #selector(togglePin))
        configure(modeButton, symbol: "book", tip: "Switch between Live Preview and Source", action: #selector(toggleMode))
        configure(collapseButton, symbol: "chevron.down", tip: "Collapse", action: #selector(toggleCollapse))
        configure(closeButton, symbol: "xmark", tip: "Close (keeps the note in All Notes)", action: #selector(closeNote))
        configure(appearanceButton, symbol: "paintpalette", tip: "Color, mode and opacity", action: #selector(showAppearance))
        configure(clipButton, symbol: "paperclip", tip: "Stack this note with others", action: #selector(showStackCreator))
        [pinButton, modeButton, collapseButton, closeButton, appearanceButton, clipButton].forEach { addSubview($0) }
        buildStackBar()

        // Action bar
        configure(expandButton, symbol: "chevron.right", tip: "Formatting tools", action: #selector(toggleActionBar))
        configure(bulletButton, symbol: "list.bullet", tip: "Bulleted list. Right-click to choose an emoji bullet", action: #selector(applyBullet))
        bulletButton.onRightClick = { [weak self] in self?.editor.pickBullet() }
        configure(boldButton, symbol: "bold", tip: "Bold", action: #selector(applyBold))
        configure(italicButton, symbol: "italic", tip: "Italic", action: #selector(applyItalic))
        configure(codeButton, symbol: "chevron.left.forwardslash.chevron.right", tip: "Code", action: #selector(applyCode))
        [expandButton, bulletButton, boldButton, italicButton, codeButton].forEach { addSubview($0) }

        opacitySlider.minValue = 0.3               // an invisible note would be unrecoverable. SPEC.md §3.3
        opacitySlider.maxValue = 1.0
        opacitySlider.doubleValue = note.opacity
        opacitySlider.controlSize = .mini
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.toolTip = "Opacity"
        addSubview(opacitySlider)

        configure(tagsButton, symbol: "tag", tip: "Edit tags", action: #selector(showTags))
        addSubview(tagsButton)
        configure(bellButton, symbol: "bell", tip: "Due date and reminders", action: #selector(showReminders))
        addSubview(bellButton)
        addSubview(taskProgress)
        tagPills.onOverflowClick = { [weak self] _ in self?.showAllTags() }
        addSubview(tagPills)

        configure(freezeButton, symbol: "snowflake", tip: "Freeze (click-through)", action: #selector(toggleFreeze))
        addSubview(freezeButton)
        grip.onDrag = { [weak self] in self?.resizeBegan() }
        grip.panel = panel
        addSubview(grip)

        buildVimControls()

        editor.onModeChange = { [weak self] _ in self?.refreshModeGlyph() }
        editor.contextMenuItems = { [weak self] in self?.contextMenuItems(editing: true) ?? [] }
        addSubview(editor)

        applyColors()
        refreshTagsButton()
        refreshModeGlyph()
        updateCollapsedState()
        updateFrozenState()
        updateReminderGlyph()
        refreshStackState()
    }

    private func configure(_ b: NSButton, symbol: String, tip: String, action: Selector) {
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: ChromeSize.glyph, weight: .semibold))
        b.toolTip = tip
        b.target = self
        b.action = action
    }

    private var foreground: NSColor { note.isDarkText ? .black : .white }

    func applyColors() {
        titleField.textColor = foreground.withAlphaComponent(0.86)
        refreshVimControls()
        refreshTitle()
        let icon = foreground.withAlphaComponent(0.5)
        [modeButton, collapseButton, closeButton, appearanceButton, expandButton,
         boldButton, italicButton, codeButton, clipButton, unstackButton, stackCollapseButton, stackCloseButton]
            .forEach { $0.contentTintColor = icon }
        stackIcon.contentTintColor = icon
        // On the orange pill, always near-black lettering, like every orange selection in the app.
        stackNameField.textColor = .black
        refreshStackPinGlyph()
        refreshPinGlyph()
        refreshBulletButton()
        refreshTagsButton()
        opacitySlider.doubleValue = note.opacity
        needsDisplay = true
    }

    private func symbol(_ name: String, weight: NSFont.Weight = .semibold) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: ChromeSize.glyph, weight: weight))
    }

    // MARK: - Stacks (SPEC.md §5.10)

    private func buildStackBar() {
        stackIcon.image = symbol("square.stack.3d.up.fill")
        stackIcon.imageScaling = .scaleProportionallyDown
        addSubview(stackIcon)
        stackPill.wantsLayer = true
        stackPill.layer?.backgroundColor = Brand.accentNS.cgColor
        stackPill.layer?.cornerRadius = 8
        addSubview(stackPill)
        stackNameField.isEditable = false
        stackNameField.isSelectable = false
        stackNameField.isBordered = false
        stackNameField.drawsBackground = false
        stackNameField.focusRingType = .none
        stackNameField.font = .systemFont(ofSize: 11.5, weight: .semibold)
        stackNameField.lineBreakMode = .byTruncatingTail
        stackNameField.usesSingleLineMode = true
        stackNameField.cell?.isScrollable = true
        stackNameField.delegate = self
        addSubview(stackNameField)
        configure(unstackButton, symbol: "paperclip", tip: "Unstack: every note goes back where it was", action: #selector(unstackTapped))
        unstackButton.image = NoteCardView.struckPaperclip()
        configure(stackPinButton, symbol: "pin", tip: "Keep the stack on top", action: #selector(stackPinTapped))
        configure(stackCollapseButton, symbol: "chevron.down", tip: "Collapse the stack", action: #selector(stackCollapseTapped))
        configure(stackCloseButton, symbol: "xmark", tip: "Close the stack (it stays in All Notes)", action: #selector(stackCloseTapped))
        [unstackButton, stackPinButton, stackCollapseButton, stackCloseButton].forEach { addSubview($0) }
    }

    /// SF Symbols has no paperclip with a slash, so it is drawn: the paperclip with a stroke across.
    /// A template image, so it takes the bar's tint like every other glyph.
    static func struckPaperclip() -> NSImage? {
        guard let clip = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Unstack")?
            .withSymbolConfiguration(.init(pointSize: ChromeSize.glyph, weight: .semibold)) else { return nil }
        let size = clip.size
        let image = NSImage(size: size, flipped: false) { rect in
            clip.draw(in: rect)
            // Clear a channel either side of the stroke so it reads as crossed out, not scribbled on.
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX + 1, y: rect.minY + 1))
            path.line(to: NSPoint(x: rect.maxX - 1, y: rect.maxY - 1))
            path.lineCapStyle = .round
            NSGraphicsContext.current?.compositingOperation = .clear
            path.lineWidth = 4.2
            path.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setStroke()
            path.lineWidth = 1.7
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Unstack"
        return image
    }

    private func layoutStackBar(in c: NSRect, headerY: CGFloat, button btn: CGFloat) {
        guard stack != nil else { return }
        let barY = headerY - NoteCardView.stackBarHeight
        let y = barY + (NoteCardView.stackBarHeight - btn) / 2
        stackCloseButton.frame = NSRect(x: c.maxX - 6 - btn, y: y, width: btn, height: btn)
        stackCollapseButton.frame = NSRect(x: stackCloseButton.frame.minX - btn, y: y, width: btn, height: btn)
        stackPinButton.frame = NSRect(x: stackCollapseButton.frame.minX - btn, y: y, width: btn, height: btn)
        unstackButton.frame = NSRect(x: stackPinButton.frame.minX - btn, y: y, width: btn, height: btn)
        stackIcon.frame = NSRect(x: c.minX + 11, y: barY + (NoteCardView.stackBarHeight - 15) / 2, width: 15, height: 15)
        let pillX = stackIcon.frame.maxX + 6
        let room = max(28, unstackButton.frame.minX - 6 - pillX)
        let textWidth = ceil((stackNameField.stringValue as NSString)
            .size(withAttributes: [.font: stackNameField.font ?? .systemFont(ofSize: 11.5, weight: .semibold)]).width) + 6
        // While renaming, the pill takes all the room there is, so the typing never runs off its end.
        let pillWidth = stackNameField.isRenaming ? room : min(room, textWidth + 16)
        stackPill.frame = NSRect(x: pillX, y: barY + (NoteCardView.stackBarHeight - 18) / 2, width: pillWidth, height: 18)
        stackNameField.frame = NSRect(x: pillX + 8, y: barY + (NoteCardView.stackBarHeight - 16) / 2,
                                      width: max(12, pillWidth - 16), height: 16)
    }

    private var stackBarRect: NSRect {
        NSRect(x: cardRect.minX, y: headerRect.minY - stackBarHeight, width: cardRect.width, height: stackBarHeight)
    }

    private func refreshStackPinGlyph() {
        let pinned = stack?.pinned == true
        stackPinButton.image = symbol(pinned ? "pin.fill" : "pin")
        stackPinButton.contentTintColor = pinned ? AppSettings.shared.outlineColor : foreground.withAlphaComponent(0.5)
        stackPinButton.toolTip = pinned ? "Unpin the stack" : "Keep the stack on top"
    }

    /// Joined, left, renumbered, renamed, brought forward: everything a stack changes on this card.
    func refreshStackState() {
        let s = stack
        let inStack = s != nil
        let front = s?.front == note.id
        for v in [stackIcon, stackPill, stackNameField, unstackButton, stackPinButton, stackCollapseButton, stackCloseButton] as [NSView] {
            v.isHidden = !inStack
        }
        clipButton.isHidden = inStack
        pinButton.isHidden = inStack
        collapseButton.isHidden = inStack
        closeButton.isHidden = inStack
        modeButton.isHidden = note.collapsed || (inStack && !front)
        if let s {
            if !stackNameField.isRenaming { stackNameField.stringValue = s.name }
            stackCollapseButton.image = symbol(s.collapsed ? "chevron.right" : "chevron.down")
            stackCollapseButton.toolTip = s.collapsed ? "Expand the stack" : "Collapse the stack"
        }
        refreshStackPinGlyph()
        refreshTitle()
        panel.applyPinned()
        needsLayout = true
        needsDisplay = true
    }

    @objc private func stacksChanged() {
        // Only the notes of the stack that changed need anything, but a card cannot tell which stack
        // that was once it has LEFT one; refreshing is cheap.
        refreshStackState()
    }

    @objc private func showStackCreator() {
        let candidates = StackCreatorView.candidates(for: note.id)
        guard candidates.count >= NoteStack.minMembers else {
            Toast.show("Open another note to stack this one with")
            return
        }
        let view = StackCreatorView(current: note.id, candidates: candidates) { [weak self] name, ids in
            self?.popover?.close()
            if let s = StackManager.shared.create(name: name, noteIDs: ids) {
                Toast.show("Stacked \(s.members.count) notes as “\(s.name)”")
            }
        }
        present(view, from: clipButton)
    }

    @objc private func unstackTapped() { if let s = stack { StackManager.shared.unstack(s.id) } }
    @objc private func stackPinTapped() { if let s = stack { StackManager.shared.togglePin(s.id) } }
    @objc private func stackCollapseTapped() { if let s = stack { StackManager.shared.toggleCollapse(s.id) } }
    @objc private func stackCloseTapped() { if let s = stack { StackManager.shared.hide(s.id) } }

    /// Double-click the stack's name to rename it, as with a note's title.
    private func beginStackRename() {
        guard stack != nil, !stackNameField.isRenaming else { return }
        panel.makeKeyAndOrderFront(nil)
        stackNameField.isRenaming = true
        stackNameField.isEditable = true
        stackNameField.isSelectable = true
        window?.makeFirstResponder(stackNameField)
        stackNameField.currentEditor()?.selectAll(nil)
        needsLayout = true
    }

    private func endStackRename() {
        stackNameField.isRenaming = false
        stackNameField.isEditable = false
        stackNameField.isSelectable = false
        needsLayout = true
    }

    // MARK: - Vim mode (SPEC.md §4.6)

    private func buildVimControls() {
        vimModeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        vimModeLabel.alignment = .center
        vimModeLabel.wantsLayer = true
        vimModeLabel.layer?.cornerRadius = 8
        vimModeLabel.isHidden = true
        vimModeLabel.setAccessibilityLabel("Vim mode")
        addSubview(vimModeLabel)

        commandPrefix.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        commandField.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        commandField.isBordered = false
        commandField.drawsBackground = false
        commandField.focusRingType = .none
        commandField.usesSingleLineMode = true
        commandField.cell?.isScrollable = true
        commandField.delegate = self
        commandField.setAccessibilityLabel("Vim command")
        vimMessageLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        vimMessageLabel.lineBreakMode = .byTruncatingTail
        [commandPrefix, commandField, vimMessageLabel].forEach { $0.isHidden = true; addSubview($0) }
        refreshVimControls()
    }

    private func refreshVimControls() {
        let ink = foreground
        vimModeLabel.stringValue = vimMode ?? ""
        // INSERT is the one to notice — typing now edits text — so it takes the note's accent.
        let inserting = vimMode == "INSERT" || vimMode == "REPLACE"
        vimModeLabel.textColor = inserting ? .black.withAlphaComponent(0.85) : ink.withAlphaComponent(0.75)
        vimModeLabel.layer?.backgroundColor = (inserting ? AppSettings.shared.outlineColor.withAlphaComponent(0.85)
                                                         : ink.withAlphaComponent(0.1)).cgColor
        vimModeLabel.toolTip = vimMode.map { "Vim: \($0.lowercased()) mode. Esc for normal, : for a command." }
        commandPrefix.textColor = AppSettings.shared.outlineColor
        commandField.textColor = ink.withAlphaComponent(0.92)
        vimMessageLabel.textColor = ink.withAlphaComponent(0.8)
    }

    /// Messages from the page's vim bridge (vim-mode.js).
    func vimEvent(_ type: String, _ payload: [String: Any]) {
        switch type {
        case "vim.mode":
            let wasOn = vimMode != nil
            vimMode = payload["mode"] as? String
            if vimMode == nil && barOverlay != .none { setOverlay(.none) }
            refreshVimControls()
            updateActionBar()
            // The label takes room from the tracker, so a wrapped tracker may need another row.
            if wasOn != (vimMode != nil) { syncFooterHeight() }
            needsLayout = true
        case "vim.prompt.open":
            commandPrefix.stringValue = payload["prefix"] as? String ?? ":"
            commandField.stringValue = payload["value"] as? String ?? ""
            setOverlay(.command)
            window?.makeFirstResponder(commandField)
            moveCommandCaretToEnd()
        case "vim.prompt.value":
            commandField.stringValue = payload["value"] as? String ?? ""
            moveCommandCaretToEnd()
        case "vim.prompt.close":
            guard barOverlay == .command else { return }
            setOverlay(.none)
            window?.makeFirstResponder(editor)
        case "vim.notify":
            let text = (payload["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            messageTimer?.invalidate()
            guard !text.isEmpty else { if barOverlay == .message { setOverlay(.none) }; return }
            guard barOverlay != .command else { return }        // never over a command being typed
            vimMessageLabel.stringValue = text
            setOverlay(.message)
            if payload["sticky"] as? Bool != true {
                messageTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                    guard let self, self.barOverlay == .message else { return }
                    self.setOverlay(.none)
                }
            }
        default: break
        }
    }

    private func moveCommandCaretToEnd() {
        let end = (commandField.stringValue as NSString).length
        commandField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    private func setOverlay(_ overlay: BarOverlay) {
        barOverlay = overlay
        // Always: this is also what hides the command field again once the bar is given back.
        applyOverlayVisibility()
        if overlay == .none { updateCollapsedState() }
        needsLayout = true
    }

    /// With the command bar up, the action bar's own controls step aside; only the grip stays.
    private func applyOverlayVisibility() {
        let covering = barOverlay != .none
        let barControls: [NSView] = [appearanceButton, expandButton, bulletButton, boldButton, italicButton, codeButton,
                                     opacitySlider, tagsButton, bellButton, taskProgress, tagPills, freezeButton, vimModeLabel]
        if covering { barControls.forEach { $0.isHidden = true } }
        commandPrefix.isHidden = barOverlay != .command
        commandField.isHidden = barOverlay != .command
        vimMessageLabel.isHidden = barOverlay != .message
    }

    /// Keys in the command bar that the engine's prompt handlers need to see.
    private func commandBarKey(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            editor.send("vim.prompt.submit", ["text": commandField.stringValue])
        case #selector(NSResponder.cancelOperation(_:)):
            editor.send("vim.prompt.key", ["key": "Escape"])
        case #selector(NSResponder.moveUp(_:)):
            editor.send("vim.prompt.key", ["key": "ArrowUp"])
        case #selector(NSResponder.moveDown(_:)):
            editor.send("vim.prompt.key", ["key": "ArrowDown"])
        case #selector(NSResponder.deleteBackward(_:)) where commandField.stringValue.isEmpty:
            // Backspace in an empty command line leaves it, as in vim.
            editor.send("vim.prompt.key", ["key": "Backspace"])
        default:
            return false
        }
        return true
    }

    /// The header title. A finished todo gets a green tick and its name struck through (owner
    /// decision, 2026-09-21), so a list that is done reads as done from across the room. Drawn
    /// here, never written into the note: the file keeps its plain title.
    private func refreshTitle() {
        guard !titleField.isRenaming else { return }
        let colour = foreground.withAlphaComponent(0.86)
        let font = titleField.font ?? .systemFont(ofSize: 12.5, weight: .semibold)
        let title = NSMutableAttributedString()
        // In a stack the note's number leads its title: it is what ⌘1–⌘5 go by, and it only shows
        // while the note is in a stack (owner decision, 2026-09-22).
        if let number = stack?.number(of: note.id) {
            title.append(NSAttributedString(string: "#\(number)  ", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .heavy),
                .foregroundColor: colour.withAlphaComponent(0.55)]))
        }
        guard note.isTodo && note.isDone else {
            title.append(NSAttributedString(string: note.title, attributes: [.font: font, .foregroundColor: colour]))
            titleField.attributedStringValue = title
            return
        }
        title.append(NSAttributedString(string: "✓ ", attributes: [
            .font: NSFont.systemFont(ofSize: font.pointSize, weight: .heavy),
            .foregroundColor: TaskProgressStyle.done]))
        title.append(NSAttributedString(string: note.title, attributes: [
            .font: font, .foregroundColor: colour.withAlphaComponent(0.6),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: colour.withAlphaComponent(0.6)]))
        titleField.attributedStringValue = title
    }

    var debugTitleText: NSAttributedString { titleField.attributedStringValue }

    /// The header pin: outlined when free, filled and in the accent color when pinned.
    private func refreshPinGlyph() {
        pinButton.image = symbol(note.pinned ? "pin.fill" : "pin")
        pinButton.contentTintColor = note.pinned ? AppSettings.shared.outlineColor : foreground.withAlphaComponent(0.5)
        pinButton.toolTip = (note.pinned ? "Unpin" : "Pin on top") + "  " + ShortcutStore.shared.combo(for: .pin).display
    }

    /// Shows the chosen emoji bullet on the button, or the ordinary bullet-list glyph.
    private func refreshBulletButton() {
        let emoji = AppSettings.shared.bulletEmoji
        if emoji.isEmpty {
            bulletButton.title = ""
            bulletButton.image = symbol("list.bullet")
            bulletButton.imagePosition = .imageOnly
        } else {
            bulletButton.image = nil
            bulletButton.font = .systemFont(ofSize: 13)
            bulletButton.title = emoji
            bulletButton.imagePosition = .noImage
        }
    }

    private func refreshTagsButton() {
        let color = foreground.withAlphaComponent(note.tags.isEmpty ? 0.5 : 0.75)
        tagsButton.image = NSImage(systemSymbolName: note.tags.isEmpty ? "tag" : "tag.fill", accessibilityDescription: "Tags")?
            .withSymbolConfiguration(.init(pointSize: ChromeSize.glyph, weight: .semibold))
        tagsButton.contentTintColor = color
        tagPills.tags = note.tags
        tagPills.foreground = foreground
    }

    private func refreshModeGlyph() {
        // The glyph shows what you will switch TO: pencil in Source mode, book in Live
        // Preview mode. SPEC.md §4.1.
        let symbol = editor.mode == "live" ? "pencil" : "book"
        modeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggle mode")?
            .withSymbolConfiguration(.init(pointSize: ChromeSize.glyph, weight: .semibold))
    }

    func updateCollapsedState() {
        let c = note.collapsed
        editor.isHidden = c
        appearanceButton.isHidden = c
        expandButton.isHidden = c
        grip.isHidden = c
        freezeButton.isHidden = c
        // A back note of a stack shows only its title bar; its mode switch would act on a hidden body.
        modeButton.isHidden = c || (stack != nil && stack?.front != note.id)
        collapseButton.image = symbol(c ? "chevron.right" : "chevron.down")
        collapseButton.toolTip = c ? "Expand" : "Collapse"
        updateActionBar()
        needsLayout = true
        needsDisplay = true
    }

    /// Tools show only while the bar is expanded; the tag list takes their place otherwise.
    ///
    /// `animated` is only true when the user actually opened or closed the bar. Every other caller
    /// (a layout pass, a refresh, a colour change) has to set the same state instantly, or the
    /// tools would fade in again every time anything touched the note.
    private func updateActionBar(animated: Bool = false) {
        // While the command bar (or a vim message) owns the action bar, nothing else may come back
        // up — not even the auto-collapse timer's cross-fade.
        if barOverlay != .none { applyOverlayVisibility(); needsLayout = true; return }
        vimModeLabel.isHidden = vimMode == nil || note.collapsed
        let open = actionBarExpanded && !note.collapsed
        let tools: [NSView] = [bulletButton, boldButton, italicButton, codeButton, opacitySlider]
        let tagSide: [NSView] = [tagsButton, tagPills, bellButton, taskProgress]

        // What each side WOULD be, ignoring the animation.
        let toolsHidden = !open
        let hiddenFor: [NSView: Bool] = [
            tagsButton: open || note.collapsed,
            tagPills: open || note.collapsed,
            bellButton: open || note.collapsed || !note.isTodo,
            taskProgress: (open || note.collapsed || !note.isTodo) || note.taskCounts.total == 0,
        ]

        if animated && Motion.enabled {
            // The side arriving slides in from where the chevron is and fades up; the side leaving
            // fades out and drifts the other way, so the swap reads as one movement.
            for view in tools { fade(view, toHidden: toolsHidden, slideFrom: -10) }
            for view in tagSide { fade(view, toHidden: hiddenFor[view] ?? true, slideFrom: 10) }
        } else {
            for view in tools { view.isHidden = toolsHidden; view.alphaValue = 1 }
            for view in tagSide { view.isHidden = hiddenFor[view] ?? true; view.alphaValue = 1 }
        }

        expandButton.image = symbol(actionBarExpanded ? "chevron.left" : "chevron.right")
        expandButton.toolTip = actionBarExpanded ? "Hide formatting tools" : "Formatting tools"

        // Collapsing hides the whole action bar, squares and all. A collapsed todo keeps its
        // progress where it can still be seen: in the title bar.
        let counts = note.taskCounts
        collapsedProgress.isHidden = !(note.collapsed && note.isTodo && counts.total > 0)
        collapsedProgress.counts = counts
        collapsedProgress.foreground = foreground
        needsLayout = true
    }

    /// Fades one action-bar control in or out. Shown views are un-hidden first so the fade is
    /// visible; hidden ones are only marked hidden once they have faded, or they vanish instantly.
    private func fade(_ view: NSView, toHidden hidden: Bool, slideFrom offset: CGFloat) {
        view.wantsLayer = true
        if hidden {
            guard !view.isHidden else { view.alphaValue = 1; return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.13
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                view.animator().alphaValue = 0
            }, completionHandler: {
                view.isHidden = true
                view.alphaValue = 1          // ready for the next time it is shown
            })
        } else {
            view.isHidden = false
            view.alphaValue = 1
            // Driven from the LAYER rather than view.animator(): a view that was hidden a moment
            // ago has no presentation layer yet, and the AppKit animator quietly does nothing.
            guard let layer = view.layer else { return }
            let slide = CASpringAnimation(keyPath: "transform.translation.x")
            slide.fromValue = offset
            slide.toValue = 0
            slide.mass = 1; slide.stiffness = 320; slide.damping = 20
            slide.duration = slide.settlingDuration

            let fadeUp = CABasicAnimation(keyPath: "opacity")
            fadeUp.fromValue = 0
            fadeUp.toValue = 1
            fadeUp.duration = 0.22
            fadeUp.timingFunction = CAMediaTimingFunction(name: .easeOut)

            layer.add(slide, forKey: "pintack.actionbar.slide")
            layer.add(fadeUp, forKey: "pintack.actionbar.fade")
        }
    }

    func updateLayoutForPin() { needsLayout = true }

    override func layout() {
        super.layout()
        let c = cardRect
        let btn = ChromeSize.headerButton
        let headerY = c.maxY - NotePanel.headerHeight
        let buttonY = headerY + (NotePanel.headerHeight - btn) / 2
        // The title clears the overhanging pin when the note is pinned. SPEC.md §5.2.
        let left = c.minX + (showsOwnPin ? 24 : 12)

        var titleRight: CGFloat
        if stack != nil {
            // In a stack the note's own pin, collapse, close and paperclip give way to the stack
            // bar's. The front note keeps its Live Preview / Source switch, the only one that is
            // still about the note itself.
            modeButton.frame = NSRect(x: c.maxX - 6 - btn, y: buttonY, width: btn, height: btn)
            titleRight = (modeButton.isHidden ? c.maxX - 6 : modeButton.frame.minX) - 6
        } else {
            closeButton.frame = NSRect(x: c.maxX - 6 - btn, y: buttonY, width: btn, height: btn)
            collapseButton.frame = NSRect(x: closeButton.frame.minX - btn, y: buttonY, width: btn, height: btn)
            modeButton.frame = NSRect(x: collapseButton.frame.minX - btn, y: buttonY, width: btn, height: btn)
            pinButton.frame = NSRect(x: (note.collapsed ? collapseButton : modeButton).frame.minX - btn,
                                     y: buttonY, width: btn, height: btn)
            // The paperclip sits just left of the pushpin (owner decision, 2026-09-22).
            clipButton.frame = NSRect(x: pinButton.frame.minX - btn, y: buttonY, width: btn, height: btn)
            titleRight = clipButton.frame.minX - 6
        }
        layoutStackBar(in: c, headerY: headerY, button: btn)
        if !collapsedProgress.isHidden {
            // Title, then the bar and its count, then the header buttons.
            let width = TaskProgressLineView.width(for: collapsedProgress.counts.total)
            collapsedProgress.frame = NSRect(x: titleRight - width, y: headerY + 7, width: width, height: 17)
            titleRight = collapsedProgress.frame.minX - 8
        }
        titleField.frame = NSRect(x: left, y: headerY + 7, width: max(20, titleRight - left), height: 17)

        let footer = footerHeight
        editor.frame = NSRect(x: c.minX + 1, y: c.minY + footer, width: c.width - 2,
                              height: max(0, c.height - NotePanel.headerHeight - stackBarHeight - footer))

        // Footer, left to right: 🎨  >  then either the tags or the tools; the resize grip at the far right.
        // The controls stay on the TOP row of the bar; extra tracker rows hang below them.
        let bar = ChromeSize.barButton, rowHeight = bar.height
        let y = c.minY + footer - ChromeSize.barRowDrop
        appearanceButton.frame = NSRect(x: c.minX + 6, y: y, width: bar.width, height: rowHeight)
        expandButton.frame = NSRect(x: appearanceButton.frame.maxX + 2, y: y,
                                    width: ChromeSize.chevron.width, height: rowHeight)
        grip.frame = NSRect(x: c.maxX - ChromeSize.grip - 4, y: c.minY + 4, width: ChromeSize.grip, height: ChromeSize.grip)
        freezeButton.frame = NSRect(x: grip.frame.minX - bar.width, y: y, width: bar.width, height: rowHeight)

        // The vim mode label sits just left of the snowflake; everything else ends before it.
        let barRight: CGFloat
        if vimMode != nil {
            vimModeLabel.frame = NSRect(x: freezeButton.frame.minX - NoteCardView.vimLabelWidth - 4,
                                        y: y + (rowHeight - 16) / 2, width: NoteCardView.vimLabelWidth, height: 16)
            barRight = vimModeLabel.frame.minX
        } else {
            barRight = freezeButton.frame.minX
        }
        // The command bar and vim's messages span the bar, up to the grip.
        let overlayX = c.minX + 12
        commandPrefix.frame = NSRect(x: overlayX, y: y + (rowHeight - 18) / 2, width: 16, height: 18)
        commandField.frame = NSRect(x: commandPrefix.frame.maxX, y: y + (rowHeight - 20) / 2,
                                    width: max(40, grip.frame.minX - 8 - commandPrefix.frame.maxX), height: 20)
        vimMessageLabel.frame = NSRect(x: overlayX, y: y + (rowHeight - 16) / 2,
                                       width: max(40, grip.frame.minX - 8 - overlayX), height: 16)

        var x = expandButton.frame.maxX + 4
        if actionBarExpanded {
            for tool in [bulletButton, boldButton, italicButton, codeButton] {
                tool.frame = NSRect(x: x, y: y, width: bar.width, height: rowHeight)
                x += bar.width + 1
            }
            let sliderWidth = barRight - 8 - (x + 4)
            opacitySlider.frame = NSRect(x: x + 4, y: y + (rowHeight - 16) / 2, width: max(0, sliderWidth), height: 16)
            opacitySlider.isHidden = sliderWidth < 36 || note.collapsed          // too narrow to use
        } else {
            tagsButton.frame = NSRect(x: x, y: y, width: bar.width, height: rowHeight)
            // The bell sits next to the tag glyph, and only on a todo note.
            let pillsStart: CGFloat
            if note.isTodo {
                bellButton.frame = NSRect(x: tagsButton.frame.maxX + 1, y: y, width: bar.width, height: rowHeight)
                pillsStart = bellButton.frame.maxX + 2
            } else {
                bellButton.frame = .zero
                pillsStart = tagsButton.frame.maxX + 2
            }
            // This note's own progress, between the bell and the tags. It wraps at six squares a
            // row (fewer on a narrow note) and the bar has already been made tall enough for it,
            // so it is never hidden for want of room — which is what used to happen past about
            // seven tasks, taking the tags down with it.
            let counts = note.isTodo ? note.taskCounts : (done: 0, total: 0)
            taskProgress.counts = counts
            taskProgress.perRow = progressPerRow
            taskProgress.showsLabel = progressShowsLabel
            taskProgress.foreground = foreground
            let rows = counts.total > 0 ? (counts.total + progressPerRow - 1) / progressPerRow : 0
            let blockWidth = TaskProgressView.width(perRow: progressPerRow, total: counts.total,
                                                    showsLabel: progressShowsLabel)
            let blockHeight = TaskProgressView.height(rows: rows)
            // The first row of squares sits on the controls' line; the rest hang below it.
            // Centred on the controls' row: its middle, plus half a square.
            let firstRowTop = y + rowHeight / 2 + TaskProgressStyle.square / 2
            taskProgress.frame = NSRect(x: pillsStart, y: firstRowTop - blockHeight,
                                        width: blockWidth, height: blockHeight)
            let afterProgress = blockWidth > 0 ? pillsStart + blockWidth + 8 : pillsStart
            // The tags take the whole thickness of the bar, wrapping into as many lines as fit.
            let tagsTop = y + rowHeight / 2 + TagPillsView.lineHeight / 2
            let tagsBottom = c.minY + 4
            tagPills.frame = NSRect(x: afterProgress, y: tagsBottom,
                                    width: max(0, barRight - afterProgress - 6),
                                    height: max(TagPillsView.lineHeight, tagsTop - tagsBottom))
        }
    }

    // MARK: - Refresh from model

    /// The note changed underneath us (Appearance popover, hotkey, external edit).
    func refreshFromNote() {
        panel.applyOpacity()
        panel.applyPinned()
        applyColors()
        editor.pushSettings()
        // A note can BECOME a todo (typing @todo), which changes what the action bar shows.
        todoSignature = currentTodoSignature
        updateActionBar()
        syncFooterHeight()
        updateReminderGlyph()
        needsLayout = true
        needsDisplay = true
    }

    @objc private func settingsChanged() {
        if !AppSettings.shared.actionBarAutoCollapse { cancelCollapseTimer() }
        panel.applyOpacity()
        tagPills.needsDisplay = true              // a tag's colour may just have been changed
        applyColors()
        editor.pushSettings()
        needsDisplay = true
    }

    @objc private func bodyChanged(_ n: Notification) {
        needsLayout = true
        if titleField.currentEditor() == nil { refreshTitle() }
        refreshTagsButton()
        syncTodoState()
    }

    @objc private func tagsMayHaveChanged() {
        refreshTagsButton()
        editor.pushTags()
        // Tagging a note `todo` is one of the two ways it becomes one, so the bar may change here too.
        syncTodoState()
        needsLayout = true
    }

    // MARK: - Actions

    @objc func togglePin() {
        note.pinned.toggle()
        panel.applyPinned()
        refreshPinGlyph()
        VaultStore.shared.save(note)
        Toast.show(note.pinned ? "📌 Pinned on top" : "Unpinned")
    }

    /// Freeze / thaw. While frozen the note lets the mouse through everywhere except the
    /// snowflake corner, which FreezeMode keeps live so this button can always be reached.
    @objc func toggleFreeze() {
        note.frozen.toggle()
        panel.applyFrozen()
        VaultStore.shared.save(note)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
        Toast.show(note.frozen ? "Frozen — clicks pass through" : "Thawed")
    }

    /// The bell carries a dot once something is actually scheduled, so a note with a live
    /// reminder is obvious without opening anything.
    func updateReminderGlyph() {
        let armed = note.due != nil && (note.remindOnTime || !note.remindAhead.isEmpty)
        bellButton.image = symbol(armed ? "bell.badge.fill" : (note.due != nil ? "bell.fill" : "bell"))
        bellButton.contentTintColor = note.due != nil ? Brand.accentNS : foreground.withAlphaComponent(0.55)
        bellButton.toolTip = note.due.map { "Due \($0.formatted(date: .abbreviated, time: .shortened))" }
            ?? "Due date and reminders"
    }

    /// The "+2" pill: shows every tag, for when the note is too narrow to lay them all out.
    /// Widening the note still reveals them in place; this is the way that does not move anything.
    @objc private func showAllTags() {
        let view = VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(note.tags, id: \.self) { tag in
                HStack(spacing: 6) {
                    Circle().fill(Color(nsColor: TagPillsView.color(for: tag))).frame(width: 9, height: 9)
                    Text("#" + tag).font(.system(size: 12))
                }
            }
            Button("Edit tags…") { [weak self] in self?.showTags() }
                .buttonStyle(.link).font(.caption).padding(.top, 2)
        }
        .padding(12)
        .frame(minWidth: 130, alignment: .leading)
        present(view, from: tagPills)
    }

    @objc private func showReminders() {
        let view = ReminderPopoverView(note: note, onChange: { [weak self] in
            self?.updateReminderGlyph()
            NotificationCenter.default.post(name: .vaultDidChange, object: nil)
        }, onDone: { [weak self] in
            self?.popover?.close()
        })
        present(view, from: bellButton)
    }

    func updateFrozenState() {
        freezeButton.image = symbol(note.frozen ? "snowflake.circle.fill" : "snowflake")
        freezeButton.toolTip = note.frozen ? "Thaw (take clicks again)" : "Freeze (click-through)"
        freezeButton.contentTintColor = note.frozen ? Brand.accentNS : foreground.withAlphaComponent(0.55)
        needsDisplay = true
    }

    @objc func toggleCollapse() {
        NoteCardView.collapseRunCount += 1          // read by the self-test's double-fire check
        note.collapsed.toggle()
        panel.applyCollapsed(animated: true)
        VaultStore.shared.save(note)
    }

    @objc func toggleMode() { editor.toggleMode() }

    @objc func closeNote() {
        if let s = stack { StackManager.shared.hide(s.id); return }
        SaveCoordinator.shared.flush(noteID: note.id)
        // Closed with nothing in it: it goes, rather than joining the Untitled/Empty rows in All
        // Notes. Only on an explicit close — hiding every note at once is not a change of mind.
        // The discard comes FIRST and decides: if it refuses (the file has words the app has not
        // read yet), this falls through to an ordinary hide and nothing blank is written anywhere.
        if VaultStore.shared.discardIfBlank(note) {
            WindowManager.shared.close(noteID: note.id)
            Toast.show("Empty note discarded")
            return
        }
        note.visible = false
        VaultStore.shared.save(note)
        WindowManager.shared.close(noteID: note.id)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
        Toast.show("Hidden · still in All Notes")
    }

    @objc func deleteNote() { WindowManager.shared.delete([note]) }

    @objc func duplicateNote() {
        let copy = VaultStore.shared.duplicate(note)
        WindowManager.shared.open(copy, focus: true)
    }

    /// ⌥⌘1…6: the Nth swatch of the note's own palette mode.
    func setColor(index: Int) {
        let set = NotePalette.set(for: note.theme)
        guard set.indices.contains(index) else { return }
        note.colorHex = set[index].hex
        VaultStore.shared.save(note)
        refreshFromNote()
    }

    func nudgeOpacity(by delta: Double) {
        let stepped = ((note.opacity + delta) * 100).rounded() / 100
        note.opacity = min(1, max(0.3, stepped))       // 0.3 floor: an invisible note is unrecoverable. SPEC.md §3.3
        VaultStore.shared.save(note)
        refreshFromNote()
        Toast.show("Opacity \(Int((note.opacity * 100).rounded()))%")
    }

    func focusEditor() { editor.focusEditor() }
    func openEmoji() { editor.openEmoji() }

    // MARK: Action bar

    @objc private func toggleActionBar() {
        actionBarExpanded.toggle()
        updateActionBar(animated: true)
        if actionBarExpanded { startCollapseTimer() } else { cancelCollapseTimer() }
    }

    @objc private func applyBullet() { editor.format("bullet"); keepBarOpen() }
    @objc private func applyBold() { editor.format("bold"); keepBarOpen() }
    @objc private func applyItalic() { editor.format("italic"); keepBarOpen() }
    @objc private func applyCode() { editor.format("code"); keepBarOpen() }

    @objc private func opacityChanged(_ slider: NSSlider) {
        note.opacity = min(1, max(0.3, (slider.doubleValue * 100).rounded() / 100))
        panel.applyOpacity()
        SaveCoordinator.shared.scheduleSave(note)      // debounced: no write per slider tick
    }

    /// Using a tool restarts the auto-collapse countdown.
    private func keepBarOpen() { if actionBarExpanded { startCollapseTimer() } }

    private func startCollapseTimer() {
        cancelCollapseTimer()
        let s = AppSettings.shared
        guard actionBarExpanded, s.actionBarAutoCollapse else { return }
        // While the pointer is over the footer the user is still working in it.
        if let window, footerRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: s.actionBarCollapseSeconds, repeats: false) { [weak self] _ in
            guard let self, self.actionBarExpanded else { return }
            self.actionBarExpanded = false
            self.updateActionBar(animated: true)      // auto-collapse should ease away, not blink
        }
    }

    private func cancelCollapseTimer() { collapseTimer?.invalidate(); collapseTimer = nil }

    private var footerRect: NSRect {
        NSRect(x: cardRect.minX, y: cardRect.minY, width: cardRect.width, height: footerHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let footerTracking { removeTrackingArea(footerTracking) }
        let area = NSTrackingArea(rect: footerRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self,
                                  userInfo: ["zone": "footer"])
        addTrackingArea(area)
        footerTracking = area
        // The whole CARD, not the window: the window is 24pt bigger on every side (SPEC.md §5.2),
        // and a note that lit up when the pointer was merely near it would be jumpy.
        if let cardTracking { removeTrackingArea(cardTracking) }
        let card = NSTrackingArea(rect: cardRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self,
                                  userInfo: ["zone": "card"])
        addTrackingArea(card)
        cardTracking = card
    }

    override func mouseEntered(with event: NSEvent) {
        if (event.trackingArea?.userInfo?["zone"] as? String) == "card" { setHovered(true); return }
        cancelCollapseTimer()
    }
    override func mouseExited(with event: NSEvent) {
        if (event.trackingArea?.userInfo?["zone"] as? String) == "card" { setHovered(false); return }
        startCollapseTimer()
    }

    /// Hover-to-reveal (Settings → Notes). Internal so the self-test can hover without a mouse.
    func setHovered(_ hovered: Bool) {
        guard panel.isHovered != hovered else { return }
        panel.isHovered = hovered
        panel.applyOpacity(animated: true)
    }

    @objc private func showAppearance() {
        let view = AppearancePopoverView(note: note) { [weak self] in
            guard let self else { return }
            VaultStore.shared.save(self.note)
            self.refreshFromNote()
        }
        present(view, from: appearanceButton)
    }

    @objc private func showTags() { presentTags(colouring: nil) }

    private func presentTags(colouring: String?) {
        let view = TagsPopoverView(note: note, colouring: colouring) { [weak self] in
            guard let self else { return }
            VaultStore.shared.save(self.note)
            self.refreshTagsButton()
            NotificationCenter.default.post(name: .vaultDidChange, object: nil)
        }
        present(view, from: tagsButton)
    }

    private func present<V: View>(_ view: V, from anchor: NSView) {
        popover?.close()
        let host = NSHostingController(rootView: view)
        // Content that grows while open (the tag editor's colour swatches) resizes the popover
        // instead of being clipped by the size it was measured at.
        host.sizingOptions = [.preferredContentSize]
        // Measure the SwiftUI content BEFORE showing. Shown unmeasured, the popover is placed for a
        // placeholder size and then shrinks in place, leaving it floating a couple of hundred points
        // away from the button it belongs to (found by measuring: 158 pt off).
        host.view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize

        let p = NSPopover()
        p.behavior = .transient
        // AppKit's own popover animation stays off: it fades a MIS-SIZED popover into place, which
        // is what made the sizing bug above so ugly. Motion.popover springs the finished one in
        // instead, matching the rest of the app.
        p.animates = false
        p.contentViewController = host
        p.contentSize = size
        // AppKit picks the side with room (below the note when it can), always touching the button.
        p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        Motion.popover(host.view.window)
        popover = p
    }

    // MARK: - Title editing

    /// Double-click the title to rename it. Until then the title is not editable, so a
    /// single click-drag moves the note. Enter commits and the title is solid again.
    private func beginRename() {
        guard !titleField.isRenaming else { return }
        panel.makeKeyAndOrderFront(nil)
        // Renaming edits the words, not the tick and the strike-through drawn over them.
        titleField.stringValue = note.title
        titleField.isRenaming = true
        titleField.isEditable = true
        titleField.isSelectable = true
        window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    private func endRename() {
        titleField.isRenaming = false
        titleField.isEditable = false
        titleField.isSelectable = false
    }

    /// Editing the header rewrites the note's first heading. SPEC.md §4.4.
    func controlTextDidEndEditing(_ obj: Notification) {
        // The command field shares this delegate. Without this, ending its edit would RENAME THE
        // NOTE to the vim command just typed. Losing focus mid-command cancels the command instead.
        if (obj.object as? NSTextField) === commandField {
            if barOverlay == .command { editor.send("vim.prompt.key", ["key": "Escape"]) }
            return
        }
        if (obj.object as? NSTextField) === stackNameField {
            let name = stackNameField.stringValue
            endStackRename()
            if let s = stack { StackManager.shared.rename(s.id, to: name) }
            refreshStackState()
            window?.makeFirstResponder(editor)
            return
        }
        let text = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        endRename()
        // Renaming stores a title beside the note rather than rewriting its first line, so the
        // body is left alone and the editor does not need to be told anything.
        if text != note.title { WindowManager.shared.rename(note, to: text) }
        refreshTitle()
        window?.makeFirstResponder(editor)
    }

    /// Esc abandons the rename.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === commandField else { return }
        editor.send("vim.prompt.input", ["text": commandField.stringValue])
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if control === commandField { return commandBarKey(selector) }
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if control === stackNameField {
            stackNameField.stringValue = stack?.name ?? ""
            window?.makeFirstResponder(editor)
            return true
        }
        // Plain text, and still renaming: ending the edit below reads this field back and renames
        // the note to whatever it says, so it must not hold the drawn "✓ " of a finished todo.
        titleField.stringValue = note.title
        window?.makeFirstResponder(editor)
        return true
    }

    // MARK: - Resizing

    private func resizeBegan() {}

    // MARK: - Dragging

    /// Whether the pointer moved while the header was held: a click on a stacked note's title bar
    /// brings it forward, a drag moves the pile.
    private var dragMoved = false

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if showsOwnPin && pinRect.contains(local) && !cardRect.contains(local) { togglePin(); return }
        // The header, the stack bar and any empty footer space drag the note; controls sit above and
        // take their own clicks.
        guard headerRect.contains(local) || stackBarRect.contains(local) || (footerRect.contains(local) && !note.collapsed) else {
            super.mouseDown(with: event); return
        }
        if showsOwnPin && pinRect.contains(local) { togglePin(); return }
        if event.clickCount == 2 && titleField.frame.contains(local) { dragOrigin = nil; beginRename(); return }
        if event.clickCount == 2 && stackNameField.frame.contains(local) && stack != nil {
            dragOrigin = nil; beginStackRename(); return
        }
        dragOrigin = event.locationInWindow
        dragStart = window?.convertPoint(toScreen: event.locationInWindow)
        dragMoved = false
    }

    /// Where the press began, on the screen. A click is anything that moved less than this.
    private var dragStart: NSPoint?
    private static let clickSlop: CGFloat = 4

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let window else { super.mouseDragged(with: event); return }
        // Screen position of the pointer, from the event itself (not NSEvent.mouseLocation, which
        // is the real cursor and so cannot be driven by tests).
        let current = window.convertPoint(toScreen: event.locationInWindow)
        let target = NSPoint(x: current.x - origin.x, y: current.y - origin.y)
        // A hand never holds perfectly still: under 4pt from the press is still a click, which in a
        // stack brings the note forward rather than dragging the pile a pixel.
        if let start = dragStart, !dragMoved, hypot(current.x - start.x, current.y - start.y) < NoteCardView.clickSlop { return }
        dragMoved = true
        // A stack moves as one: dragging any of its title bars carries the whole pile.
        if stack != nil { StackManager.shared.drag(panel, to: target) } else { window.setFrameOrigin(target) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragOrigin != nil {
            dragOrigin = nil
            if stack != nil {
                if dragMoved { StackManager.shared.dragEnded(panel) } else { StackManager.shared.bringToFront(note.id) }
            } else {
                panel.syncFrameToNote()
                VaultStore.shared.save(note)
            }
        }
        super.mouseUp(with: event)
    }

    // MARK: - Context menu (SPEC.md §5.3)

    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        guard headerRect.contains(local) || footerRect.contains(local) || (note.pinned && pinRect.contains(local)) else { return nil }
        return noteMenu(editing: false)
    }

    func noteMenu(editing: Bool) -> NSMenu {
        let menu = NSMenu()
        contextMenuItems(editing: editing).forEach { menu.addItem($0) }
        return menu
    }

    /// One menu for the whole note, whether you right-click the header, the footer or the text:
    /// everything from the menu bar's Note menu, All Notes from Window, and note management.
    /// `editing` adds Cut / Copy / Paste / Select All for right-clicks inside the text.
    func contextMenuItems(editing: Bool) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        // Items that run one of the app's shortcut actions on THIS note, showing its key binding.
        func action(_ title: String, _ a: ShortcutAction) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(menuPerform(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = a.rawValue
            MainMenuBuilder.apply(ShortcutStore.shared.combo(for: a), to: i)
            return i
        }
        func plain(_ title: String, _ sel: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            return i
        }

        if editing {
            // No target: these go to the first responder, the editor's web view.
            items.append(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
            items.append(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
            items.append(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
            items.append(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
            items.append(.separator())
        }

        // The menu bar's Note menu.
        items.append(action(note.pinned ? "Unpin from Top" : "Pin on Top", .pin))
        items.append(action(note.collapsed ? "Expand" : "Collapse", .collapse))
        items.append(action(note.frozen ? "Thaw" : "Freeze (click-through)", .freeze))
        items.append(action(editor.mode == "live" ? "Switch to Source" : "Switch to Live Preview", .toggleMode))
        items.append(action("Emoji…", .emoji))

        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu(title: "Color")
        for (i, a) in [ShortcutAction.color1, .color2, .color3, .color4, .color5, .color6].enumerated() {
            let swatch = NotePalette.set(for: note.theme)[i]
            let c = action(swatch.name, a)
            c.state = swatch.hex.caseInsensitiveCompare(note.colorHex) == .orderedSame ? .on : .off
            c.image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
                (NSColor(hex: swatch.hex) ?? .yellow).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
                NSColor.black.withAlphaComponent(0.25).setStroke(); NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
                return true
            }
            colorMenu.addItem(c)
        }
        colorItem.submenu = colorMenu
        items.append(colorItem)
        items.append(action("Less Opaque", .lessOpaque))
        items.append(action("More Opaque", .moreOpaque))
        items.append(action("Round / Square Corners", .toggleCorners))
        items.append(.separator())

        // From the menu bar's Window menu.
        items.append(action("All Notes", .toggleAllNotes))
        items.append(action("Auto-Arrange Notes", .autoArrange))
        items.append(.separator())

        // Managing this note.
        items.append(plain("Minimize to All Notes", #selector(closeNote)))
        items.append(plain("Duplicate", #selector(duplicateNote)))

        let move = NSMenuItem(title: "Move to Folder…", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let current = VaultStore.shared.folder(of: note)
        let root = sub.addItem(withTitle: "Vault root", action: #selector(moveToFolder(_:)), keyEquivalent: "")
        root.target = self; root.representedObject = ""; root.state = current.isEmpty ? .on : .off
        for f in VaultStore.shared.folders() {
            let item = sub.addItem(withTitle: f, action: #selector(moveToFolder(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = f; item.state = f == current ? .on : .off
        }
        sub.addItem(.separator())
        sub.addItem(plain("New Folder…", #selector(moveToNewFolder)))
        move.submenu = sub
        items.append(move)

        items.append(.separator())
        items.append(action("Close Note", .close))
        items.append(plain("Delete Note", #selector(deleteNote)))
        return items
    }

    @objc private func menuPerform(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = ShortcutAction(rawValue: raw) else { return }
        perform(a)
    }

    /// Runs a shortcut action against THIS note. Note-scoped actions land here from the key
    /// monitor, the menus and the context menu alike, so they cannot disagree.
    func perform(_ action: ShortcutAction) {
        // In a stack, pin / collapse / close act on the whole stack, like the stack bar's buttons.
        if let s = stack {
            switch action {
            case .pin:        StackManager.shared.togglePin(s.id); return
            case .collapse:   StackManager.shared.toggleCollapse(s.id); return
            case .close:      StackManager.shared.hide(s.id); return
            case .stackCycle: StackManager.shared.cycle(from: note.id); return
            default:
                if let n = action.stackNumber { StackManager.shared.bringToFront(number: n, from: note.id); return }
            }
        }
        switch action {
        case .pin:        togglePin()
        case .collapse:   toggleCollapse()
        case .freeze:     toggleFreeze()
        case .deleteNote: deleteNote()
        case .close:      closeNote()
        case .toggleMode: toggleMode()
        case .emoji:      openEmoji()
        case .lessOpaque: nudgeOpacity(by: -0.1)
        case .moreOpaque: nudgeOpacity(by: 0.1)
        case .color1, .color2, .color3, .color4, .color5, .color6:
            if let i = [ShortcutAction.color1, .color2, .color3, .color4, .color5, .color6].firstIndex(of: action) { setColor(index: i) }
        case .stackCycle, .stackNote1, .stackNote2, .stackNote3, .stackNote4, .stackNote5:
            break                                                // not in a stack: nothing to do
        default:          ActionRouter.perform(action)          // app-wide actions
        }
    }

    @objc private func moveToFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String else { return }
        VaultStore.shared.move(note, toFolder: folder)
        Toast.show("Moved to " + (folder.isEmpty ? "Vault root" : folder))
    }

    @objc private func moveToNewFolder() {
        let alert = NSAlert()
        alert.messageText = "New folder"
        alert.informativeText = "Notes in a folder are stored in a matching directory in the vault."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Folder name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create and Move")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Keep folder names filesystem-safe: no separators, no leading dots.
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty else { return }
        VaultStore.shared.move(note, toFolder: name)
        Toast.show("Moved to " + name)
    }
}

// MARK: - Resize grip

/// Bottom-right grip. The panel's own resize edges sit in the transparent margin
/// (unreachable, by design), so resizing has to come from inside the card.
final class ResizeGripView: NSView {

    var onDrag: (() -> Void)?
    weak var panel: NotePanel?

    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setStroke()
        let p = NSBezierPath()
        p.lineWidth = 1.3
        for offset in [4.0, 8.0, 12.0] {
            p.move(to: NSPoint(x: bounds.maxX - 1, y: bounds.minY + offset))
            p.line(to: NSPoint(x: bounds.maxX - offset, y: bounds.minY + 1))
        }
        p.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startMouse = window.convertPoint(toScreen: event.locationInWindow)
        startFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = window.convertPoint(toScreen: event.locationInWindow)
        let minW = window.minSize.width, minH = window.minSize.height
        let w = max(minW, startFrame.width + (now.x - startMouse.x))
        let extra = panel?.card.extraFooterHeight ?? 0
        let h = max(minH + NotePanel.footerHeight + extra + 40, startFrame.height + (startMouse.y - now.y))
        // The top-left corner stays put; the bottom-right follows the mouse.
        window.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - h, width: w, height: h), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        panel?.syncFrameToNote()
        // A narrower note fits fewer squares on a row, so the bar's thickness is re-derived once
        // the drag ends rather than fighting the drag, then the frame is written back again.
        panel?.card.syncFooterHeight(animated: false)
        panel?.syncFrameToNote()
        if let note = panel?.note { VaultStore.shared.save(note) }
        // The front note of a stack sets the size of the whole pile.
        if let panel { StackManager.shared.resized(panel) }
    }
}


// MARK: - Small controls

/// The header title. Not editable until the user double-clicks it, and while it is not
/// editable it is invisible to mouse hit-testing, so clicks fall through to the card and
/// the title drags the note like the rest of the header.
final class TitleField: NSTextField {
    var isRenaming = false
    override func hitTest(_ point: NSPoint) -> NSView? { isRenaming ? super.hitTest(point) : nil }
    override var acceptsFirstResponder: Bool { isRenaming }
}

/// A borderless icon button that can also react to a right-click.
final class ToolButton: NSButton {
    var onRightClick: (() -> Void)?
    override func rightMouseDown(with event: NSEvent) {
        if let onRightClick { onRightClick() } else { super.rightMouseDown(with: event) }
    }
}

#if DEBUG
/// Hooks for the self-test (Support/SelfTest.swift). Compiled out of Release.
extension NoteCardView {
    /// What the stack shows on this card: its bar, the paperclip, the mode switch, the bar's name.
    var debugStack: (bar: Bool, clip: Bool, mode: Bool, name: String) {
        (!stackNameField.isHidden, !clipButton.isHidden, !modeButton.isHidden, stackNameField.stringValue)
    }
    func debugShowStackCreator() { showStackCreator() }
    /// A click on an empty part of the title bar, through mouseDown/mouseUp as a pointer sends it.
    func debugClickHeader() {
        guard let window else { return }
        let point = convert(NSPoint(x: headerRect.maxX - 70, y: headerRect.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { continue }
            if type == .leftMouseDown { mouseDown(with: e) } else { mouseUp(with: e) }
        }
    }
    func debugExpandActionBar() { if !actionBarExpanded { toggleActionBar() } }
    func debugShowAppearance() { showAppearance() }
    var debugIsRenaming: Bool { titleField.isRenaming }
    var debugTitleCenter: NSPoint { NSPoint(x: titleField.frame.midX, y: titleField.frame.midY) }
    var debugPopoverWindow: NSWindow? { popover?.contentViewController?.view.window }
    var debugPopoverShown: Bool { popover?.isShown == true }
    /// The appearance button's rect in screen coordinates.
    var debugAppearanceButtonScreenRect: NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(appearanceButton.convert(appearanceButton.bounds, to: nil))
    }
    var debugActionBarExpanded: Bool { actionBarExpanded }
    var debugBulletTitle: String { bulletButton.title }
    func debugMenuTitles(editing: Bool) -> [String] { contextMenuItems(editing: editing).map { $0.isSeparatorItem ? "—" : $0.title } }
    func debugMenuItem(_ title: String, editing: Bool) -> NSMenuItem? { contextMenuItems(editing: editing).first { $0.title == title } }
    var debugTagsButtonFrame: NSRect { tagsButton.frame }
    var debugBellHidden: Bool { bellButton.isHidden }
    var debugTagPills: TagPillsView { tagPills }
    var debugProgress: TaskProgressView { taskProgress }
    var debugVim: (mode: String?, labelShown: Bool, commandShown: Bool, prefix: String, text: String,
                   fieldFocused: Bool, message: String?, tagsHidden: Bool) {
        let focused = (window?.firstResponder as? NSText)?.delegate as? NSTextField === commandField
        return (vimMode, !vimModeLabel.isHidden, !commandField.isHidden, commandPrefix.stringValue,
                commandField.stringValue, focused, vimMessageLabel.isHidden ? nil : vimMessageLabel.stringValue,
                tagsButton.isHidden)
    }
    /// Types into the command bar and presses Return or Escape, through the same paths the keys take.
    func debugCommandBar(type text: String) {
        commandField.stringValue = text
        editor.send("vim.prompt.input", ["text": text])
    }
    func debugCommandBar(press selector: Selector) { _ = commandBarKey(selector) }
    var debugCollapsedProgress: TaskProgressLineView { collapsedProgress }
    var debugTitleFrame: NSRect { titleField.frame }
    var debugPinFrame: NSRect { pinButton.frame }
    var debugProgressPerRow: Int { progressPerRow }
    var debugFooterHeight: CGFloat { footerHeight }
    var debugExtraFooterHeight: CGFloat { extraFooterHeight }
    var debugCardRect: NSRect { cardRect }
    func debugShowReminderPopover() { showReminders() }
    var debugPopoverContentView: NSView? { popover?.contentViewController?.view }
    func debugDismissPopover() { popover?.close() }
    func debugCollapseActionBar() { if actionBarExpanded { toggleActionBar() } }
    func debugToggleActionBar() { toggleActionBar() }
    /// (isHidden, on-screen opacity) for a tool and a tag-side control, so the self-test can watch
    /// them cross-fade. Reads the PRESENTATION layer: `alphaValue` is the model value, which jumps
    /// to its destination the moment the animation is set up and so proves nothing.
    var debugActionBarState: (toolHidden: Bool, toolAlpha: CGFloat, tagHidden: Bool, tagAlpha: CGFloat) {
        func onScreen(_ view: NSView) -> CGFloat {
            // -1 says "no presentation layer to read", so a missing animation cannot masquerade
            // as a finished one.
            guard let presented = view.layer?.presentation() else { return -1 }
            return CGFloat(presented.opacity)
        }
        return (boldButton.isHidden, onScreen(boldButton), tagsButton.isHidden, onScreen(tagsButton))
    }
    var debugFooterEmptyPoint: NSPoint { NSPoint(x: cardRect.midX + 20, y: cardRect.minY + 12) }
    func debugShowTags(colouring: String? = nil) { presentTags(colouring: colouring) }
    func debugClosePopover() { popover?.close() }
    var debugHasPopover: Bool { popover?.isShown == true }
}
#endif
