import SwiftUI
import QuartzCore
import AppKit

/// The Tutorial | Help presentation (owner, 2026-09-22). SPEC.md §8.4.
///
/// One slide per feature, each with a REAL screenshot of that feature in use — the pictures are made
/// by `scripts/make-tutorial-shots.sh`, which drives the app itself, so a slide can never show a
/// version of PinTack that no longer exists. Slides advance themselves every 5 seconds until the
/// reader takes over with ‹ or ›, and then stay where they are put.
///
/// The words live apart from the view, as the onboarding card's do: SwiftUI puts none of its own
/// views into the accessibility tree an NSView hands out, so text only inside the view is text no
/// test can read.
enum TutorialContent {

    struct Slide: Identifiable {
        let image: String
        let title: String
        let detail: String
        /// A shortcut worth knowing on this slide, shown as a key cap. Read live, never hard-coded.
        let shortcut: ShortcutAction?
        /// Shown in place of a shortcut when the feature is reached some other way.
        let hint: String?
        var id: String { image }

        init(_ image: String, _ title: String, _ detail: String, shortcut: ShortcutAction? = nil, hint: String? = nil) {
            self.image = image; self.title = title; self.detail = detail; self.shortcut = shortcut; self.hint = hint
        }
    }

    static let title = "Tutorial"
    static let subtitle = "Everything PinTack can do, one thing at a time."
    static let dismiss = "OK"
    static let autoAdvance: TimeInterval = 5

    /// The pictures ship as a folder of PNGs rather than an asset catalog, because
    /// `scripts/make-tutorial-shots.sh` writes them straight into it.
    static func picture(_ name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Tutorial")
            ?? Bundle.main.url(forResource: name, withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return NSImage(named: name)
    }

    static let slides: [Slide] = [
        Slide("live-preview", "Notes that write themselves neatly",
              "Type Markdown and it renders as you go — bold, lists, quotes, `code`. The line you are on shows its raw text, so nothing is ever hidden from you. Every note is a plain .md file in your vault.",
              shortcut: .newNote),
        Slide("slash-menu", "Type / for anything",
              "Headings, tables, checklists, code blocks, colours, a divider, today's date. Keep typing to filter the list, Return to insert. Type @ instead and you get your templates.",
              hint: "Type / in any note"),
        Slide("code", "Code that looks like code",
              "Fenced blocks get syntax colours, the language's own logo, and a dark panel of their own on any colour of note. Every language CodeMirror ships is there; each one loads only when a note actually uses it.",
              hint: "Type ``` or /code"),
        Slide("todo", "Todos that keep count",
              "Tag a note todo and its action bar grows progress squares and a count. Add a due date and a reminder, and both travel inside the file. ⌘↩ ticks the line you are on.",
              shortcut: .newTodo),
        Slide("pin", "It stays exactly where you put it",
              "Pin a note above every other window and it takes the pushpin and a glow in its own colour. Collapse it to its title bar, fade it until you reach for it, or freeze it so clicks pass straight through to what is underneath.",
              shortcut: .pin),
        Slide("stack", "Stacks: a tidy desk in one click",
              "The paperclip piles 2 to 5 open notes into one, every title bar showing. Click any title bar to bring that note forward, ⌘1–⌘5 to jump, ⌥Tab to walk the pile. Unstack puts every note back exactly where it was.",
              hint: "Paperclip in the title bar, or /stack"),
        Slide("vim", "Vim keys, if you want them",
              "Turn vim mode on and every note takes vim's keys, with a line-number gutter and : and / opening a command bar in the action bar. A table folds to one line — 3 [+4] — so j and k never wander through it.",
              hint: "Settings → Editor → Vim mode"),
        Slide("tags", "Tags, colours and contrast",
              "Type #tag anywhere and it becomes a pill in the action bar, coloured from its own name or from a colour you pick. Note colours are yours; the text flips light or dark by itself so nothing is ever unreadable.",
              hint: "Type #tag, or the tag icon"),
        Slide("all-notes", "Every note, in one window",
              "Folders, tags, full-text search and a row for every note, each with show, rename and delete. Drag notes onto a folder, pick several to file or bin at once, and export the lot as JSON whenever you like.",
              shortcut: .toggleAllNotes),
        Slide("stacks-tab", "Your stacks, listed",
              "The Stacks tab lists every pile: what is in it, in order, and buttons to show, rename, unstack or delete it. Deleting a stack always asks first, and Return keeps every note by unstacking instead.",
              shortcut: .toggleAllNotes),
        Slide("todos-tab", "Everything still to do",
              "The Todos tab gathers every todo note with its progress and due date, sorted by what is most done, least done or due next. Pick several and mark them complete, or bin them, in one go.",
              shortcut: .showTodos),
        Slide("settings", "Make it yours",
              "Note colour, outline, glow, opacity, font, where new notes land, how quickly they save, the editor's every habit, and a rebindable key for every action. Plugins get their own section, and a permission for everything they touch.",
              hint: "⌘, or the gear in All Notes"),
    ]
}

#if DEBUG
/// What the self-test measures about the tutorial's cost: how often the page rebuilds, and how long
/// a step of a drag takes. A choppy drag is a number, not an impression (owner, 2026-09-26).
enum TutorialProbe {
    static var bodyEvaluations = 0

