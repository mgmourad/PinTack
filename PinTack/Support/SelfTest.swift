#if DEBUG
import AppKit
import WebKit
import Carbon.HIToolbox

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
    private static weak var app: AppDelegate?

    static func runIfRequested(appDelegate: AppDelegate, statusItem: StatusItemController?) {
        guard let dir = ProcessInfo.processInfo.environment["PINTACK_SELFTEST_DIR"] else { return }
        app = appDelegate
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
            codeHighlightTest(panels: panels) { shortcutTest(out: out) { interactionTest(out: out) } }
        }
    }

    /// The ```powershell block in `sampleBody`, highlighted inside the real web view. This is the only
    /// place that proves the page's CSP lets editor.js import a language module at run time: over the
    /// dev server the CSP is rewritten, so a browser check cannot tell us.
    private static func codeHighlightTest(panels: [NotePanel], then next: @escaping () -> Void) {
        guard panels.count > 1 else { next(); return }
        let js = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        for (let i = 0; i < 50 && !document.querySelector('.cm-codeblock span[class]'); i++) await sleep(100);
        const badge = document.querySelector('.cm-codeblock-tagged');
        const spans = [...document.querySelectorAll('.cm-codeblock span[class]')];
        const colour = e => getComputedStyle(e).color;
        // Whether the language LOGO actually painted, which is the part the page's CSP could refuse.
        let logo = null;
        if (badge) {
          const img = getComputedStyle(badge, '::after').backgroundImage;
          const url = img.startsWith('url("') ? img.slice(5, img.indexOf('")')) : null;
          if (url) {
            logo = await new Promise((done) => {
              const probe = new Image();
              probe.onload = () => done(url.split('/').pop() + ' ' + probe.naturalWidth + 'x' + probe.naturalHeight);
              probe.onerror = () => done('REFUSED ' + url);
              probe.src = url;
            });
          }
        }
        return JSON.stringify({
          badge: badge ? badge.dataset.lang : null,
          logo,
          tokens: spans.length,
          distinctColours: new Set(spans.map(colour)).size,
        });
        """
        panels[1].card.editor.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): log("code block highlighting in the app: \(value as? String ?? "nil")")
            case .failure(let error): log("code block highlighting in the app: FAILED \(error)")
            }
            next()
        }
    }

    // MARK: Interaction: real mouse events through the real window, plus popover placement

    private static func mouse(_ type: NSEvent.EventType, _ p: NSPoint, in panel: NSWindow, clicks: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    }

    private static func interactionTest(out: URL) {
        let panels = WindowManager.shared.openPanels.sorted { $0.note.created < $1.note.created }
        guard let p1 = panels.first else { renderWindows(out: out); return }

        // 1. Dragging by the TITLE moves the note (this was broken: the title swallowed the drag).
        let title = p1.card.debugTitleCenter
        let before = p1.frame.origin
        if let d = mouse(.leftMouseDown, title, in: p1), let m = mouse(.leftMouseDragged, NSPoint(x: title.x + 60, y: title.y - 40), in: p1),
           let u = mouse(.leftMouseUp, NSPoint(x: title.x + 60, y: title.y - 40), in: p1) {
            p1.sendEvent(d); p1.sendEvent(m); p1.sendEvent(u)
        }
        let moved = NSPoint(x: p1.frame.origin.x - before.x, y: p1.frame.origin.y - before.y)
        log("drag by title: window moved by (\(Int(moved.x)), \(Int(moved.y))) (expected 60, -40); renaming started by a single click = \(p1.card.debugIsRenaming)")
        let stored = NotePanel.cardRect(forWindow: p1.frame)
        log("after drag: stored card frame matches window inset by margin = \(p1.note.cardFrame == stored)")

        // 2. Double-click the title starts renaming; leaving the field ends it.
        if let d1 = mouse(.leftMouseDown, title, in: p1, clicks: 1), let u1 = mouse(.leftMouseUp, title, in: p1, clicks: 1),
           let d2 = mouse(.leftMouseDown, title, in: p1, clicks: 2), let u2 = mouse(.leftMouseUp, title, in: p1, clicks: 2) {
            p1.sendEvent(d1); p1.sendEvent(u1); p1.sendEvent(d2); p1.sendEvent(u2)
        }
        log("double-click on title: renaming = \(p1.card.debugIsRenaming)")
        p1.makeFirstResponder(p1.card.editor)
        log("after leaving the field: renaming = \(p1.card.debugIsRenaming) (false = solid again, draggable)")

        // 2b. Footer: empty space drags the note and does NOT open the tag editor; the tag ICON does.
        let empty = p1.card.debugFooterEmptyPoint
        let posBefore = p1.frame.origin
        if let d = mouse(.leftMouseDown, empty, in: p1), let m = mouse(.leftMouseDragged, NSPoint(x: empty.x + 30, y: empty.y - 20), in: p1),
           let u = mouse(.leftMouseUp, NSPoint(x: empty.x + 30, y: empty.y - 20), in: p1) { p1.sendEvent(d); p1.sendEvent(m); p1.sendEvent(u) }
        log("drag from EMPTY footer space: window moved by (\(Int(p1.frame.origin.x - posBefore.x)), \(Int(p1.frame.origin.y - posBefore.y))) (expected 30, -20); tag editor opened = \(p1.card.debugHasPopover) (must be false)")
        let icon = p1.card.debugTagsButtonFrame
        let iconPoint = NSPoint(x: icon.midX, y: icon.midY)
        if let d = mouse(.leftMouseDown, iconPoint, in: p1), let u = mouse(.leftMouseUp, iconPoint, in: p1) { p1.sendEvent(d); p1.sendEvent(u) }
        log("click on the tag ICON: tag editor opened = \(p1.card.debugHasPopover) (must be true); icon is \(Int(icon.width))x\(Int(icon.height)) pt wide, not a full-width strip")
        p1.card.debugClosePopover()

        // 2c. Right-click menu: contents, and does choosing an item run it?
        let p2m = panels.count > 1 ? panels[1] : p1
        log("right-click menu inside a note: \(p2m.card.debugMenuTitles(editing: true).joined(separator: " | "))")
        log("right-click menu on the header: \(p2m.card.debugMenuTitles(editing: false).joined(separator: " | "))")
        let pinTitle = p2m.note.pinned ? "Unpin from Top" : "Pin on Top"
        if let item = p2m.card.debugMenuItem(pinTitle, editing: true), let action = item.action {
            let was = p2m.note.pinned
            NSApp.sendAction(action, to: item.target, from: item)
            log("menu item '\(pinTitle)' chosen: pinned \(was) -> \(p2m.note.pinned)")
            NSApp.sendAction(action, to: item.target, from: item)    // put it back
        }
        // Paste through the responder chain, with the user's clipboard saved and restored.
        let general = NSPasteboard.general
        let saved = general.string(forType: .string)
        general.clearContents(); general.setString("PASTE-OK", forType: .string)
        p2m.makeKeyAndOrderFront(nil); p2m.makeFirstResponder(p2m.card.editor)
        let handled = NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            p2m.card.editor.evaluateJavaScript("window.__pintack._view.state.doc.toString().includes('PASTE-OK')") { r, _ in
                log("Paste from the context menu path: sendAction handled = \(handled), text arrived in the note = \(String(describing: r))")
                general.clearContents(); if let saved { general.setString(saved, forType: .string) }
            }
        }

        // 3. New todo note: "@Todo " with the hint, tagged #todo.
        let before3 = VaultStore.shared.notes.count
        WindowManager.shared.newTodo()
        if let todo = WindowManager.shared.focusedNote {
            log("new todo note: notes \(before3) -> \(VaultStore.shared.notes.count), body = \(todo.body.debugDescription), tags = \(todo.tags)")
        }

        // 3b. Drive the todo flow inside the real WebKit view: title, Enter, item, Enter; then a format button.
        if let todoPanel = WindowManager.shared.focusedPanel {
            let ed = todoPanel.card.editor
            // A brand-new note's WebKit view needs a moment to load the editor module.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            let js = """
            const v = window.__pintack._view, wait = ms => new Promise(r => setTimeout(r, ms));
            const enter = () => v.contentDOM.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', bubbles: true, cancelable: true}));
            const type = t => { const h = v.state.selection.main.head; v.dispatch({changes: {from: h, insert: t}, selection: {anchor: h + t.length}, userEvent: 'input.type'}); };
            enter(); await wait(40);                       // no title yet: nothing happens
            const afterEmptyEnter = v.state.doc.toString();
            type('Groceries'); enter(); await wait(40);    // first checkbox
            type('milk'); enter(); await wait(40);         // next checkbox
            type('eggs'); await wait(40);
            return JSON.stringify({ afterEmptyEnter, doc: v.state.doc.toString() });
            """
            ed.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): log("todo flow in WebKit: \(value)")
                case .failure(let error): log("todo flow in WebKit FAILED: \(error)")
                }
                ed.format("bold")            // action-bar button → JS, acts on the word under the caret
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    ed.evaluateJavaScript("JSON.stringify(window.__pintack._view.state.doc.toString())") { r, e in
                        log("after Bold button: doc = \(String(describing: r ?? e))")
                    }
                }
            }
            }
        }

        // 4. Action bar on the second note, then its Appearance popover: where does it land?
        if panels.count > 1 {
            let p2 = panels[1]
            p2.card.debugExpandActionBar()
            p2.card.debugShowAppearance()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                let anchor = p2.card.debugAppearanceButtonScreenRect
                if let w = p2.card.debugPopoverWindow {
                    let f = w.frame
                    // The popover must touch the button: its edge within a few points of the anchor.
                    let gapBelow = anchor.minY - f.maxY, gapAbove = f.minY - anchor.maxY
                    log("appearance popover: shown = \(p2.card.debugPopoverShown), frame = \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)); button = \(Int(anchor.minX)),\(Int(anchor.minY)) \(Int(anchor.width))x\(Int(anchor.height)); vertical gap to button: below=\(Int(gapBelow)) above=\(Int(gapAbove))")
                    log("popover attached to button (|gap| < 30 pt) = \(min(abs(gapBelow), abs(gapAbove)) < 30)")
                    snapshot(window: w, to: out.appendingPathComponent("popover-appearance.png")) { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { renderWindows(out: out) } }
                } else {
                    log("appearance popover: NO WINDOW")
                    renderWindows(out: out)
                }
            }
        } else { renderWindows(out: out) }
    }

    // MARK: Shortcuts: synthetic key presses through the same handler the key monitor uses

    private static func key(_ combo: KeyCombo, repeat isRepeat: Bool = false, in panel: NSWindow) -> NSEvent? {
        var flags: NSEvent.ModifierFlags = []
        if combo.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if combo.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                                isARepeat: isRepeat, keyCode: UInt16(combo.keyCode))
    }

    private static func shortcutTest(out: URL, then next: @escaping () -> Void) {
        let panels = WindowManager.shared.openPanels.sorted { $0.note.created < $1.note.created }
        guard let app, let p = panels.dropFirst().first else { next(); return }
        p.makeKeyAndOrderFront(nil)
        let n = p.note
        ActionRouter.dedupeInterval = 0          // the checks below press the same key back to back on purpose
        func press(_ a: ShortcutAction, rep: Bool = false) {
            if let e = key(ShortcutStore.shared.combo(for: a), repeat: rep, in: p) { _ = app.handleShortcut(e) }
        }
        let pinned0 = n.pinned; press(.pin);  log("shortcut ⌥⌘P: pinned \(pinned0) -> \(n.pinned)")
        press(.pin)
        let col0 = n.collapsed; press(.collapse); log("shortcut ⌥⌘K: collapsed \(col0) -> \(n.collapsed)"); press(.collapse)
        let mode0 = p.card.editor.mode; press(.toggleMode); log("shortcut ⌥⌘M: mode \(mode0) -> \(p.card.editor.mode)"); press(.toggleMode)
        press(.color3); log("shortcut ⌥⌘3: color = \(n.colorHex) (expected Mint \(NotePalette.set(for: n.theme)[2].hex))")
        let op0 = n.opacity; press(.lessOpaque); log("shortcut ⌥⌘,: opacity \(op0) -> \(n.opacity)"); press(.moreOpaque)

        // Key repeat: a held ⌥⌘P must act once, not flip back and forth.
        let before = n.pinned
        press(.pin); press(.pin, rep: true); press(.pin, rep: true); press(.pin, rep: true)
        log("held ⌥⌘P (1 press + 3 auto-repeats): pinned \(before) -> \(n.pinned) (must have toggled exactly once)")
        press(.pin, rep: false)

        // The same press arriving by two paths (Carbon + key monitor) must act ONCE.
        ActionRouter.dedupeInterval = 0.25
        ActionRouter.resetDedupeMemory()
        let beforeDup = n.pinned
        press(.pin); press(.pin)
        log("one press delivered twice (two paths): pinned \(beforeDup) -> \(n.pinned) (must have toggled exactly once)")
        ActionRouter.dedupeInterval = 0
        press(.pin)

        // A REAL key press, posted to the event queue so AppKit dispatches it down EVERY path it
        // has (the local monitor and the main menu's key equivalent). The checks above call
        // handleShortcut directly, which exercises one path only and hides double-fires.
        ActionRouter.dedupeInterval = 0.25
        ActionRouter.resetDedupeMemory()
        NoteCardView.collapseRunCount = 0
        let realBefore = n.collapsed
        if let e = key(ShortcutStore.shared.combo(for: .collapse), in: p) { NSApp.postEvent(e, atStart: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            log("REAL ⌥⌘K press (every dispatch path): collapsed \(realBefore) -> \(n.collapsed), toggleCollapse ran \(NoteCardView.collapseRunCount)x (must be 1)")
            if n.collapsed != realBefore { p.card.toggleCollapse() }
            ActionRouter.dedupeInterval = 0
            shortcutTailTest(p: p, n: n, then: next)
        }
    }

    private static func shortcutTailTest(p: NotePanel, n: Note, then next: @escaping () -> Void) {
        // Hold ⌥⌘N: Carbon path (simulated) fired in quick succession must make ONE note.
        let notesBefore = VaultStore.shared.notes.count
        for _ in 0..<5 { GlobalHotKeyCenter.shared.simulatePress(of: .newNote) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            log("5 rapid ⌥⌘N presses: notes \(notesBefore) -> \(VaultStore.shared.notes.count) (must be +1)")
            // Active note when the key window is something else (All Notes): falls back to the last focused note.
            AllNotesWindowController.shared.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let target = WindowManager.shared.focusedPanel
                log("with All Notes key, shortcut target = \(target?.note.title.debugDescription ?? "NONE (would toast 'Click a note first')")")
                next()
            }
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

    // MARK: Runner, end to end: real plugin → real bridge → real process, inside WKWebView

    private static func runnerTest(out: URL, then next: @escaping () -> Void) {
        let pm = PluginManager.shared
        log("plugins: " + pm.installed.map { "\($0.id) v\($0.manifest?.version ?? "?") enabled=\($0.enabled) valid=\($0.isValid)" }.joined(separator: ", "))

        // A command approved "earlier": written through the same TrustStore API a real approval uses. The
        // self-test has NO way to answer the approval sheet, so it never clicks an unapproved command.
        let approved = "echo runner-selftest-$((6*7)); echo to-stderr 1>&2"
        TrustStore.shared.approve(TrustKey(kind: .command, value: approved, cwd: NSHomeDirectory()))
        let body = "# Runner test\n\nSome text.\n\n```runner\nlabel: Approved job\nrun: \(approved)\n```\n\n```runner\nlabel: Unapproved job\nrun: echo never-runs-without-approval\n```\n"
        let note = VaultStore.shared.createNote(body: body, frame: WindowManager.shared.nextCardFrame(size: NSSize(width: 380, height: 330)))
        let panel = WindowManager.shared.open(note, focus: true)
        panel.card.debugExpandActionBar()

        let js = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        for (let i = 0; i < 60 && document.querySelectorAll('.runner').length < 2; i++) await sleep(100);
        await sleep(600);
        const out = {};
        out.blocks = document.querySelectorAll('.runner').length;
        out.rawFenceHidden = !document.querySelector('.cm-content').textContent.includes('```runner');
        out.badges = [...document.querySelectorAll('.rn-badge')].map(e => e.textContent);
        out.playGlyphs = document.querySelectorAll('.rn-run svg.rn-play').length;
        out.outputCollapsed = [...document.querySelectorAll('.rn-out')].every(e => e.hidden);
        document.querySelectorAll('.rn-run')[0].click();
        for (let i = 0; i < 80; i++) { await sleep(100); const c = document.querySelectorAll('.rn-chip')[0]; if (c && c.textContent.startsWith('exit')) break; }
        out.chip = document.querySelectorAll('.rn-chip')[0].textContent;
        out.output = document.querySelectorAll('.rn-body')[0].textContent.trim();
        out.stderrRed = !!document.querySelectorAll('.rn-body')[0].querySelector('.rn-err');
        out.badgesAfter = [...document.querySelectorAll('.rn-badge')].map(e => e.textContent);
        return JSON.stringify(out);
        """
        // The page needs time to load the module, then the plugin, then render.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            panel.card.editor.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let v): log("Runner in the real app: \(v)")
                case .failure(let e): log("Runner in the real app FAILED: \(e)")
                }
                log("running processes left after the run: \(PluginBridge.shared.activeRunCount)")
                let nowTrusted = TrustStore.shared.isTrusted(TrustKey(kind: .command, value: "echo never-runs-without-approval", cwd: NSHomeDirectory()))
                log("the unapproved command was approved by the test (must be false): \(nowTrusted)")
                PluginSettingsWindows.shared.show(pluginID: "runner", title: "Runner")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if let w = NSApp.windows.first(where: { $0.title == "Runner Settings" }) {
                        snapshot(window: w, to: out.appendingPathComponent("plugin-settings.png")) { next() }
                    } else { next() }
                }
            }
        }
    }

    /// End to end for link previews, opt-in via PINTACK_LINKPREVIEW_URL so the self-test never
    /// contacts anything on its own. Point it at a local server to exercise the whole path: Swift
    /// fetches, parses the og: tags, saves the thumbnail into the vault, and the card renders from
    /// that file with the page's CSP still refusing anything remote.
    private static func linkPreviewTest(out: URL, then next: @escaping () -> Void) {
        guard let url = ProcessInfo.processInfo.environment["PINTACK_LINKPREVIEW_URL"], !url.isEmpty else { return next() }
        // Turn the setting on FIRST and let the settings change settle: it reloads open editors,
        // which would tear down the JS context this test is waiting in.
        AppSettings.shared.linkPreviews = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { linkPreviewTestBody(url: url, out: out, then: next) }
    }

    private static func linkPreviewTestBody(url: String, out: URL, then next: @escaping () -> Void) {
        let note = VaultStore.shared.createNote(body: "# Link preview\n\n\(url)\n",
                                                frame: WindowManager.shared.nextCardFrame(size: NSSize(width: 380, height: 300)))
        let panel = WindowManager.shared.open(note, focus: false)
        let js = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        for (let i = 0; i < 120 && !document.querySelector('.cm-link-card'); i++) await sleep(100);
        const card = document.querySelector('.cm-link-card');
        if (!card) return JSON.stringify({ card: false, text: document.querySelector('.cm-content').textContent.slice(0, 120) });
        const img = card.querySelector('.cm-link-thumb');
        const pick = s => { const e = card.querySelector(s); return e ? e.textContent : null; };
        return JSON.stringify({
          card: true,
          title: pick('.cm-link-title'),
          summary: pick('.cm-link-summary'),
          domain: pick('.cm-link-domain'),
          thumb: img ? img.getAttribute('src') : null,
          thumbLoaded: img ? (img.complete && img.naturalWidth > 0) : false,
          closeHidden: getComputedStyle(card.querySelector('.cm-link-close')).opacity,
        });
        """
        // The page is still loading right after open(); calling into it now would have the context
        // replaced under the waiting promise ("completion handler is no longer reachable").
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        panel.card.editor.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): log("link preview card: \(value as? String ?? "nil")")
            case .failure(let error): log("link preview card: FAILED \(error)")
            }
            // Dismissing must leave the plain URL behind, and must stick.
            let dismissJS = """
            const card = document.querySelector('.cm-link-card');
            const close = card && card.querySelector('.cm-link-close');
            const steps = { hasCard: !!card, hasClose: !!close };
            if (close) {
              try { close.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })); steps.dispatched = true; }
              catch (e) { steps.error = String(e); }
            }
            await new Promise(r => setTimeout(r, 700));
            steps.cardGone = !document.querySelector('.cm-link-card');
            steps.showsURL = document.querySelector('.cm-content').textContent.includes('\(url)');
            return JSON.stringify(steps);
            """
            panel.card.editor.callAsyncJavaScript(dismissJS, arguments: [:], in: nil, in: .page) { r2 in
                if case .success(let v) = r2 { log("link preview ✕ dismiss: \(v as? String ?? "nil")") }
                log("dismissal recorded in Swift = \(LinkPreviewStore.shared.isDismissed(noteID: note.id, url: url))")
                snapshot(window: panel, to: out.appendingPathComponent("link-preview.png")) { next() }
            }
        }
        }
    }

    /// The crop/resize sheet an image goes through on its way into a note.
    private static func imageCropTest(out: URL, then next: @escaping () -> Void) {
        let size = NSSize(width: 420, height: 260)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(calibratedRed: 0.13, green: 0.35, blue: 0.62, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.24, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 130, y: 50, width: 160, height: 160)).fill()
        image.unlockFocus()

        ImageCropPanel.present(image: image, over: nil) { data, _ in
            log("image crop sheet: returned \(data?.count ?? 0) bytes")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let panel = NSApp.windows.first(where: { $0.title == "Insert Image" }) else {
                log("image crop sheet: NOT SHOWN"); return next()
            }
            let rendered = ImageCropPanel.png(from: image, crop: NSRect(x: 120, y: 40, width: 180, height: 180),
                                              size: NSSize(width: 90, height: 90))
            log("image crop sheet: shown \(Int(panel.frame.width))x\(Int(panel.frame.height)) pt; "
                + "a 180x180 crop resized to 90x90 produced \(rendered?.count ?? 0) bytes")
            snapshot(window: panel, to: out.appendingPathComponent("image-crop.png")) {
                panel.close()
                next()
            }
        }
    }

    private static func renderWindows(out: URL) {
        runnerTest(out: out) { linkPreviewTest(out: out) { imageCropTest(out: out) { renderWindowsNow(out: out) } } }
    }

    private static func renderWindowsNow(out: URL) {
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
            // Reproduce the reported bug: a DARK outline color used to tint Settings' labels and buttons
            // the same dark red on a dark window, making them unreadable.
            AppSettings.shared.outlineColorHex = "#5A1F1A"
            SettingsView.initialPane = ProcessInfo.processInfo.environment["PINTACK_SETTINGS_PANE"].flatMap(SettingsView.Pane.init(rawValue:)) ?? .plugins
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
