import SwiftUI
import AppKit

/// The 🎨 footer popover: Auto / Dark / Light mode, the swatches for that mode, a custom
/// color well and opacity. SPEC.md §5.3.
///
/// Text color is deliberately not offered. It always flips light/dark from the chosen
/// color, so nothing a user picks can be unreadable. Dark and Light only change WHICH
/// swatches are shown (deeper or paler versions); a preset color carries across the switch.
struct AppearancePopoverView: View {

    let note: Note
    let onChange: () -> Void

    @State private var colorHex: String
    @State private var opacity: Double
    @State private var mode: String
    @State private var custom: Color

    init(note: Note, onChange: @escaping () -> Void) {
        self.note = note
        self.onChange = onChange
        _colorHex = State(initialValue: note.colorHex)
        _opacity = State(initialValue: note.opacity)
        _mode = State(initialValue: note.theme)
        _custom = State(initialValue: Color(nsColor: note.color))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Mode", selection: $mode) {
                Text("Auto").tag("auto")
                Text("Dark").tag("dark")
                Text("Light").tag("light")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: mode) { _, new in switchMode(to: new) }

            VStack(alignment: .leading, spacing: 6) {
                Text("Color").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(NotePalette.set(for: mode), id: \.hex) { swatch in
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: swatch.hex) ?? .yellow))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Color(nsColor: Brand.accentNS), lineWidth: colorHex.caseInsensitiveCompare(swatch.hex) == .orderedSame ? 2.5 : 0).padding(-3))
                            .help(swatch.name)
                            .onTapGesture { apply(hex: swatch.hex) }
                    }
                    ColorPicker("Custom", selection: $custom, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: custom) { _, new in
                            let hex = NSColor(new).hexString
                            if hex.caseInsensitiveCompare(colorHex) != .orderedSame { apply(hex: hex) }
                        }
                        .help("Custom color…")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Opacity").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((opacity * 100).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $opacity, in: 0.3...1.0)
                    .onChange(of: opacity) { _, new in note.opacity = new; onChange() }
            }
        }
        .padding(14)
        .frame(width: 248)
        .tint(Color(nsColor: Brand.accentNS))
    }

    private func switchMode(to new: String) {
        note.theme = new
        if let mapped = NotePalette.remap(note.colorHex, toMode: new) {
            note.colorHex = mapped
            colorHex = mapped
            custom = Color(nsColor: NSColor(hex: mapped) ?? .yellow)
        }
        onChange()
    }

    private func apply(hex: String) {
        colorHex = hex
        note.colorHex = hex
        onChange()
    }
}

/// The 🏷 footer popover: current tags as removable chips, an input with
/// autocomplete against existing vault tags. SPEC.md §3.5, §5.3.
struct TagsPopoverView: View {

    let note: Note
    let onChange: () -> Void

    @State private var tags: [String]
    @State private var input = ""
    /// The tag whose colour dot was clicked, showing the swatches under the chips. nil: closed.
    @State private var colouring: String?
    /// Bumped when a colour changes, so the chips redraw in it at once.
    @State private var colourVersion = 0

    /// `colouring` opens a tag's swatches straight away. The self-test uses it, because a click
    /// on a SwiftUI button is not something it can make.
    init(note: Note, colouring: String? = nil, onChange: @escaping () -> Void) {
        self.note = note
        self.onChange = onChange
        _tags = State(initialValue: note.tags)
        _colouring = State(initialValue: colouring)
    }

    private var suggestions: [String] {
        let typed = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        return VaultStore.shared.tagCounts().map(\.tag)
            .filter { t in !tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame } }
            .filter { typed.isEmpty || $0.lowercased().hasPrefix(typed) }
            .prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags").font(.caption).foregroundStyle(.secondary)

