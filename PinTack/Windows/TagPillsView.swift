import AppKit

/// The note's tags in the action bar, drawn as coloured pills. SPEC.md §5.3.
///
/// The colour is derived from the tag text, never chosen by the user: the same tag then looks the
/// same in every note and after a relaunch, without storing anything. Tags that do not fit collapse
/// into a "+N" pill.
final class TagPillsView: NSView {

    var tags: [String] = [] { didSet { if tags != oldValue { needsDisplay = true } } }
    /// The note's automatic text colour, used for the "+N" overflow pill.
    var foreground: NSColor = .black { didSet { needsDisplay = true } }
    /// Called when the "+N" pill is clicked, to show the ones that did not fit.
    var onOverflowClick: ((NSRect) -> Void)?

    /// Where the "+N" pill is, or .zero when every tag fitted. Set during drawing.
    private(set) var overflowRect: NSRect = .zero

    private static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let padding: CGFloat = 6
    private static let gap: CGFloat = 4

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

    /// A tag's colour, from a stable hash of its text. NOT `hashValue`: Swift seeds its hasher per
    /// process, so every launch would repaint the same tag a different colour.
    static func color(for tag: String) -> NSColor {
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

    override func draw(_ dirtyRect: NSRect) {
        overflowRect = .zero
        guard !tags.isEmpty else { return }
        let height = min(bounds.height, 15)
        let y = ((bounds.height - height) / 2).rounded()
        var x: CGFloat = 0

        for (index, tag) in tags.enumerated() {
            let text = "#" + tag
            let pillWidth = TagPillsView.width(of: text)
            // Does this pill fit, and if it is not the last one, does a "+N" still fit after it?
            let remaining = tags.count - index
            let overflow = "+\(remaining)"
            let overflowWidth = TagPillsView.width(of: overflow)
            let needsRoom = index == tags.count - 1 ? pillWidth : pillWidth + TagPillsView.gap + overflowWidth
            if x + needsRoom > bounds.width {
                if x + overflowWidth <= bounds.width {
                    overflowRect = NSRect(x: x, y: y, width: overflowWidth, height: height)
                    draw(overflow, at: overflowRect,
                         background: foreground.withAlphaComponent(0.18), text: foreground.withAlphaComponent(0.85))
                    window?.invalidateCursorRects(for: self)
                }
                return
            }
            // Every pill is washed out to take dark text, so the lettering never switches colour.
            draw(text, at: NSRect(x: x, y: y, width: pillWidth, height: height),
                 background: TagPillsView.color(for: tag), text: .black)
            x += pillWidth + TagPillsView.gap
        }
    }

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