    /// Frame intervals straight from the window's own display link, so what is measured is what the
    /// screen did, not what the app intended. It reports when a frame was DUE, which is why the
    /// processor time spent on a transition is measured beside it.
    final class FrameMeter: NSObject {
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private(set) var intervals: [Double] = []

        func start(on window: NSWindow) {
            intervals = []
            last = 0
            let link = window.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func frame(_ link: CADisplayLink) {
            if last > 0 { intervals.append(link.timestamp - last) }
            last = link.timestamp
        }

        func stop() { link?.invalidate(); link = nil }

        var lateFrames: Int { intervals.filter { $0 > 0.017 }.count }
    }
}
#endif

/// Which slide is showing, and whether the slides are still advancing by themselves. Apart from the
/// view so the self-test can run the clock without watching pixels.
/// The filling bar under the slide showing, and nothing else.
///
/// Its own object on purpose: it changes five times a second, and any change published by the model
/// rebuilds the WHOLE 980×700 page. Measured (2026-09-26): the page sitting there cost 250 ms of
/// processor time a second, which is what made dragging and the slide changes choppy — there was
/// nothing left to draw them with.
final class TutorialBar: ObservableObject {
    @Published var progress: Double = 0
}

final class TutorialModel: ObservableObject {
    @Published private(set) var index = 0
    @Published private(set) var auto = true
    let bar = TutorialBar()
    var progress: Double { bar.progress }

    #if DEBUG
    /// The model the window on screen is actually using, so the self-test can turn a slide and
    /// measure the frames that result. A model of its own would animate nothing.
    static weak var debugShared: TutorialModel?
    init() { TutorialModel.debugShared = self }
    #endif

    var slides: [TutorialContent.Slide] { TutorialContent.slides }

    /// Called on a timer; returns true when it moved on to the next slide.
    @discardableResult
    func tick(_ seconds: TimeInterval) -> Bool {
        guard auto else { return false }
        bar.progress += seconds / TutorialContent.autoAdvance
        guard bar.progress >= 1 else { return false }
        bar.progress = 0
        index = (index + 1) % slides.count
        return true
    }

    /// Any move made by hand stops the slides advancing by themselves, for good (owner, 2026-09-22).
    func step(_ delta: Int) { go(to: max(0, min(slides.count - 1, index + delta))) }

    func go(to target: Int) {
        auto = false
        bar.progress = 0
        index = target
    }
}

struct TutorialView: View {

    var onDismiss: () -> Void

    @StateObject private var model = TutorialModel()
    @State private var appeared = false
    @State private var window: NSWindow?
    /// Where the pointer took hold, in the page's own coordinates. The window is moved by the
    /// difference on every step, which is self-correcting: as the window follows the pointer, the
    /// pointer's place in the page comes back to the grab point and the next difference is zero.
    @State private var grab: CGPoint?