            if !tags.isEmpty {
                FlowChips(items: tags, colouring: colouring, version: colourVersion,
                          pickColour: { tag in withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                              colouring = colouring == tag ? nil : tag } },
                          remove: { tag in
                              tags.removeAll { $0 == tag }
                              if colouring == tag { colouring = nil }
                              commit()
                          })
            }

            if let tag = colouring {
                TagColourSwatches(tag: tag) { colourVersion += 1 }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            TextField("Add tag…", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add(input) }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { add(s) } label: {
                            Text("#\(s)").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 240)
        .tint(Color(nsColor: Brand.accentNS))
    }

    private func add(_ raw: String) {
        // Tags are stored as typed, without the leading #; nested with "/". SPEC.md §3.5.
        let clean = raw.trimmingCharacters(in: CharacterSet(charactersIn: "# ,")).replacingOccurrences(of: " ", with: "-")
        guard !clean.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { input = ""; return }
        tags.append(clean)
        input = ""
        commit()
    }

    private func commit() {
        note.tags = tags
        onChange()
    }
}

/// The note's tags as chips, each in the tag's own colour with a dot that opens its swatches.
private struct FlowChips: View {
    let items: [String]
    let colouring: String?
    let version: Int                     // read so the chips redraw when a colour changes
    let pickColour: (String) -> Void
    let remove: (String) -> Void

    var body: some View {
        let _ = version
        ChipFlow(spacing: 4) {
            ForEach(items, id: \.self) { tag in
                let ink = Color(nsColor: TagPillsView.textColor(for: tag))
                HStack(spacing: 4) {
                    Button { pickColour(tag) } label: {
                        Circle().strokeBorder(ink.opacity(0.55), lineWidth: 1)
                            .background(Circle().fill(ink.opacity(colouring == tag ? 0.35 : 0.12)))
                            .frame(width: 10, height: 10)
                    }
                    .buttonStyle(.plain)
                    .help("Change this tag's colour")
                    Text("#\(tag)").font(.caption.weight(.semibold)).foregroundStyle(ink)
                        .lineLimit(1).fixedSize()
                    Button { remove(tag) } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(ink.opacity(0.6))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color(nsColor: TagPillsView.color(for: tag))))
            }
        }
    }
}

/// Lays chips out left to right and wraps them onto a new line when the next would not fit —
/// never breaking a chip's text, which a fixed three-to-a-row grid did once chips grew a dot.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return arrange(subviews, width: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, origin) in zip(subviews, arrange(subviews, width: bounds.width).origins) {
            view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + lineHeight))
    }
}

/// A tag's colour choices: Automatic, a row of presets, and a custom colour. It changes the tag
/// everywhere at once, because a colour is a property of the tag, not of the note.
private struct TagColourSwatches: View {
    let tag: String
    let changed: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var custom = Color.orange

    /// Soft enough for the pills' usual look, strong enough to tell apart at a glance.
    static let presets = ["#FF8A80", "#FFB74D", "#FFE066", "#9BE38B", "#6FD6C4",
                          "#7FB8FF", "#B39DFF", "#FF9ACD", "#C9CCD1", "#3A3F4B"]

    private var key: String { tag.lowercased() }
    private var chosen: String? { settings.tagColors[key] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Colour of #\(tag)").font(.caption2).foregroundStyle(.secondary)
            // Flows onto a second line rather than pushing the whole popover sideways.
            ChipFlow(spacing: 6) {
                swatch(nil)
                ForEach(Self.presets, id: \.self) { swatch($0) }
                ColorPicker("", selection: $custom, supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: custom) { _, new in set(NSColor(new).hexString) }
                    .help("Any colour")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }

    /// nil is Automatic: the colour from the tag's name, drawn so it can be recognised as such.
    @ViewBuilder private func swatch(_ hex: String?) -> some View {
        let fill = hex.flatMap { NSColor(hex: $0) } ?? TagPillsView.automaticColor(for: tag)
        let isChosen = chosen?.caseInsensitiveCompare(hex ?? "") == .orderedSame || (hex == nil && chosen == nil)
        Button { set(hex) } label: {
            ZStack {
                Circle().fill(Color(nsColor: fill))
                if hex == nil { Text("A").font(.system(size: 8, weight: .bold)).foregroundStyle(.black.opacity(0.6)) }
            }
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(Color.primary.opacity(isChosen ? 0.85 : 0.15), lineWidth: isChosen ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(hex == nil ? "Automatic, from the tag's name" : hex!)
    }

    private func set(_ hex: String?) {
        if let hex { settings.tagColors[key] = hex } else { settings.tagColors[key] = nil }
        changed()
    }
}
