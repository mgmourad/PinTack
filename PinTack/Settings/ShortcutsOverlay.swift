import SwiftUI
import AppKit

/// The ⌥⌘/ shortcut list from the prototype: a centered dark card that closes on
/// Esc or when you click away. Reads the live bindings, so rebinding is reflected.
struct ShortcutsOverlayView: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Keyboard shortcuts").font(.system(size: 17, weight: .semibold))
            Text("Notes, Appearance and Windows shortcuts act on the focused note. New note, New todo, All Notes and Auto-arrange also work from any app.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 14)

            let groups = ["Notes", "Appearance", "Windows", "Data"]
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.uppercased()).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Color(nsColor: Brand.accentNS))
                        ForEach(ShortcutAction.allCases.filter { $0.group == group }, id: \.self) { a in
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                // ⌥⌘N set solid runs together at this size. Tracking separates the
                                // glyphs; the trailing gap it leaves is taken off the right padding.
                                Text(ShortcutStore.shared.combo(for: a).display)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .tracking(3)
                                    .padding(.leading, 7).padding(.trailing, 4).padding(.vertical, 2.5)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.1)))
                                Text(a.title).font(.system(size: 12.5))
                            }
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(26)
        .frame(width: 700, alignment: .leading)
    }
}

final class ShortcutsOverlay {

    static let shared = ShortcutsOverlay()

    private final class OverlayPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { close() }
        override func resignKey() { super.resignKey(); close() }
    }

    private var panel: NSPanel?

    func toggle() {
        if let panel, panel.isVisible { panel.close(); return }
        show()
    }

    func show() {
        let host = NSHostingView(rootView: ShortcutsOverlayView())
        let size = host.fittingSize
        let p = OverlayPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .modalPanel
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.appearance = NSAppearance(named: .vibrantDark)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 15
        host.frame = bg.bounds
        host.autoresizingMask = [.width, .height]
        bg.addSubview(host)
        p.contentView = bg

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2))
        }
        p.makeKeyAndOrderFront(nil)
        panel = p
    }
}