    /// Five times a second, not twenty (owner reported the drag moving "like 30fps", 2026-09-26).
    /// Every tick republishes `progress`, and every republish rebuilds this whole 980×700 page — and
    /// a rebuild of a window that is not opaque and carries a system shadow makes the window server
    /// work out the shadow again. The bar fills just as smoothly on a linear animation between
    /// tickswide apart, for a quarter of the work.
    private static let tickInterval: TimeInterval = 0.2
    private let tick = Timer.publish(every: TutorialView.tickInterval, on: .main, in: .common).autoconnect()
    private var index: Int { model.index }
    private var auto: Bool { model.auto }
    private var progress: Double { model.progress }
    private var slides: [TutorialContent.Slide] { TutorialContent.slides }
    private var slide: TutorialContent.Slide { slides[min(index, slides.count - 1)] }
    private var accent: Color { Color(nsColor: Brand.accentNS) }

    var body: some View {
        #if DEBUG
        TutorialProbe.bodyEvaluations += 1
        #endif
        return VStack(spacing: 0) {
            header
            stage
            words
            controls
        }
        .frame(width: 980, height: 700)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.09)))
        .foregroundStyle(.white.opacity(0.92))
        .background(WindowReader { window = $0 })
        // The whole page drags the window (owner, 2026-09-26). A SwiftUI gesture, because SwiftUI
        // takes the mouse before any AppKit view behind it does; SIMULTANEOUS, so the buttons and
        // dots still get their clicks, and 4pt of slack so a click is never a drag.
        .simultaneousGesture(windowDrag)
        .onReceive(tick) { _ in advanceClock() }
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { appeared = true } }
        .background(KeyCatcher(onLeft: { step(-1) }, onRight: { step(1) }, onClose: onDismiss))
    }

    // MARK: Pieces

    /// The app's own dark indigo, with a soft orange bloom behind the picture.
    private var background: some View {
        ZStack {
            Color.chromeWindow
            RadialGradient(colors: [accent.opacity(0.20), .clear], center: .init(x: 0.5, y: 0.18),
                           startRadius: 10, endRadius: 620)
            LinearGradient(colors: [.white.opacity(0.05), .clear], startPoint: .top, endPoint: .center)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "graduationcap.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
            Text(TutorialContent.title).font(.system(size: 15, weight: .semibold))
            Text(TutorialContent.subtitle).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.5))
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.7))
            .accessibilityLabel("Close")
            .tip("Close", "Put the tutorial away; the ? button in All Notes brings it back")
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 6)
    }

    /// The screenshot, floating over its own reflection.
    private var stage: some View {
        ZStack {
            ForEach(Array(slides.enumerated()), id: \.element.id) { i, s in
                if i == index {
                    picture(s)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 60)).combined(with: .scale(scale: 0.97)),
                            removal: .opacity.combined(with: .offset(x: -60))))
                }
            }
        }
        .frame(height: 420)
        .padding(.horizontal, 40)
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: index)
    }

    private func picture(_ s: TutorialContent.Slide) -> some View {
        let image = TutorialContent.picture(s.image)
        // The drawn size is worked out here rather than left to a fit: the reflection underneath has
        // to be laid out at exactly the same size, or it shrinks into a thumbnail.
        let stageWidth: CGFloat = 880, stageHeight: CGFloat = 330
        let aspect = (image?.size.width ?? 4) / max(1, image?.size.height ?? 3)
        let height = min(stageHeight, stageWidth / aspect)
        let width = height * aspect
        return VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    // A picture that has not been generated must not leave a slide blank.
                    RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06))
                        .overlay(Text(s.image).font(.caption).foregroundStyle(.white.opacity(0.4)))
                }
            }
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.45), radius: 26, y: 14)
            .shadow(color: accent.opacity(0.18), radius: 40)

            // The reflection: the same picture at the same size, upside down, fading out under it.
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: width, height: height)
                    .scaleEffect(y: -1, anchor: .center)
                    .mask(LinearGradient(colors: [.white.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(width: width, height: 74))
                    .frame(width: width, height: 74, alignment: .top)
                    .clipped()
                    .opacity(0.55)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var words: some View {
        VStack(spacing: 9) {
            Text(slide.title)
                .font(.system(size: 23, weight: .bold))
                .multilineTextAlignment(.center)
            Text(slide.detail)
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.66))
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 640)
                .fixedSize(horizontal: false, vertical: true)
            keyCap
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
        .frame(height: 150, alignment: .top)
        .id(slide.id)                       // a new slide's words fade in as their own view
        .transition(.opacity)
        .animation(.easeOut(duration: 0.35), value: index)
    }

    @ViewBuilder private var keyCap: some View {
        if let action = slide.shortcut {
            HStack(spacing: 8) {
                Text(ShortcutStore.shared.combo(for: action).display)
                    .font(.system(size: 11.5, design: .monospaced)).tracking(3)
                    .padding(.leading, 7).padding(.trailing, 4).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12)))
                Text(action.title).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.top, 2)
        } else if let hint = slide.hint {
            Text(hint).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45)).padding(.top, 2)
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            arrow("chevron.left", "Previous", enabled: index > 0) { step(-1) }
            dots
            arrow("chevron.right", "Next", enabled: index < slides.count - 1) { step(1) }
            Spacer()
            Text("\(index + 1) of \(slides.count)")
                .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
            Button(action: onDismiss) {
                Text(TutorialContent.dismiss)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .frame(width: 96, height: 32)
                    .background(Capsule().fill(accent))
                    .shadow(color: accent.opacity(0.4), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(TutorialContent.dismiss)
            .tip("OK", "Close the tutorial")
        }
        .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 2)
    }

    /// One dot per slide; the one showing is a bar that fills while the slide plays itself.
    private var dots: some View {
        TutorialDots(bar: model.bar, index: index, auto: auto, slides: slides, accent: accent) { go(to: $0) }
    }

    private func arrow(_ symbol: String, _ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.3))
        .disabled(!enabled)
        .accessibilityLabel(name)
        .tip(name, name == "Next" ? "The next feature; this also stops the slides advancing by themselves"
                                  : "The feature before this one; this also stops the slides advancing by themselves")
    }

    /// Moving the window itself. SwiftUI's y grows downward and AppKit's upward, hence the sign.
    private var windowDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let window else { return }
                let start = grab ?? value.startLocation
                if grab == nil { grab = value.startLocation }
                let delta = CGSize(width: value.location.x - start.x, height: value.location.y - start.y)
                guard delta != .zero else { return }
                window.setFrameOrigin(NSPoint(x: window.frame.origin.x + delta.width,
                                              y: window.frame.origin.y - delta.height))
            }
            .onEnded { _ in grab = nil }
    }

    // MARK: Moving between slides

    private func advanceClock() {
        // Never while the page is being dragged: the drag itself costs 0.2 ms a step (measured), so
        // what made it choppy was the page rebuilding underneath it.
        guard grab == nil else { return }
        _ = model.tick(TutorialView.tickInterval)
    }

    private func step(_ delta: Int) { withAnimation { model.step(delta) } }

    private func go(to target: Int) { withAnimation { model.go(to: target) } }
}

