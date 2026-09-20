import AppKit
import SwiftUI

/// The note's visible card: chrome, header controls, editor, footer. SPEC.md §5.3.
///
/// The view is the full WINDOW size; the card is inset by `NotePanel.margin`
/// inside it. Everything below positions itself against `cardRect`, never `bounds`.
final class NoteCardView: NSView, NSTextFieldDelegate {

    private let note: Note
    private unowned let panel: NotePanel

    private let titleField = TitleField()
    private let pinButton = ToolButton()
    private let modeButton = ToolButton()
    private let collapseButton = ToolButton()
    private let closeButton = ToolButton()
    private let appearanceButton = ToolButton()
    private let tagsButton = ToolButton()          // the tag ICON: the only thing that opens the tag editor
    private let tagsLabel = NSTextField(labelWithString: "")   // shows the tags; ignores the mouse so it drags
    private let grip = ResizeGripView()
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
    private var footerTracking: NSTrackingArea?

    private var popover: NSPopover?
    private var dragOrigin: NSPoint?

    private let pinSize: CGFloat = 28

    init(note: Note, panel: NotePanel) {
        self.note = note
        self.panel = panel
        self.editor = NoteEditorView(note: note)
        super.init(frame: .zero)
        wantsLayer = true
        buildSubviews()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(bodyChanged(_:)), name: .noteBodyDidChange, object: note)
        nc.addObserver(self, selector: #selector(settingsChanged), name: .settingsDidChange, object: nil)
        nc.addObserver(self, selector: #selector(tagsMayHaveChanged), name: .vaultDidChange, object: nil)
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

    /// The pushpin art (assets: Pushpin). Its needle enters a crack in the paper, and that crack
    /// is anchored on the card's top-left corner while the head overhangs into the transparent
    /// margin. SPEC.md §5.4. The crack sits 74% across and 87% down the trimmed image; the
    /// height is chosen so the head's top stays inside the 24pt margin (17 + 0.87 × 46 ≈ 23).
    private var pinImageRect: NSRect {
        let h: CGFloat = 46
        let aspect: CGFloat = 188.0 / 285.0
        let w = h * aspect
        let crack = CGPoint(x: cardRect.minX + 24, y: cardRect.maxY - 17)
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
        if note.pinned && pinRect.contains(local) { return self }
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
        let glowing = note.pinned && settings.pinnedGlow
        if glowing {
            for (blur, alpha) in [(22.0, 0.62), (9.0, 0.85)] {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: CGFloat(blur), color: note.color.withAlphaComponent(alpha).cgColor)
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
            sep.move(to: NSPoint(x: rect.minX + 1, y: rect.minY + NotePanel.footerHeight - 0.5))
            sep.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + NotePanel.footerHeight - 0.5))
        }
        sep.stroke()

        if note.pinned {
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
        titleField.stringValue = note.title
        titleField.delegate = self
        addSubview(titleField)

        configure(pinButton, symbol: "pin", tip: "Pin on top", action: #selector(togglePin))
        configure(modeButton, symbol: "book", tip: "Switch between Live Preview and Source", action: #selector(toggleMode))
        configure(collapseButton, symbol: "chevron.down", tip: "Collapse", action: #selector(toggleCollapse))
        configure(closeButton, symbol: "xmark", tip: "Close (keeps the note in All Notes)", action: #selector(closeNote))
        configure(appearanceButton, symbol: "paintpalette", tip: "Color, mode and opacity", action: #selector(showAppearance))
        [pinButton, modeButton, collapseButton, closeButton, appearanceButton].forEach { addSubview($0) }

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
        tagsLabel.font = .systemFont(ofSize: 11)
        tagsLabel.lineBreakMode = .byTruncatingTail
        tagsLabel.isSelectable = false
        addSubview(tagsLabel)

        grip.onDrag = { [weak self] in self?.resizeBegan() }
        grip.panel = panel
        addSubview(grip)

        editor.onModeChange = { [weak self] _ in self?.refreshModeGlyph() }
        editor.contextMenuItems = { [weak self] in self?.contextMenuItems(editing: true) ?? [] }
        addSubview(editor)

        applyColors()
        refreshTagsButton()
        refreshModeGlyph()
        updateCollapsedState()
    }

    private func configure(_ b: NSButton, symbol: String, tip: String, action: Selector) {
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        b.toolTip = tip
        b.target = self
        b.action = action
    }

    private var foreground: NSColor { note.isDarkText ? .black : .white }

    func applyColors() {
        titleField.textColor = foreground.withAlphaComponent(0.86)
        let icon = foreground.withAlphaComponent(0.5)
        [modeButton, collapseButton, closeButton, appearanceButton, expandButton,
         boldButton, italicButton, codeButton].forEach { $0.contentTintColor = icon }
        refreshPinGlyph()
        refreshBulletButton()
        refreshTagsButton()
        opacitySlider.doubleValue = note.opacity
        needsDisplay = true
    }

    private func symbol(_ name: String, weight: NSFont.Weight = .semibold) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: weight))
    }

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
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        tagsButton.contentTintColor = color
        tagsLabel.stringValue = note.tags.joined(separator: ", ")
        tagsLabel.textColor = foreground.withAlphaComponent(0.7)
    }

    private func refreshModeGlyph() {
        // The glyph shows what you will switch TO: pencil in Source mode, book in Live
        // Preview mode. SPEC.md §4.1.
        let symbol = editor.mode == "live" ? "pencil" : "book"
        modeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggle mode")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
    }

    func updateCollapsedState() {
        let c = note.collapsed
        editor.isHidden = c
        appearanceButton.isHidden = c
        expandButton.isHidden = c
        grip.isHidden = c
        modeButton.isHidden = c
        collapseButton.image = symbol(c ? "chevron.right" : "chevron.down")
        collapseButton.toolTip = c ? "Expand" : "Collapse"
        updateActionBar()
        needsLayout = true
        needsDisplay = true
    }

    /// Tools show only while the bar is expanded; the tag list takes their place otherwise.
    private func updateActionBar() {
        let open = actionBarExpanded && !note.collapsed
        [bulletButton, boldButton, italicButton, codeButton, opacitySlider].forEach { $0.isHidden = !open }
        tagsButton.isHidden = open || note.collapsed
        tagsLabel.isHidden = open || note.collapsed
        expandButton.image = symbol(actionBarExpanded ? "chevron.left" : "chevron.right")
        expandButton.toolTip = actionBarExpanded ? "Hide formatting tools" : "Formatting tools"
        needsLayout = true
    }

    func updateLayoutForPin() { needsLayout = true }

    override func layout() {
        super.layout()
        let c = cardRect
        let btn: CGFloat = 20
        let headerY = c.maxY - NotePanel.headerHeight
        // The title clears the overhanging pin when the note is pinned. SPEC.md §5.2.
        let left = c.minX + (note.pinned ? 34 : 12)

        closeButton.frame = NSRect(x: c.maxX - 8 - btn, y: headerY + 5, width: btn, height: btn)
        collapseButton.frame = NSRect(x: closeButton.frame.minX - btn - 1, y: headerY + 5, width: btn, height: btn)
        modeButton.frame = NSRect(x: collapseButton.frame.minX - btn - 1, y: headerY + 5, width: btn, height: btn)
        pinButton.frame = NSRect(x: (note.collapsed ? collapseButton : modeButton).frame.minX - btn - 1,
                                 y: headerY + 5, width: btn, height: btn)
        titleField.frame = NSRect(x: left, y: headerY + 7, width: max(20, pinButton.frame.minX - 6 - left), height: 17)

        let footer = NotePanel.footerHeight
        editor.frame = NSRect(x: c.minX + 1, y: c.minY + footer,
                              width: c.width - 2, height: max(0, c.height - NotePanel.headerHeight - footer))

        // Footer, left to right: 🎨  >  then either the tags or the tools; the resize grip at the far right.
        let y = c.minY + 5
        appearanceButton.frame = NSRect(x: c.minX + 8, y: y, width: 22, height: 20)
        expandButton.frame = NSRect(x: appearanceButton.frame.maxX + 2, y: y, width: 18, height: 20)
        grip.frame = NSRect(x: c.maxX - 20, y: c.minY + 4, width: 16, height: 16)

        var x = expandButton.frame.maxX + 4
        if actionBarExpanded {
            for tool in [bulletButton, boldButton, italicButton, codeButton] {
                tool.frame = NSRect(x: x, y: y, width: 22, height: 20)
                x += 23
            }
            let sliderWidth = grip.frame.minX - 8 - (x + 4)
            opacitySlider.frame = NSRect(x: x + 4, y: c.minY + 7, width: max(0, sliderWidth), height: 16)
            opacitySlider.isHidden = sliderWidth < 36 || note.collapsed          // too narrow to use
        } else {
            tagsButton.frame = NSRect(x: x, y: y, width: 22, height: 20)
            tagsLabel.frame = NSRect(x: tagsButton.frame.maxX + 2, y: y + 2, width: max(0, grip.frame.minX - tagsButton.frame.maxX - 10), height: 16)
        }
    }

    // MARK: - Refresh from model

    /// The note changed underneath us (Appearance popover, hotkey, external edit).
    func refreshFromNote() {
        panel.alphaValue = note.opacity
        panel.applyPinned()
        applyColors()
        editor.pushSettings()
        needsLayout = true
        needsDisplay = true
    }

    @objc private func settingsChanged() {
        if !AppSettings.shared.actionBarAutoCollapse { cancelCollapseTimer() }
        applyColors()
        editor.pushSettings()
        needsDisplay = true
    }

    @objc private func bodyChanged(_ n: Notification) {
        if titleField.currentEditor() == nil { titleField.stringValue = note.title }
        refreshTagsButton()
    }

    @objc private func tagsMayHaveChanged() {
        refreshTagsButton()
        editor.pushTags()
    }

    // MARK: - Actions

    @objc func togglePin() {
        note.pinned.toggle()
        panel.applyPinned()
        refreshPinGlyph()
        VaultStore.shared.save(note)
        Toast.show(note.pinned ? "📌 Pinned on top" : "Unpinned")
    }

    @objc func toggleCollapse() {
        note.collapsed.toggle()
        panel.applyCollapsed(animated: true)
        VaultStore.shared.save(note)
    }

    @objc func toggleMode() { editor.toggleMode() }

    @objc func closeNote() {
        SaveCoordinator.shared.flush(noteID: note.id)
        note.visible = false
        VaultStore.shared.save(note)
        WindowManager.shared.close(noteID: note.id)
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
        Toast.show("Hidden · still in All Notes")
    }

    @objc func deleteNote() {
        WindowManager.shared.close(noteID: note.id)
        VaultStore.shared.delete(note)
        Toast.show("Moved to Trash")
    }

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
        updateActionBar()
        if actionBarExpanded { startCollapseTimer() } else { cancelCollapseTimer() }
    }

    @objc private func applyBullet() { editor.format("bullet"); keepBarOpen() }
    @objc private func applyBold() { editor.format("bold"); keepBarOpen() }
    @objc private func applyItalic() { editor.format("italic"); keepBarOpen() }
    @objc private func applyCode() { editor.format("code"); keepBarOpen() }

    @objc private func opacityChanged(_ slider: NSSlider) {
        note.opacity = min(1, max(0.3, (slider.doubleValue * 100).rounded() / 100))
        panel.alphaValue = note.opacity
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
            self.updateActionBar()
        }
    }

