import SwiftUI
import AppKit

/// The look of PinTack's own window — All Notes and Settings, one window since 2026-09-21.
///
/// Owner decisions, the same day: dark means DARK — a deep indigo, the colour of an indigo note,
/// not the system's grey — and a selection is a solid bright sticky-note orange with dark lettering,
/// not orange washed out to brown over a dark background. Light mode keeps a warm paper tone.
///
/// Chrome never takes the user's note-outline colour (CLAUDE.md): a dark outline once made Settings
/// unreadable. Everything orange here is the fixed `Brand.accentNS`.
enum ChromeTheme {

    /// The selection fill, and lettering that reads on it.
    static let highlight = Brand.accentNS
    static let onHighlight = NSColor(white: 0.07, alpha: 1)

    static let window = dynamic(light: NSColor(srgbRed: 0.965, green: 0.953, blue: 0.937, alpha: 1),   // #F6F3EF
                                dark: NSColor(srgbRed: 0.078, green: 0.067, blue: 0.157, alpha: 1))    // #141128
    static let sidebar = dynamic(light: NSColor(srgbRed: 0.925, green: 0.910, blue: 0.890, alpha: 1),  // #ECE8E3
                                 dark: NSColor(srgbRed: 0.106, green: 0.090, blue: 0.204, alpha: 1))   // #1B1734
    /// Rows, fields and cards that sit on the window.
    static let surface = dynamic(light: NSColor(white: 1, alpha: 0.75),
                                 dark: NSColor(srgbRed: 0.157, green: 0.137, blue: 0.282, alpha: 1))   // #282348
    static let surfaceHover = dynamic(light: NSColor(white: 0, alpha: 0.05),
                                      dark: NSColor(white: 1, alpha: 0.06))
    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.08),
                                  dark: NSColor(white: 1, alpha: 0.08))

    /// A colour that follows the window's own light or dark appearance as it changes.
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

extension NSColor {
    /// This colour as it is drawn under a given appearance, for checks that need a number.
    func resolved(for name: NSAppearance.Name) -> NSColor {
        var out = self
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            out = self.usingColorSpace(.sRGB) ?? self
        }
        return out
    }
}

extension Color {
    static let chromeHighlight = Color(nsColor: ChromeTheme.highlight)
    static let chromeOnHighlight = Color(nsColor: ChromeTheme.onHighlight)
    static let chromeWindow = Color(nsColor: ChromeTheme.window)
    static let chromeSidebar = Color(nsColor: ChromeTheme.sidebar)
    static let chromeSurface = Color(nsColor: ChromeTheme.surface)
    static let chromeSurfaceHover = Color(nsColor: ChromeTheme.surfaceHover)
    static let chromeHairline = Color(nsColor: ChromeTheme.hairline)
}

/// The window's movement, one curve for all of it so tab switches, pane changes and selections feel
/// like parts of one thing. Lively on purpose (the owner wants springs, 2026-09-20); Reduce Motion
/// turns it into a plain fade.
enum ChromeMotion {
    static var spring: Animation {
        Motion.enabled ? .spring(response: 0.36, dampingFraction: 0.78) : .easeInOut(duration: 0.12)
    }
}

extension View {
    /// A settings Form on the window's own colour instead of the system's grouped grey.
    func chromeForm() -> some View {
        formStyle(.grouped).scrollContentBackground(.hidden)
    }
}

/// A row of glyph tabs with a solid orange pill that slides to the chosen one. Replaces the system
/// segmented control, whose selection on macOS is a grey that no tint reaches.
///
/// Its tooltips are its own, not the system's: a glyph on its own says little, so the owner wanted
/// these sooner (0.5 s, against 1 s everywhere else) and easier to see (2026-09-22). macOS has one
/// tooltip delay per app, so a faster one has to be drawn here.
struct GlyphTabs<Value: Hashable>: View {

    struct Item: Identifiable {
        let value: Value
        let symbol: String?       // an SF Symbol, or nil to show `text`
        let text: String
        let name: String
        let detail: String
        var id: String { name }
    }

