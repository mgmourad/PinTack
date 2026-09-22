import SwiftUI
import AppKit

/// The card shown the first time PinTack runs, and never again. SPEC.md §3.0.
///
/// One screen, no pages, no "next": everything a new user needs to know is on it at once and OK
/// puts it away. It reads the LIVE shortcut bindings, so a rebound key is never shown wrong.
/// What the card says, kept apart from how it looks so the self-test can read the words. SwiftUI
/// puts none of its own views into the accessibility tree an NSView hands out, so text checked only
/// through the rendered card would be text nobody could check at all.
enum OnboardingContent {

    struct Feature: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let detail: String
    }

    static let title = "Welcome to PinTack"
    static let subtitle = "Sticky notes that live on your desktop and nowhere else."
    static let footnote = "Everything is yours to change in Settings (⌘,). This screen appears only once."
    static let dismiss = "OK"
    /// The way back to the longer version, and the same button All Notes carries (owner, 2026-09-22).
    static let tutorial = "Show Tutorial"

    /// The four shortcuts worth knowing on day one. Displayed from the LIVE bindings, so a
    /// rebound key is never shown wrong.
    static let shortcuts: [ShortcutAction] = [.newNote, .newTodo, .toggleAllNotes, .showShortcuts]

    static let features: [Feature] = [
        Feature(symbol: "doc.plaintext",
                title: "Plain Markdown, always",
                detail: "Every note is a .md file in ~/Documents/PinTack. Edit it in any app; PinTack keeps up."),
        Feature(symbol: "slash.circle",
                title: "Type / for anything",
                detail: "Headings, tables, code, colours, checklists. @ recalls a template you saved earlier."),
        Feature(symbol: "pin.fill",
                title: "It stays where you put it",
                detail: "Pin a note above every window, collapse it to its title, or freeze it so clicks pass through."),
        Feature(symbol: "checklist",
                title: "Todos that remind you",
                detail: "Tag a note todo for progress squares in its bar and a due date that travels with the file."),
        Feature(symbol: "magnifyingglass",
                title: "Find it in a second",
                detail: "Full-text search, folders, tags and templates in All Notes. /find jumps from inside a note."),
        Feature(symbol: "puzzlepiece.extension.fill",
                title: "Yours to extend",
                detail: "JavaScript plugins, each one asking your permission before it is allowed to do anything."),
    ]
}

struct OnboardingView: View {

    var onDismiss: () -> Void

    private var accent: Color { Color(nsColor: Brand.accentNS) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12)).padding(.vertical, 22)
            grid
            shortcutStrip
            footer
        }
        .padding(.horizontal, 34)
        .padding(.top, 34)
        .padding(.bottom, 26)
        .frame(width: 760)
        // The app's own dark indigo (owner, 2026-09-22), the same as the PinTack window and the
        // tutorial, instead of the system's grey HUD material.
        .background(OnboardingView.chrome)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.09)))
        .foregroundStyle(.white.opacity(0.92))
    }

    /// Shared with the tutorial: deep indigo, with a soft orange bloom behind the icon.
    static var chrome: some View {
        ZStack {
            Color.chromeWindow
            RadialGradient(colors: [Color(nsColor: Brand.accentNS).opacity(0.18), .clear],
                           center: .init(x: 0.5, y: 0.12), startRadius: 8, endRadius: 520)
            LinearGradient(colors: [.white.opacity(0.05), .clear], startPoint: .top, endPoint: .center)
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: 12) {
            if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable().interpolation(.high)
                    .frame(width: 88, height: 88)
                    // A soft halo in the app's own orange, so the icon sits on the dark card
                    // rather than floating on it.
                    .shadow(color: accent.opacity(0.45), radius: 26)
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            }
            Text(OnboardingContent.title)
                .font(.system(size: 30, weight: .bold))
            Text(OnboardingContent.subtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.62))
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                            GridItem(.flexible(), spacing: 14)],
                  spacing: 14) {
            ForEach(OnboardingContent.features) { feature in
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.16)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(feature.title).font(.system(size: 13, weight: .semibold))
                        Text(feature.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(13)
                // Both tiles on a row take the height of the taller one; without this the shorter
                // of a pair floats in a half-height box and the grid reads as ragged.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
                )
            }
        }
    }

    private var shortcutStrip: some View {
        HStack(spacing: 22) {
            ForEach(OnboardingContent.shortcuts, id: \.self) { action in
                HStack(spacing: 8) {
                    // ⌥⌘N set solid runs together at this size; tracking separates the glyphs and
                    // the trailing gap it leaves comes off the right padding. Same as ⌥⌘/.
                    Text(ShortcutStore.shared.combo(for: action).display)
                        .font(.system(size: 11.5, design: .monospaced))
                        .tracking(3)
                        .padding(.leading, 7).padding(.trailing, 4).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.1)))
                    Text(action.title).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(.top, 22)
    }

    private var footer: some View {
        HStack(alignment: .center) {
            Text(OnboardingContent.footnote)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 20)
            Button {
                onDismiss()
                TutorialWindow.show()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "graduationcap.fill").font(.system(size: 12.5, weight: .semibold))
                    Text(OnboardingContent.tutorial).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(accent)
                .padding(.horizontal, 16).frame(height: 32)
                .background(Capsule().fill(accent.opacity(0.15))
                    .overlay(Capsule().strokeBorder(accent.opacity(0.4))))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .accessibilityLabel(OnboardingContent.tutorial)
            Button(action: onDismiss) {
                Text(OnboardingContent.dismiss)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(width: 96, height: 32)
                    .background(Capsule().fill(accent))
                    .shadow(color: accent.opacity(0.4), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(OnboardingContent.dismiss)
        }
        .padding(.top, 24)
    }
}

// MARK: - Window

/// Shows `OnboardingView` once, the first time the app is ever run.
///
/// "Once" is a marker file beside the vault's other metadata, the same way the welcome note is
/// remembered — a preference would come back the moment someone reset defaults, and the vault is
/// what the app treats as its own state.
enum OnboardingWindow {

    /// Its own class only so Escape can dismiss it. It deliberately does NOT close on losing focus,
    /// the way the ⌥⌘/ overlay does: this one is read, and a stray click must not lose it.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { OnboardingWindow.dismiss() }
    }

    private static var panel: NSPanel?

    private static var markerURL: URL {
        VaultStore.shared.metaURL.appendingPathComponent("onboarded")
    }

    static var hasRunBefore: Bool { FileManager.default.fileExists(atPath: markerURL.path) }

    /// The app's own entry point, called at launch. Does nothing on every run after the first.
    static func showIfFirstRun() {
        guard !hasRunBefore else { return }
        // Written when it is SHOWN, not when it is dismissed: a crash or a force-quit before OK
        // must not mean the user is greeted all over again on every launch.
        try? Data().write(to: markerURL)
        show()
    }

    static func show() {
        if let panel, panel.isVisible { panel.makeKeyAndOrderFront(nil); return }

        let host = NSHostingView(rootView: OnboardingView(onDismiss: { dismiss() }))
        let size = host.fittingSize
        let p = Panel(contentRect: NSRect(origin: .zero, size: size),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .modalPanel
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The card paints its own background now, so no material behind it.
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        Motion.appear(window: p, content: host, to: 1)
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    static func dismiss() {
        panel?.close()
        panel = nil
    }

    static var isShowing: Bool { panel?.isVisible == true }

    #if DEBUG
    /// The self-test reads the card's own text and photographs it.
    static var panelForTesting: NSWindow? { panel }
    #endif
}
