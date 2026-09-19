#if DEBUG
import AppKit
import WebKit

/// Debug-only verification hook. Set PINTACK_SELFTEST_DIR and the app writes a
/// report and PNG renders of its own windows there, then (with
/// PINTACK_SELFTEST_QUIT) exits.
///
/// Why it exists: the project owner validates behavior, not code, and an agent
/// cannot take screenshots of another app without Screen Recording permission. An
/// app can always render its own windows, so this gives evidence of what is
/// actually on screen: the Dock icon, the menu-bar icon, and every note's card.
/// It never ships: the whole file is compiled out of Release builds.
enum SelfTest {

    private static var lines: [String] = []

    static func runIfRequested(appDelegate: AppDelegate, statusItem: StatusItemController?) {
        guard let dir = ProcessInfo.processInfo.environment["PINTACK_SELFTEST_DIR"] else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { run(out: out, statusItem: statusItem) }
    }

    private static func log(_ s: String) { lines.append(s); NSLog("PinTack selftest: \(s)") }

    private static func run(out: URL, statusItem: StatusItemController?) {
        log("activationPolicy = \(NSApp.activationPolicy() == .regular ? "regular (Dock icon shown)" : "NOT regular")")
        log("vault = \(VaultStore.shared.vaultURL.path)")
        log("notes in vault = \(VaultStore.shared.notes.count), open panels = \(WindowManager.shared.openPanels.count)")

        // Dock icon
        if let icon = NSApp.applicationIconImage {
            log("dock icon: \(Int(icon.size.width))x\(Int(icon.size.height)) pt, \(icon.representations.count) representations")
            save(icon, to: out.appendingPathComponent("dock-icon.png"))
        } else { log("dock icon: MISSING") }
        log("asset 'AppIcon' resolves: \(NSImage(named: "AppIcon") != nil)")

        // Menu-bar icon
        if let item = statusItem?.statusItem {
            log("status item isVisible = \(item.isVisible)")
            if let w = item.button?.window {
                let screens = NSScreen.screens.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" }
                log("status item window frame = \(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))x\(Int(w.frame.height)); onScreen=\(w.isVisible); screens=\(screens)")
                let onAnyScreen = NSScreen.screens.contains { $0.frame.intersects(w.frame) }
                log("status item lies inside a screen: \(onAnyScreen)")
            } else { log("status item has NO window (not placed in the menu bar)") }
            log("status item image: \(item.button?.image != nil), isTemplate = \(item.button?.image?.isTemplate == true)")
            saveMenuBarMock(to: out.appendingPathComponent("menubar-icon.png"))
        } else { log("status item: MISSING") }

        // Hotkeys: registration status per global action, then push a simulated press
        // through the same Carbon handler path and check that a note appears.
        for (action, status) in GlobalHotKeyCenter.shared.lastStatus.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            log("hotkey \(ShortcutStore.shared.combo(for: action).display) (\(action.rawValue)): OSStatus \(status) \(status == noErr ? "registered" : "FAILED")")
        }
        let before = VaultStore.shared.notes.count
        let delivered = GlobalHotKeyCenter.shared.simulatePress(of: .newNote)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            log("simulated ⌥⌘N through Carbon handler: delivered=\(delivered), notes \(before) -> \(VaultStore.shared.notes.count)")
            bridgeTest(out: out)
        }
    }

    /// Exercises the editor inside the real WKWebView: type through the JS bridge,
    /// wait out both debounces, and check the text reached the file on disk.
    private static func bridgeTest(out: URL) {
        let panels = WindowManager.shared.openPanels.sorted { $0.note.created < $1.note.created }
        for p in panels {
            log("note '\(p.note.title)': first responder = \(type(of: p.firstResponder as Any)), editor is responder = \(p.firstResponder === p.card.editor)")
        }
        guard let target = panels.first else { renderWindows(out: out); return }

        // A second note gets a body that uses every Live Preview construct, so the
        // screenshot shows the renderer inside WebKit, not just in a desktop browser.
        if panels.count > 1 {
            let p2 = panels[1]
            p2.note.body = sampleBody
            p2.note.colorHex = "#A3D5FF"
            p2.card.refreshFromNote()
            p2.card.editor.reloadBody()
        }

        let js = "(()=>{const v=window.__pintack._view; v.dispatch({changes:{from:v.state.doc.length, insert:'\\n\\nBRIDGE-TEST-OK #selftest'}}); return v.state.doc.length})()"
        target.card.editor.evaluateJavaScript(js) { result, error in
            log("JS edit dispatched: result=\(String(describing: result)) error=\(String(describing: error))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            let onDisk = (try? String(contentsOf: target.note.fileURL, encoding: .utf8)) ?? ""
            log("bridge round trip (type → JS → Swift → atomic save): file contains edit = \(onDisk.contains("BRIDGE-TEST-OK")); inline #tag merged into frontmatter = \(onDisk.contains("selftest"))")
            renderWindows(out: out)
        }
    }

    private static let sampleBody = """
    # Sprint blockers

    ## Blockers
    - [x] Cert renewal on the build agent
    - [ ] Graph throttling on bulk device query
    - [ ] Autopilot profile drift

    Some **bold**, *italic*, ~~struck~~ and `Get-CimInstance` inline. ==Highlighted== and <span style="color:#e07b39">orange</span> text, #urgent.

    > The best interface is the one you forget is there.

    ```powershell
    Get-Process | Where-Object CPU -gt 10
    ```

    | Tool | Use |
    | --- | :---: |
    | Intune | **MDM** |

    🍎 apples
    🥛 oat milk
    """

    private static func renderWindows(out: URL) {
        // Put some realistic content in a note so the Live Preview render is visible.
        if let first = WindowManager.shared.openPanels.sorted(by: { $0.note.created < $1.note.created }).first {
            first.note.pinned = true
            first.applyPinned()
        }
        let group = DispatchGroup()
        var index = 0
        for panel in WindowManager.shared.openPanels.sorted(by: { $0.note.created < $1.note.created }) {
            index += 1
            let name = "note-\(index).png"
            let f = panel.frame
            log("note \(index): window \(Int(f.width))x\(Int(f.height)) = card \(Int(f.width - 48))x\(Int(f.height - 48)) + 24pt margin; card frame stored y=\(Int(panel.note.cardFrame.minY)) window y=\(Int(f.minY + 24))")
            group.enter()
            snapshot(window: panel, to: out.appendingPathComponent(name)) { group.leave() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            AllNotesWindowController.shared.show()
            SettingsWindowController.shared.show()
            ShortcutsOverlay.shared.show()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if let w = AllNotesWindowController.shared.window { group.enter(); snapshot(window: w, to: out.appendingPathComponent("all-notes.png")) { group.leave() } }
            if let w = SettingsWindowController.shared.window { group.enter(); snapshot(window: w, to: out.appendingPathComponent("settings.png")) { group.leave() } }
            if let w = NSApp.windows.first(where: { String(describing: type(of: $0)).contains("OverlayPanel") }) {
                group.enter(); snapshot(window: w, to: out.appendingPathComponent("shortcuts.png")) { group.leave() }
            }
            group.notify(queue: .main) { finish(out: out) }
        }
    }

    private static func finish(out: URL) {
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.environment["PINTACK_SELFTEST_QUIT"] != nil {
            SaveCoordinator.shared.flushAll()
            NSApp.terminate(nil)
        }
    }

    // MARK: Rendering

    private static func snapshot(window: NSWindow, to url: URL, completion: @escaping () -> Void) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { completion(); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let base = NSImage(size: view.bounds.size)
        base.addRepresentation(rep)

        let webViews = allSubviews(of: view).compactMap { $0 as? WKWebView }.filter { !$0.isHidden }
        var shots: [(NSRect, NSImage)] = []
        let group = DispatchGroup()
        for web in webViews {
            group.enter()
            web.takeSnapshot(with: nil) { image, _ in
                if let image { shots.append((web.convert(web.bounds, to: view), image)) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let backdrop = NSColor(srgbRed: 0.36, green: 0.40, blue: 0.48, alpha: 1)
            let composed = NSImage(size: view.bounds.size, flipped: false) { rect in
                backdrop.setFill(); rect.fill()
                base.draw(in: rect)
                for (frame, image) in shots { image.draw(in: frame) }
                return true
            }
            save(composed, to: url)
            completion()
        }
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    /// The template icon as the menu bar would tint it, on light and dark bars, at 4x.
    private static func saveMenuBarMock(to url: URL) {
        let icon = StatusItemController.templateIcon()
        let size = NSSize(width: 240, height: 44)
        let img = NSImage(size: size, flipped: false) { rect in
            for (i, (bg, fg)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.16, alpha: 1), NSColor.white)].enumerated() {
                let half = NSRect(x: CGFloat(i) * rect.width / 2, y: 0, width: rect.width / 2, height: rect.height)
                bg.setFill(); half.fill()
                let tinted = NSImage(size: icon.size, flipped: false) { r in
                    icon.draw(in: r); fg.setFill(); r.fill(using: .sourceAtop); return true
                }
                let scale: CGFloat = 1.8
                let s = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
                tinted.draw(in: NSRect(x: half.midX - s.width / 2, y: half.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
        save(img, to: url)
    }

    private static func save(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
#endif