/// The row of dots, which is the ONLY thing that changes while a slide plays itself. It watches the
/// bar rather than the model, so a tick redraws 26×7 points instead of the whole page.
private struct TutorialDots: View {
    @ObservedObject var bar: TutorialBar
    let index: Int
    let auto: Bool
    let slides: [TutorialContent.Slide]
    let accent: Color
    let go: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(slides.enumerated()), id: \.element.id) { i, s in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(i == index ? 0.18 : 0.10))
                    if i == index && auto {
                        // No animation: the bar moves about a point per tick, and an animation here
                        // is an animation on the whole window, for ever.
                        Capsule().fill(accent).frame(width: max(4, 26 * bar.progress))
                    } else if i == index {
                        Capsule().fill(accent)
                    }
                }
                .frame(width: i == index ? 26 : 7, height: 7)
                .contentShape(Rectangle())
                .onTapGesture { go(i) }
                .accessibilityLabel(s.title)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: index)
    }
}

/// Hands the view's window back to SwiftUI. The drag itself is a SwiftUI gesture (see
/// `TutorialView.windowDrag`): an `NSView` sitting in the BACKGROUND never sees the mouse, because
/// every SwiftUI view drawn over it takes the event first — which is why the first attempt at a
/// drag layer did nothing by hand while passing a test that called it directly.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Reader(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Reader: NSView {
        private let onWindow: (NSWindow?) -> Void
        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}

