import SwiftUI
import AppKit

/// The 🎨 footer popover: preset swatches, a custom color well, opacity with a
/// live percentage, and the per-note light/dark override. SPEC.md §5.3.
///
/// Color and opacity are set-and-forget, so they live behind one button instead of
/// six permanent footer controls that overlapped at the default width.
struct AppearancePopoverView: View {

    let note: Note
    let onChange: () -> Void

    @State private var colorHex: String
    @State private var opacity: Double
    @State private var theme: String
    @State private var custom: Color

    init(note: Note, onChange: @escaping () -> Void) {
        self.note = note
        self.onChange = onChange
        _colorHex = State(initialValue: note.colorHex)
        _opacity = State(initialValue: note.opacity)
        _theme = State(initialValue: note.theme)
        _custom = State(initialValue: Color(nsColor: note.color))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Color").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(NotePalette.presets, id: \.hex) { preset in
                    Circle()
                        .fill(Color(nsColor: NSColor(hex: preset.hex) ?? .yellow))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 1))
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: colorHex.uppercased() == preset.hex ? 2.5 : 0).padding(-3))
                        .help(preset.name)
                        .onTapGesture { apply(hex: preset.hex) }
                }
                ColorPicker("Custom", selection: $custom, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: custom) { _, new in apply(hex: NSColor(new).hexString) }
                    .help("Custom color…")
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

            VStack(alignment: .leading, spacing: 4) {
                Text("Text").font(.caption).foregroundStyle(.secondary)
                Picker("Text", selection: $theme) {
                    Text("Auto").tag("auto")
                    Text("Dark text").tag("light")     // a "light" note is light paper
                    Text("Light text").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: theme) { _, new in note.theme = new; onChange() }
            }
        }
        .padding(14)
        .frame(width: 248)
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

    init(note: Note, onChange: @escaping () -> Void) {
        self.note = note
        self.onChange = onChange
        _tags = State(initialValue: note.tags)
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
                FlowChips(items: tags) { tag in
                    tags.removeAll { $0 == tag }
                    commit()
                }
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

/// Chips that wrap onto new lines.
private struct FlowChips: View {
    let items: [String]
    let remove: (String) -> Void

    var body: some View {
        // A simple wrapping layout without the macOS 13+ Layout protocol boilerplate.
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { tag in
                        HStack(spacing: 3) {
                            Text("#\(tag)").font(.caption)
                            Button { remove(tag) } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    }
                }
            }
        }
    }
}
