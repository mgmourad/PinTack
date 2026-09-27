#if DEBUG
import AppKit

/// How long from clicking a note to a typed character actually being in its editor (SPEC.md §17).
///
///     PINTACK_VAULT=/tmp/x PINTACK_FOCUSPROBE=5 build/Debug/PinTack.app/Contents/MacOS/PinTack
///
/// or `scripts/bench-focus.sh`. Debug builds only, throwaway vaults only.
///
/// Today this is nearly nothing, because every note's editor is always live and a click only moves
/// the keyboard between windows. It is measured anyway, because it is the number any design that
/// parks a note in a non-live state has to pay back on every focus switch — and the number that
/// says whether such a design is tolerable.
///
/// The click is delivered the way the window server delivers one: to whichever window is actually
/// on top at that point, not to the note we mean, so the app's own hand-off is part of what is
/// measured. The keystroke follows IMMEDIATELY, with no wait, because that is what a person does
/// and dropping it is the failure this has to be able to see.
enum FocusProbe {

    static var requested: Int? {
        guard let raw = ProcessInfo.processInfo.environment["PINTACK_FOCUSPROBE"] else { return nil }
        return Int(raw).map { max(1, $0) } ?? 5
    }

    static func runIfRequested() {
        guard let runs = requested else { return }
        guard ProcessInfo.processInfo.environment["PINTACK_VAULT"]?.isEmpty == false else {
            print("FOCUSPROBE refused: set PINTACK_VAULT to a throwaway folder")
            exit(2)
        }
        NSApp.activate(ignoringOtherApps: true)
        MainWindowController.shared.close()
        // Long enough for every restored note to have loaded its editor: a page still loading would
        // be measuring the launch, not a focus switch.
        let settle = 6 + Double(WindowManager.shared.openPanels.count) * 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { measureFloor(runs: runs) }
    }

    // MARK: - The measurement

    private static var latencies: [Double] = []
    private static var dropped = 0
    private static var wrongNote: [String] = []
    private static var trace: [String] = []
    private static var floorMs = 0.0

    /// What one round trip to a page costs. The probe finds out the character has landed by asking
    /// the page, so no latency below this is measurable, and a number is worth nothing without the
    /// resolution it was measured at.
    private static func measureFloor(runs: Int) {
        guard let panel = WindowManager.shared.openPanels.first else {
            report(runs: runs, note: "no open note to measure")
            return
        }
        var samples: [Double] = []
        func ping(_ left: Int) {
            guard left > 0 else {
                floorMs = samples.sorted()[samples.count / 2]
                step(runs: runs, left: runs)
                return
            }
            let t0 = Date()
            panel.card.editor.evaluateJavaScript("1") { _, _ in
                samples.append(Date().timeIntervalSince(t0) * 1000)
                ping(left - 1)
            }
        }
        ping(9)
    }