/// Arrow keys and Escape, which SwiftUI buttons alone cannot catch in a borderless panel.
private struct KeyCatcher: NSViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = Catcher()
        view.onLeft = onLeft; view.onRight = onRight; view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let c = nsView as? Catcher else { return }
        c.onLeft = onLeft; c.onRight = onRight; c.onClose = onClose
    }

    final class Catcher: NSView {
        var onLeft: () -> Void = {}
        var onRight: () -> Void = {}
        var onClose: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true else { return event }
                switch event.keyCode {
                case 123: self.onLeft(); return nil          // ←
                case 124: self.onRight(); return nil         // →
                case 53:  self.onClose(); return nil         // Esc
                default:  return event
                }
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - Window

/// Shows the tutorial, from the ? button in All Notes or from the first-run card.
enum TutorialWindow {

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { TutorialWindow.dismiss() }
    }

    private static var panel: NSPanel?

    static var isShowing: Bool { panel?.isVisible == true }

    static func show() {
        if let panel, panel.isVisible { panel.makeKeyAndOrderFront(nil); return }
        let host = NSHostingView(rootView: TutorialView(onDismiss: { dismiss() }))
        let size = host.fittingSize
        let p = Panel(contentRect: NSRect(origin: .zero, size: size),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // Above every other window, this app's and everyone else's, and it stays there while the
        // reader clicks around (owner, 2026-09-26).
        p.level = .modalPanel
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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

    #if DEBUG
    static var panelForTesting: NSWindow? { panel }

    /// Drags the page the way a hand does: real events, through `NSApp.sendEvent`, so hit testing
    /// and the responder chain decide who gets them. The first version called the drag view's own
    /// methods and passed while the window would not move by hand at all (owner, 2026-09-26) — a
    /// test that cannot fail.
    static func dragForTesting(by delta: NSSize, pace: TimeInterval = 0.02) -> Bool {
        guard let panel else { return false }
        let start = NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
        func event(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        // The pointer travels a fixed path ON SCREEN and the window follows it, so each event's
        // position IN THE WINDOW is measured against where the window has got to by then — which is
        // what the window server does. Scripting window-relative positions instead made the page
        // move 3.5x too far: every step re-counted the distance already travelled.
        let originAtStart = panel.frame.origin
        let screenStart = NSPoint(x: originAtStart.x + start.x, y: originAtStart.y + start.y)
        guard let down = event(.leftMouseDown, start) else { return false }
        NSApp.sendEvent(down)
        let steps = 6
        for i in 1...steps {
            let onScreen = NSPoint(x: screenStart.x + delta.width * CGFloat(i) / CGFloat(steps),
                                   y: screenStart.y + delta.height * CGFloat(i) / CGFloat(steps))
            let inWindow = NSPoint(x: onScreen.x - panel.frame.origin.x, y: onScreen.y - panel.frame.origin.y)
            guard let moved = event(.leftMouseDragged, inWindow) else { return false }
            NSApp.sendEvent(moved)
            // `pace` is the harness pretending to be a hand. Pass 0 to time the app's own work.
            if pace > 0 { RunLoop.current.run(until: Date().addingTimeInterval(pace)) }
        }
        let last = NSPoint(x: screenStart.x + delta.width - panel.frame.origin.x,
                           y: screenStart.y + delta.height - panel.frame.origin.y)
        guard let up = event(.leftMouseUp, last) else { return false }
        NSApp.sendEvent(up)
        if pace > 0 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return true
    }
    #endif
}
