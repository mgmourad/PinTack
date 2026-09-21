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
struct GlyphTabs<Value: Hashable>: View {

    struct Item: Identifiable {
        let value: Value
        let symbol: String?       // an SF Symbol, or nil to show `text`
        let text: String
        let help: String
        var id: String { help }
    }

    @Binding var selection: Value
    let items: [Item]
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
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
                .help(item.help)
                .accessibilityLabel(item.help)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.chromeSurface))
    }
}
