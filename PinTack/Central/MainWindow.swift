import SwiftUI
import AppKit

/// All Notes and Settings, one window with a tab each (owner decision, 2026-09-21). They used to be
/// two windows that each needed finding. `AllNotesWindowController` and `SettingsWindowController`
/// still exist, unchanged on the outside, and now just pick a tab here — so every shortcut, menu
/// item and the All Notes gear keeps working exactly as it did.
final class MainWindowModel: ObservableObject {

    enum Tab: String, CaseIterable, Identifiable {
        case allNotes = "All Notes", settings = "Settings"
        var id: String { rawValue }
        var symbol: String { self == .allNotes ? "square.stack.3d.up.fill" : "gearshape.fill" }
    }

    static let shared = MainWindowModel()

    @Published var tab: Tab = .allNotes
    /// Kept here rather than inside SettingsView, so leaving for All Notes and coming back finds
    /// the same pane.
    @Published var settingsPane: SettingsView.Pane = SettingsView.initialPane
}

struct MainWindowView: View {

    @ObservedObject private var model = MainWindowModel.shared
    @Namespace private var tabPill

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().fill(Color.chromeHairline).frame(height: 1)
            // Both tabs stay alive underneath, so a search typed in All Notes or a Settings pane is
            // still there on the way back; only the one in front takes clicks.
            ZStack {
                page(.allNotes) { AllNotesView() }
                page(.settings) { SettingsView() }
            }
        }
        .background(Color.chromeWindow)
        .frame(minWidth: 880, minHeight: 560)
        .tint(Color.chromeHighlight)
    }

    /// The two tabs, centred in the title bar next to the traffic lights, as in the owner's sketch.
    private var tabBar: some View {
        HStack(spacing: 10) {
            ForEach(MainWindowModel.Tab.allCases) { tab in
                let chosen = tab == model.tab
                Button {
                    withAnimation(ChromeMotion.spring) { model.tab = tab }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab.symbol).font(.system(size: 14, weight: .semibold))
                        Text(tab.rawValue).font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(chosen ? Color.chromeOnHighlight : Color.primary.opacity(0.75))
                    .padding(.horizontal, 22).frame(height: 34)
                    .background {
                        if chosen {
                            Capsule().fill(Color.chromeHighlight)
                                .matchedGeometryEffect(id: "tab", in: tabPill)
                                .shadow(color: Color.chromeHighlight.opacity(0.4), radius: 10, y: 2)
                        } else {
                            Capsule().strokeBorder(Color.chromeHairline, lineWidth: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .padding(.top, 4)
    }

    private func page<Content: View>(_ tab: MainWindowModel.Tab, @ViewBuilder content: () -> Content) -> some View {
        let shown = model.tab == tab
        // Slides a little towards the side its tab is on, and fades, so the switch has a direction.
        let side: CGFloat = tab == .allNotes ? -1 : 1
        return content()
            .opacity(shown ? 1 : 0)
            .offset(x: shown || !Motion.enabled ? 0 : 28 * side)
            .scaleEffect(shown || !Motion.enabled ? 1 : 0.985)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            .animation(ChromeMotion.spring, value: model.tab)
    }
}

final class MainWindowController {

    static let shared = MainWindowController()
    private(set) var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }
    var tab: MainWindowModel.Tab { MainWindowModel.shared.tab }

    func show(_ tab: MainWindowModel.Tab) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "PinTack"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            // The tab bar lives in the title bar, so its empty space has to drag the window.
            w.isMovableByWindowBackground = true
            w.backgroundColor = ChromeTheme.window
            w.contentViewController = NSHostingController(rootView: MainWindowView())
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 960, height: 640))
            w.setFrameAutosaveName("PinTackMainWindow")
            if !w.setFrameUsingName("PinTackMainWindow") { w.center() }
            window = w
        }
        if MainWindowModel.shared.tab != tab {
            // Switched WITHOUT animation. This path is a shortcut or a menu, often pressed while
            // another app is in front, and SwiftUI animations do not advance in an app that is not
            // the active one: an animated switch here left the window drawing the old tab while the
            // model said the new one (seen in the self-test, 2026-09-21). Clicks on the tabs, which
            // can only happen with the app active, still animate.
            withAnimation(ChromeMotion.spring) { MainWindowModel.shared.tab = tab }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}