    /// One click, one keystroke, timed from the click to the character being in the document.
    private static func step(runs: Int, left: Int) {
        guard left > 0 else { return report(runs: runs, note: nil) }
        let panels = WindowManager.shared.openPanels
        guard panels.count >= 1 else { return report(runs: runs, note: "no open notes") }
        // A note that is NOT the key window (focusing the note you are already in measures nothing),
        // and a point on it that a PERSON could actually hit: on a crowded desk a note's middle is
        // often under another note, and a click there focuses the wrong one. Aiming at a covered
        // point made the probe report every keystroke as dropped — the probe's fault, not the app's
        // (2026-09-27).
        guard let (target, point) = visibleTarget() else {
            return report(runs: runs, note: "no unfocused note had a point of its own to click")
        }
        // Its own letter per run: with one shared marker, a character left behind by an earlier run
        // makes every later run look as though it landed in the wrong note.
        let markers: [(String, UInt16)] = [("z", 6), ("x", 7), ("c", 8), ("v", 9), ("b", 11)]
        let (marker, keyCode) = markers[(runs - left) % markers.count]

        let before = Date()
        // What the WINDOW SERVER does on a press, before the app sees anything: it raises the window
        // under the pointer and gives it the keyboard. A synthetic click does not do this by itself
        // (CLAUDE.md, the stack tests), and without it the keystroke goes to whichever note had the
        // keyboard before — which looked like dropped keystrokes and was the harness all along.
        // It is inside the measurement, because a person waits for all of it.
        target.makeKeyAndOrderFront(nil)
        let hit = target
        let inWindow = hit.convertPoint(fromScreen: point)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: hit.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                NSApp.sendEvent(e)
            }
        }
        let keyAfterClick = (NSApp.keyWindow as? NotePanel)?.note.title ?? "\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none")"
        trace.append("aimed \(target.note.title) | key after click: \(keyAfterClick)")
        // No pause: typing the instant the click lands is the case that matters.
        if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: target.windowNumber, context: nil,
                                      characters: marker, charactersIgnoringModifiers: marker,
                                      isARepeat: false, keyCode: keyCode) {
            NSApp.sendEvent(key)
        }

        let deadline = Date().addingTimeInterval(8)
        func poll() {
            target.card.editor.evaluateJavaScript(
                "window.__pintack && window.__pintack._view ? window.__pintack._view.state.doc.toString().includes(\"\(marker)\") : false"
            ) { result, _ in
                if (result as? Bool) == true {
                    latencies.append(Date().timeIntervalSince(before) * 1000)
                    clean(target, marker) { step(runs: runs, left: left - 1) }
                } else if Date() > deadline {
                    // Not in the note we aimed at. Say where it DID go: a character that landed in
                    // another note is a different fault from one that vanished.
                    elsewhere(marker, except: target) { other in
                        if let other { wrongNote.append(other) } else { dropped += 1 }
                        clean(target, marker) { step(runs: runs, left: left - 1) }
                    }
                } else {
                    poll()
                }
            }
        }
        poll()
    }

    /// Whether the character landed in some OTHER note instead of the one clicked.
    private static func elsewhere(_ marker: String, except target: NotePanel,
                                  then done: @escaping (String?) -> Void) {
        let others = WindowManager.shared.openPanels.filter { $0 !== target }
        func check(_ rest: [NotePanel]) {
            guard let panel = rest.first else { return done(nil) }
            panel.card.editor.evaluateJavaScript(
                "window.__pintack && window.__pintack._view ? window.__pintack._view.state.doc.toString().includes(\"\(marker)\") : false"
            ) { result, _ in
                if (result as? Bool) == true { done(panel.note.title) } else { check(Array(rest.dropFirst())) }
            }
        }
        check(others)
    }

    /// An unfocused note and a point on it that belongs to it — the window server has to agree that
    /// a click there lands on that note, or the click focuses somebody else.
    private static func visibleTarget() -> (NotePanel, NSPoint)? {
        let key = NSApp.keyWindow
        // Front to back: the nearest note to the top is the one a person would reach for.
        let order = (NSWindow.windowNumbers(options: []) ?? []).map(\.intValue)
        let panels = WindowManager.shared.openPanels
        let candidates = order.compactMap { n in panels.first { $0.windowNumber == n } }.filter { $0 !== key }
            + panels.filter { $0 !== key }
        // …and if every note is focused or covered, the note that HAS the keyboard is still a fair
        // measurement of "type into this note", so it is the last resort rather than nothing.
        for panel in candidates + [key].compactMap({ $0 as? NotePanel }) {
            if let point = clickablePoint(on: panel) { return (panel, point) }
        }
        return nil
    }

    /// A point inside the note's body that the window server agrees belongs to this window. The body
    /// rather than the title bar: a title-bar click drags the note or starts a rename. A crowded
    /// desk leaves only a strip of a note showing, so the whole card is scanned rather than assuming
    /// the middle is free.
    private static func clickablePoint(on panel: NotePanel) -> NSPoint? {
        let card = NotePanel.cardRect(forWindow: panel.frame)
        // Top down, starting just under the title bar: the FIRST LINES are text in every kind of
        // note, while the middle of a note that holds a picture IS the picture — and clicking a
        // picture selects it for cropping, so the keystroke that follows goes nowhere. That is the
        // app behaving correctly; the probe was aiming at the wrong thing (2026-09-27).
        let top = card.maxY - NotePanel.headerHeight - 10
        let bottom = card.minY + 40
        guard top > bottom else { return nil }
        for row in 0..<8 {
            let y = top - (top - bottom) * CGFloat(row) / 8
            for column in 0..<5 {
                let x = card.minX + 16 + (card.width - 32) * CGFloat(column) / 5
                let point = NSPoint(x: x, y: y)
                if NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == panel.windowNumber {
                    return point
                }
            }
        }
        return nil
    }

    /// Takes the marker back out, so the next round starts from the same document.
    private static func clean(_ panel: NotePanel, _ marker: String, then next: @escaping () -> Void) {
        panel.card.editor.evaluateJavaScript("""
            (() => { const v = window.__pintack && window.__pintack._view; if (!v) return;
              const text = v.state.doc.toString(), at = text.indexOf(MARKER);
              if (at >= 0) v.dispatch({ changes: { from: at, to: at + 1 } }); })()
            """.replacingOccurrences(of: "MARKER", with: "\"\(marker)\"")) { _, _ in
                // A moment for the key window to settle before the next click is aimed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: next)
            }
    }

    private static func report(runs: Int, note: String?) {
        let sorted = latencies.sorted()
        var lines = ["PinTack focus probe: click a note, type, measure until the character is in it",
                     "notes open: \(WindowManager.shared.openPanels.count)   runs: \(runs)"]
        if let note { lines.append("could not measure: \(note)") }
        if sorted.isEmpty {
            lines.append("no measurement")
        } else {
            lines.append(String(format: "click_to_type_ms median=%.1f min=%.1f max=%.1f  (resolution: one page round trip = %.1f ms)",
                                sorted[sorted.count / 2], sorted.first ?? 0, sorted.last ?? 0, floorMs))
        }
        lines.append("dropped keystrokes: \(dropped)")
        // The click-by-click trace only when something went wrong: on a good run it is noise, and
        // on a bad one it is the whole story (which note had the keyboard when the key was sent).
        if dropped > 0 || !wrongNote.isEmpty { lines.append(contentsOf: trace.map { "  · " + $0 }) }
        if !wrongNote.isEmpty { lines.append("keystrokes that landed in ANOTHER note: \(wrongNote.count) (\(wrongNote.joined(separator: ", ")))") }
        let report = lines.joined(separator: "\n")
        print(report)
        if let out = ProcessInfo.processInfo.environment["PINTACK_FOCUSPROBE_OUT"] {
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }
}
#endif
