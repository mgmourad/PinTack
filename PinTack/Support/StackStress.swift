#if DEBUG
import AppKit

/// A hundred clicks on a pile of five notes, one a second, with a marker showing where each one
/// lands so a person can watch it happen (owner's request, 2026-09-22).
///
///     scripts/stack-click-stress.sh [clicks]
///
/// It makes five notes in five colours against a THROWAWAY vault, stacks them, then clicks title
/// bars at random — sometimes the same one twice running — and after every click checks the four
/// things that must hold:
///
///   1. the note clicked is the one in front,
///   2. it swapped with the note that was in front, and nothing else moved,
///   3. what is drawn matches the pile: places, front-to-back order, sizes,
///   4. every note's title bar is still visible and can still be hit, and none is left renaming.
///
/// Every click is written down, so a fault can be read back with the state that led to it.
///
/// The clicks are synthetic: a real pointer would need Accessibility permission, which this app must
/// never ask for (SPEC.md §6.4). They are routed the way macOS routes one — the window under the
/// point, made key first, then mouse down and up.
enum StackStress {

    static var requested: Int? {
        ProcessInfo.processInfo.environment["PINTACK_STACK_STRESS"].map { Int($0) ?? 100 }
    }

    private static var marker: NSWindow?
    private static var log: [String] = []
    private static var faults: [String] = []

    static func runIfRequested() {
        guard let clicks = requested else { return }
        guard ProcessInfo.processInfo.environment["PINTACK_VAULT"]?.isEmpty == false else {
            print("STACK STRESS refused: set PINTACK_VAULT to a throwaway folder")
            exit(2)
        }
        NSApp.activate(ignoringOtherApps: true)
        MainWindowController.shared.close()

        // Against a vault that already HAS a stack (a copy of the owner's, say), use his notes rather
        // than making new ones: their sizes, colours, pins and todo bars are the point.
        if ProcessInfo.processInfo.environment["PINTACK_STACK_STRESS_EXISTING"] != nil,
           let existing = StackManager.shared.stacks.first {
            let members = StackManager.shared.notes(of: existing)
            print("STACK STRESS using the vault's own stack “\(existing.name)”: "
                  + members.map { "\($0.title.isEmpty ? "Untitled" : $0.title)"
                                  + " \(Int($0.cardFrame.width))×\(Int($0.cardFrame.height))"
                                  + ($0.pinned ? " PINNED" : "") + ($0.collapsed ? " COLLAPSED" : "")
                                  + ($0.isTodo ? " todo" : "") }.joined(separator: " | "))
            for note in members {
                note.visible = true
                VaultStore.shared.save(note)
                WindowManager.shared.open(note)
            }
            func nameOf(_ id: String?) -> String {
                let t = VaultStore.shared.note(id: id ?? "")?.title ?? "?"
                return String((t.isEmpty ? "Untitled" : t).prefix(14))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                StackManager.shared.layoutAll()
                showMarker()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    step(1, of: clicks, stackID: existing.id, notes: members, name: nameOf, lastPlace: 0)
                }
            }
            return
        }

