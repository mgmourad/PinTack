import AppKit

/// The note's tags in the action bar, drawn as coloured pills. SPEC.md §5.3.
///
/// The colour is derived from the tag text, never chosen by the user: the same tag then looks the
/// same in every note and after a relaunch, without storing anything.
///
/// Pills WRAP onto as many lines as the view is tall — which is however many rows the task tracker
/// has already given the action bar (owner decision, 2026-09-20). Tags never make the bar taller
/// themselves: once the lines they have are full, the rest collapse into a "+N" pill.
final class TagPillsView: NSView {

    var tags: [String] = [] { didSet { if tags != oldValue { needsDisplay = true } } }
    /// The note's automatic text colour, used for the "+N" overflow pill.
    var foreground: NSColor = .black { didSet { needsDisplay = true } }
    /// Called when the "+N" pill is clicked, to show the ones that did not fit.
    var onOverflowClick: ((NSRect) -> Void)?

    /// Where the "+N" pill is, or .zero when every tag fitted. Set during drawing.
    private(set) var overflowRect: NSRect = .zero

    private static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let padding: CGFloat = 5
    private static let gap: CGFloat = 3
    static let lineHeight: CGFloat = 15
    private static let lineGap: CGFloat = 3

    override var isFlipped: Bool { true }

    /// Transparent to the mouse so the empty part of the action bar still drags the note, and tags
    /// are edited only from the tag icon (an owner decision, 2026-09-19) — with ONE exception: the
    /// "+N" pill takes its own clicks, or there is no way to see the tags it is standing in for
    /// short of making the note wider.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !overflowRect.isEmpty, let parent = superview else { return nil }
        return overflowRect.contains(convert(point, from: parent)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard !overflowRect.isEmpty else { return }
        onOverflowClick?(convert(overflowRect, to: nil))
    }

    override func resetCursorRects() {
        guard !overflowRect.isEmpty else { return }
        addCursorRect(overflowRect, cursor: .pointingHand)
    }

    /// Drawn, not built from controls. Without this VoiceOver finds no tags on the note at all.
    override func isAccessibilityElement() -> Bool { !tags.isEmpty }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? {
        tags.isEmpty ? nil : "Tags: " + tags.joined(separator: ", ")
    }

    /// A tag's colour: the one the user picked for it (the tag editor, 2026-09-21), otherwise the
    /// automatic one from its name.
    static func color(for tag: String) -> NSColor {
        if let hex = AppSettings.shared.tagColors[tag.lowercased()], let picked = NSColor(hex: hex) { return picked }
        return automaticColor(for: tag)
    }

    /// Lettering that reads on the pill. Automatic colours are always washed out to take dark text;
    /// a picked colour can be anything, so it is decided by how light that colour is.
    static func textColor(for tag: String) -> NSColor {
        color(for: tag).relativeLuminance < 0.45 ? .white : .black
    }

    /// The colour from a stable hash of the tag's text. NOT `hashValue`: Swift seeds its hasher per
    /// process, so every launch would repaint the same tag a different colour.
    static func automaticColor(for tag: String) -> NSColor {
        var hash: UInt64 = 5381
        for byte in tag.lowercased().utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let hue = CGFloat(hash % 360) / 360.0
        var saturation: CGFloat = 0.46
        var color = NSColor(hue: hue, saturation: saturation, brightness: 0.95, alpha: 1)
        // Blues and purples come out much darker than yellows at the same saturation. Wash them
        // out until every pill is light enough for dark text, the same rule note colours follow
        // (NotePalette.randomPastel), so pills never mix black and white lettering.
        while color.relativeLuminance < 0.5 && saturation > 0.08 {
            saturation *= 0.88
            color = NSColor(hue: hue, saturation: saturation, brightness: 0.95, alpha: 1)
        }
        return color
    }

    private static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + padding * 2
    }

    /// Lines of pills this view has room for. One at the usual footer height; more once the task
    /// tracker has made the action bar taller.
    private var lineCount: Int {
        let step = TagPillsView.lineHeight + TagPillsView.lineGap
        return max(1, Int((bounds.height + TagPillsView.lineGap) / step))
    }

    /// Where every pill goes, and whether an overflow pill is needed. Laid out BEFORE anything is
    /// drawn: the "+N" has to take the place of pills that were already positioned, which cannot be
    /// undone once they are on screen.
    private func layoutPills() -> (pills: [(tag: String, rect: NSRect)], overflow: NSRect) {
        guard !tags.isEmpty, bounds.width > 0 else { return ([], .zero) }
        let lines = lineCount

        /// Places `texts` left to right, wrapping, and returns nil the moment one does not fit.
        func place(_ texts: [String]) -> [NSRect]? {
            var rects: [NSRect] = []
            var line = 0
            var x: CGFloat = 0
            for text in texts {
                let width = TagPillsView.width(of: text)
                if x > 0 && x + width > bounds.width {
                    line += 1
                    x = 0
                }
                guard line < lines, x + width <= bounds.width else { return nil }
                rects.append(NSRect(x: x, y: CGFloat(line) * (TagPillsView.lineHeight + TagPillsView.lineGap),
                                    width: width, height: TagPillsView.lineHeight))
                x += width + TagPillsView.gap
            }
            return rects
        }

        if let rects = place(tags.map { "#" + $0 }) {
            return (zip(tags, rects).map { (tag: $0.0, rect: $0.1) }, .zero)
        }
        // Not all of them fit. Show as many as can share the space with a "+N" that stands for the
        // rest, dropping one more each time until the whole arrangement fits.
        for shown in stride(from: tags.count - 1, through: 0, by: -1) {
            let texts = tags.prefix(shown).map { "#" + $0 } + ["+\(tags.count - shown)"]
            guard let rects = place(Array(texts)) else { continue }
            return (zip(tags.prefix(shown), rects).map { (tag: $0.0, rect: $0.1) }, rects[shown])
        }
        return ([], .zero)
    }

    override func draw(_ dirtyRect: NSRect) {
        let previousOverflow = overflowRect
        let (pills, overflow) = layoutPills()
        overflowRect = overflow

        for pill in pills {
            draw("#" + pill.tag, at: pill.rect, background: TagPillsView.color(for: pill.tag),
                 text: TagPillsView.textColor(for: pill.tag))
        }
        if !overflow.isEmpty {
            draw("+\(tags.count - pills.count)", at: overflow,
                 background: foreground.withAlphaComponent(0.18), text: foreground.withAlphaComponent(0.85))
        }
        if previousOverflow != overflowRect { window?.invalidateCursorRects(for: self) }
    }

#if DEBUG
    /// Lines of pills the bar's current thickness allows, and where the pills actually landed.
    var debugLineCount: Int { lineCount }
    var debugPillRects: [NSRect] { layoutPills().pills.map(\.rect) }
#endif

    private func draw(_ text: String, at rect: NSRect, background: NSColor, text textColor: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        background.setFill()
        path.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: TagPillsView.font,
            .foregroundColor: textColor.withAlphaComponent(0.92),
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: rect.minX + TagPillsView.padding,
                                            y: rect.midY - size.height / 2),
                                withAttributes: attributes)
    }
}