    static var tipDelay: TimeInterval { 0.5 }

    @Binding var selection: Value
    let items: [Item]
    @Namespace private var pill
    @State private var hovered: Value?
    @State private var tipFor: Value?
    @State private var hoverToken = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let chosen = item.value == selection
                Button {
                    withAnimation(ChromeMotion.spring) { selection = item.value }
                } label: {
                    Group {
                        if let symbol = item.symbol {
                            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                        } else {
                            Text(item.text).font(.system(size: 15, weight: .bold))
                        }
                    }
                    .foregroundStyle(chosen ? Color.chromeOnHighlight : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background {
                        if chosen {
                            Capsule().fill(Color.chromeHighlight)
                                .matchedGeometryEffect(id: "pill", in: pill)
                                .shadow(color: Color.chromeHighlight.opacity(0.35), radius: 6, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in hover(inside ? item.value : nil, leaving: item.value) }
                // Anchored to the side it is nearest, so a tip under the first or last tab stays in
                // the sidebar instead of running off its edge.
                .overlay(alignment: index == 0 ? .topLeading : index == items.count - 1 ? .topTrailing : .top) {
                    if tipFor == item.value { bubble(item).offset(y: 36).allowsHitTesting(false) }
                }
                .zIndex(tipFor == item.value ? 1 : 0)
                .accessibilityLabel(item.name)
                .accessibilityHint(item.detail)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.chromeSurface))
    }

    /// Solid orange with near-black lettering, like every selection in this window: the name in bold
    /// on top, what it holds underneath.
    private func bubble(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name).font(.system(size: 12.5, weight: .bold))
            Text(item.detail).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.chromeOnHighlight)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(width: 180, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.chromeHighlight)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3))
        .transition(.opacity.combined(with: .offset(y: Motion.enabled ? -4 : 0)))
    }

    private func hover(_ value: Value?, leaving: Value) {
        if value == nil && hovered != leaving { return }       // a late exit from a tab already left
        hovered = value
        hoverToken += 1
        let token = hoverToken
        withAnimation(.easeOut(duration: 0.1)) { tipFor = nil }
        guard let value else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + GlyphTabs.tipDelay) {
            guard token == hoverToken, hovered == value else { return }
            withAnimation(.easeOut(duration: 0.14)) { tipFor = value }
        }
    }
}

/// A segmented choice with a solid orange pill and DARK lettering on it. The system segmented
/// control draws its chosen segment in the accent colour with white text, and no tint changes that
/// — white on bright orange was the unreadable highlight the owner reported (2026-09-21).
struct ChromeSegmented<Value: Hashable>: View {

    @Binding var selection: Value
    let options: [(label: String, value: Value)]
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let chosen = option.value == selection
                Button {
                    withAnimation(ChromeMotion.spring) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12.5, weight: chosen ? .semibold : .medium))
                        .foregroundStyle(chosen ? Color.chromeOnHighlight : Color.primary.opacity(0.8))
                        .padding(.horizontal, 12).frame(height: 24)
                        .background {
                            if chosen {
                                Capsule().fill(Color.chromeHighlight)
                                    .matchedGeometryEffect(id: "segment", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.chromeSurface))
        .fixedSize()
    }
}

/// The window's one prominent button, orange with dark lettering for the same reason.
struct ChromeProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.chromeOnHighlight)
            .padding(.horizontal, 14).frame(height: 28)
            .background(Capsule().fill(Color.chromeHighlight.opacity(configuration.isPressed ? 0.8 : 1)))
            .shadow(color: Color.chromeHighlight.opacity(0.3), radius: 6, y: 1)
            .scaleEffect(configuration.isPressed && Motion.enabled ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A settings row whose label and control share a centre line. The Form's own layout lines a label
/// up with the control's text baseline, and a pill control reports one that sits low, which left
/// "App theme" a few points above its own segments.
struct CentredRow: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
        }
    }
}
