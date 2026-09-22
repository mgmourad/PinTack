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
        var symbol: String { self == .allNotes ? "note.text" : "gearshape.fill" }   // All Notes draws its own asset
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

    /// All Notes has the owner's own sticky-pad glyph (2026-09-22): the stack glyph it used to share
    /// is the Stacks tab's inside All Notes. A template image, so it takes the tab's colour exactly
    /// like the gear beside it.
    @ViewBuilder private func tabIcon(_ tab: MainWindowModel.Tab) -> some View {
        if tab == .allNotes {
            Image("AllNotesTab").renderingMode(.template).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit).frame(width: 16, height: 16)
        } else {
            Image(systemName: tab.symbol).font(.system(size: 14, weight: .semibold))
        }
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
                        tabIcon(tab)
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
                .tip(tab.rawValue, tab == .allNotes ? "Every note, todo, template and stack" : "How PinTack looks and behaves")
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
        // No `.animation(_:value:)` here. That fired on EVERY tab change, including one made while the
        // window was closed, where the animation is never driven: the model said Settings and the
        // window still drew All Notes (caught by the self-test, 2026-09-21). Animation comes only
        // from an explicit withAnimation — a tab clicked, with the window on screen.
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
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if MainWindowModel.shared.tab != tab {
            // A shortcut or menu switches the tab instantly, since the window may only just be
            // coming forward; a click on a tab is what springs.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { MainWindowModel.shared.tab = tab }
            // And once more on the next turn of the run loop. A change that lands while SwiftUI is
            // part-way through another update (a setting changed just before) can be dropped: the
            // model said Settings and the window drew All Notes until something else redrew it.
            // Measured in the self-test, 2026-09-21; this nudge is what fixed it.
            DispatchQueue.main.async { MainWindowModel.shared.objectWillChange.send() }
        }
    }

    func close() { window?.close() }
}