    private func cancelCollapseTimer() { collapseTimer?.invalidate(); collapseTimer = nil }

    private var footerRect: NSRect {
        NSRect(x: cardRect.minX, y: cardRect.minY, width: cardRect.width, height: NotePanel.footerHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let footerTracking { removeTrackingArea(footerTracking) }
        let area = NSTrackingArea(rect: footerRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        footerTracking = area
    }

    override func mouseEntered(with event: NSEvent) { cancelCollapseTimer() }
    override func mouseExited(with event: NSEvent) { startCollapseTimer() }

    @objc private func showAppearance() {
        let view = AppearancePopoverView(note: note) { [weak self] in
            guard let self else { return }
            VaultStore.shared.save(self.note)
            self.refreshFromNote()
        }
        present(view, from: appearanceButton)
    }

    @objc private func showTags() {
        let view = TagsPopoverView(note: note) { [weak self] in
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
        // Measure the SwiftUI content BEFORE showing. Shown unmeasured, the popover is placed for a
        // placeholder size and then shrinks in place, leaving it floating a couple of hundred points
        // away from the button it belongs to (found by measuring: 158 pt off).
        host.view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize

        let p = NSPopover()
        p.behavior = .transient
        p.animates = false
        p.contentViewController = host
        p.contentSize = size
        // AppKit picks the side with room (below the note when it can), always touching the button.
        p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover = p
    }

    // MARK: - Title editing

    /// Double-click the title to rename it. Until then the title is not editable, so a
    /// single click-drag moves the note. Enter commits and the title is solid again.
    private func beginRename() {
        guard !titleField.isRenaming else { return }
        panel.makeKeyAndOrderFront(nil)
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
        let text = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        endRename()
        if text.isEmpty { titleField.stringValue = note.title } else if text != note.title { editor.setTitle(text) }
        window?.makeFirstResponder(editor)
    }

    /// Esc abandons the rename.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        titleField.stringValue = note.title
        window?.makeFirstResponder(editor)
        return true
    }

    // MARK: - Resizing

    private func resizeBegan() {}

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if note.pinned && pinRect.contains(local) && !cardRect.contains(local) { togglePin(); return }
        // The header and any empty footer space drag the note; controls sit above and take their own clicks.
        guard headerRect.contains(local) || (footerRect.contains(local) && !note.collapsed) else {
            super.mouseDown(with: event); return
        }
        if note.pinned && pinRect.contains(local) { togglePin(); return }
        if event.clickCount == 2 && titleField.frame.contains(local) { dragOrigin = nil; beginRename(); return }
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let window else { super.mouseDragged(with: event); return }
        // Screen position of the pointer, from the event itself (not NSEvent.mouseLocation, which
        // is the real cursor and so cannot be driven by tests).
        let current = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: current.x - origin.x, y: current.y - origin.y))
    }

    override func mouseUp(with event: NSEvent) {
        if dragOrigin != nil {
            dragOrigin = nil
            panel.syncFrameToNote()
            VaultStore.shared.save(note)
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
        switch action {
        case .pin:        togglePin()
        case .collapse:   toggleCollapse()
        case .close:      closeNote()
        case .toggleMode: toggleMode()
        case .emoji:      openEmoji()
        case .lessOpaque: nudgeOpacity(by: -0.1)
        case .moreOpaque: nudgeOpacity(by: 0.1)
        case .color1, .color2, .color3, .color4, .color5, .color6:
            if let i = [ShortcutAction.color1, .color2, .color3, .color4, .color5, .color6].firstIndex(of: action) { setColor(index: i) }
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
        let h = max(minH + NotePanel.footerHeight + 40, startFrame.height + (startMouse.y - now.y))
        // The top-left corner stays put; the bottom-right follows the mouse.
        window.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - h, width: w, height: h), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        panel?.syncFrameToNote()
        if let note = panel?.note { VaultStore.shared.save(note) }
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
    var debugFooterEmptyPoint: NSPoint { NSPoint(x: cardRect.midX + 20, y: cardRect.minY + 12) }
    func debugShowTags() { showTags() }
    func debugClosePopover() { popover?.close() }
    var debugHasPopover: Bool { popover?.isShown == true }
}
#endif