        let colours = ["#FFE9A8", "#D9F3C9", "#CFE6FF", "#F6D6E8", "#E7DFFA"]
        let names = ["Butter", "Mint", "Sky", "Rose", "Lilac"]
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 360, height: 260)
        let notes = zip(colours, names).map { colour, name -> Note in
            let n = VaultStore.shared.createNote(body: "\(name)\n\nA note in the pile.",
                                                 frame: NSRect(x: screen.midX - size.width / 2,
                                                               y: screen.midY - size.height / 2,
                                                               width: size.width, height: size.height))
            n.colorHex = colour
            VaultStore.shared.save(n)
            WindowManager.shared.open(n)
            return n
        }
        func name(_ id: String?) -> String { notes.firstIndex { $0.id == id }.map { names[$0] } ?? "?" }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let stack = StackManager.shared.create(name: "Stress", noteIDs: notes.map(\.id)) else {
                print("STACK STRESS: could not make the stack"); exit(1)
            }
            showMarker()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                step(1, of: clicks, stackID: stack.id, notes: notes, name: name, lastPlace: 0)
            }
        }
    }

    // MARK: One click

    private static func step(_ i: Int, of total: Int, stackID: String, notes: [Note],
                             name: @escaping (String?) -> String, lastPlace: Int) {
        guard i <= total else { finish(stackID: stackID, notes: notes); return }
        let sm = StackManager.shared, wm = WindowManager.shared
        guard let s = sm.stack(id: stackID) else { finish(stackID: stackID, notes: notes); return }

        // Two in five clicks land on the place just clicked, so repeats are covered too.
        let place = (lastPlace > 0 && Int.random(in: 1...5) <= 2) ? lastPlace : Int.random(in: 1...s.order.count)
        let before = s.order
        guard let target = wm.panel(for: before[place - 1]) else { finish(stackID: stackID, notes: notes); return }
        let card = NotePanel.cardRect(forWindow: target.frame)
        let point = NSPoint(x: card.midX, y: card.maxY - NotePanel.headerHeight / 2)
        let aimed = target.note.id

        // Another app in front would take every click: keep PinTack frontmost for the run.
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        moveMarker(to: point)
        // A beat between the marker arriving and the click, so a watcher can see where it is going.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
            let hit = wm.openPanels.first { $0.windowNumber == number }
            flashMarker()
            // macOS raises the window under the pointer and makes it key. That raise goes through the
            // window server, so it can land AFTER the app has reordered the pile — which is what the
            // owner's recording shows. PINTACK_STACK_STRESS_LATE_RAISE puts it in that order.
            let lateRaise = ProcessInfo.processInfo.environment["PINTACK_STACK_STRESS_LATE_RAISE"] != nil
            if !lateRaise { hit?.makeKeyAndOrderFront(nil) }
            if let hit {
                let inWindow = hit.convertPoint(fromScreen: point)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: hit.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: 1, pressure: 1) {
                        hit.sendEvent(e)
                    }
                }
            }
            if lateRaise { DispatchQueue.main.async { hit?.makeKeyAndOrderFront(nil) } }
            // Let the pile settle before judging it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                let after = sm.stack(id: stackID)?.order ?? []
                var want = before
                want.swapAt(0, place - 1)
                var trouble: [String] = []
                if after.first != aimed { trouble.append("\(name(after.first)) came forward, not \(name(aimed))") }
                if after != want { trouble.append("pile is \(after.map(name).joined(separator: ",")), expected \(want.map(name).joined(separator: ","))") }
                trouble += drawnFaults(stackID: stackID, name: name)
                if let renaming = wm.openPanels.first(where: { $0.card.debugIsRenaming }) {
                    trouble.append("\(name(renaming.note.id)) is being renamed")
                }
                let line = String(format: "%3d", i) + ". place \(place)"
                    + " (\(name(aimed)))  delivered to \(name(hit?.note.id))"
                    + "  \(before.map(name).joined(separator: ",")) → \(after.map(name).joined(separator: ","))"
                    + (trouble.isEmpty ? "  ok" : "  ✗ " + trouble.joined(separator: "; "))
                log.append(line)
                if !trouble.isEmpty { faults.append(line) }
                print("STACK STRESS \(line)")
                // One click a second, as asked.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    step(i + 1, of: total, stackID: stackID, notes: notes, name: name, lastPlace: place)
                }
            }
        }
    }

    /// What is on screen, against what the pile says.
    private static func drawnFaults(stackID: String, name: (String?) -> String) -> [String] {
        let wm = WindowManager.shared
        guard let s = StackManager.shared.stack(id: stackID), let front = wm.panel(for: s.front ?? "") else { return [] }
        let base = NotePanel.cardRect(forWindow: front.frame)
        var bad: [String] = []
        for (place, id) in s.order.enumerated() {
            guard let p = wm.panel(for: id) else { bad.append("\(name(id)) has no window"); continue }
            let card = NotePanel.cardRect(forWindow: p.frame)
            let wantTop = base.maxY + CGFloat(place) * NotePanel.headerHeight
            if abs(card.maxY - wantTop) > 1 || abs(card.minX - base.minX) > 1 || abs(card.width - base.width) > 1 {
                bad.append("\(name(id)) is drawn \(Int(card.maxY - wantTop))pt off place \(place + 1)")
            }
            let point = NSPoint(x: card.midX, y: card.maxY - NotePanel.headerHeight / 2)
            let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
            guard let hit = wm.openPanels.first(where: { $0.windowNumber == number }) else {
                bad.append("\(name(id))'s title bar is hidden"); continue
            }
            if hit.card.debugClickTarget(atScreen: point) != id {
                bad.append("\(name(id))'s title bar leads to \(name(hit.card.debugClickTarget(atScreen: point)))")
            }
        }
        let z = (NSWindow.windowNumbers(options: []) ?? []).compactMap { n in
            s.order.first { wm.panel(for: $0)?.windowNumber == n.intValue }
        }
        if z != s.order { bad.append("drawn \(z.map(name).joined(separator: ",")) but the pile is \(s.order.map(name).joined(separator: ","))") }
        return bad
    }

    private static func finish(stackID: String, notes: [Note]) {
        let summary = "STACK STRESS: \(log.count) clicks, \(faults.count) with something wrong"
        print(summary)
        let report = ([summary, ""] + log + ["", "Faults:"] + (faults.isEmpty ? ["none"] : faults)).joined(separator: "\n")
        if let out = ProcessInfo.processInfo.environment["PINTACK_STACK_STRESS_OUT"] {
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
        }
        marker?.close()
        NSApp.terminate(nil)
    }

    // MARK: The marker, so a watcher can see where each click lands

    private static func showMarker() {
        let size: CGFloat = 26
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver               // above the notes, so it is always visible
        panel.ignoresMouseEvents = true          // and never in the way of the clicks it is showing
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = MarkerView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        panel.orderFrontRegardless()
        marker = panel
    }

    private static func moveMarker(to point: NSPoint) {
        guard let marker else { return }
        let target = NSPoint(x: point.x - marker.frame.width / 2, y: point.y - marker.frame.height / 2)
        Motion.springFrame(marker, to: NSRect(origin: target, size: marker.frame.size))
    }

    private static func flashMarker() {
        (marker?.contentView as? MarkerView)?.flash()
    }

    /// A red ring that fills for a moment when the click goes in.
    private final class MarkerView: NSView {
        private var pressed = false

        func flash() {
            pressed = true
            needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.pressed = false
                self?.needsDisplay = true
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            let ring = bounds.insetBy(dx: 4, dy: 4)
            let path = NSBezierPath(ovalIn: ring)
            NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: pressed ? 0.85 : 0.25).setFill()
            path.fill()
            NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 0.95).setStroke()
            path.lineWidth = 2.5
            path.stroke()
        }
    }
}
#endif
