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
        // Rich text: the pasteboard carries BOTH flavours, exactly as a browser copy does. The
        // editor must take the HTML one and write Markdown, not flatten it to the plain string.
        general.clearContents()
        general.setString("<h3>Rollout</h3><ul><li>Pilot <b>ring 1</b></li></ul>", forType: .html)
        general.setString("Rollout Pilot ring 1", forType: .string)
        p2m.makeKeyAndOrderFront(nil); p2m.makeFirstResponder(p2m.card.editor)
        let handled = NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            p2m.card.editor.evaluateJavaScript("(()=>{const d=window.__pintack._view.state.doc.toString();"
                + "return JSON.stringify({markdown: d.includes('### Rollout') && d.includes('- Pilot **ring 1**'),"
                + " flattened: d.includes('Rollout Pilot ring 1')})})()") { r, _ in
                log("rich text paste → Markdown: \(r ?? "nil") (markdown must be true, flattened false)")
            }
            p2m.card.editor.evaluateJavaScript("window.__pintack._view.state.doc.toString().includes('Rollout')") { r, _ in
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

    /// Images are edited inside the note: click one and it gets corner handles, a crop tool and a
    /// bin. This drives all three with real mouse events in the page and checks what reaches the
    /// Markdown, because "the handles appear" is not the same as "the picture actually changed".
    private static func imageEditTest(out: URL, then next: @escaping () -> Void) {
        // A 200x120 picture: left half red, right half blue.
        let size = NSSize(width: 200, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill();  NSRect(x: 0, y: 0, width: 100, height: 120).fill()
        NSColor.blue.setFill(); NSRect(x: 100, y: 0, width: 100, height: 120).fill()
        image.unlockFocus()
        guard let png = ImageEditing.png(from: image, crop: nil, size: nil),
              let path = VaultStore.shared.writeAttachment(png, ext: "png") else { log("image edit: NO ATTACHMENT"); return next() }

        let note = VaultStore.shared.createNote(body: "# Image\n\n![shot](\(path))\n",
                                                frame: WindowManager.shared.nextCardFrame(size: NSSize(width: 420, height: 360)))
        let panel = WindowManager.shared.open(note, focus: false)

        let js = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const view = window.__pintack._view;
        const at = s => document.querySelector(s);
        for (let i = 0; i < 60 && !at('.cm-image'); i++) await sleep(100);
        let img = at('.cm-image');
        if (!img) return JSON.stringify({ error: 'no image rendered' });
        for (let i = 0; i < 40 && !img.complete; i++) await sleep(100);
        const steps = { natural: img.naturalWidth + 'x' + img.naturalHeight };

        // Click through REAL hit testing: whatever is painted on top receives it, exactly as a
        // mouse would. Dispatching straight at an element hid a bug where the crop shade covered
        // the tick and cross, so they rendered but could never be clicked.
        const clickAt = (x, y) => {
          const el = document.elementFromPoint(x, y);
          if (!el) return 'nothing';
          el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: x, clientY: y, button: 0 }));
          // Name what the click actually LANDED on. An SVG's className is an object, so walk up to
          // the nearest thing with a real class name.
          const named = el.closest('.cm-image-tool, .cm-crop-shade, .cm-crop-box, .cm-image-wrap, .cm-line');
          return named ? named.className : (el.tagName || 'unknown');
        };
        const press = (el, x, y, type) => el.dispatchEvent(new MouseEvent(type, { bubbles: true, clientX: x, clientY: y, button: 0 }));

        // 1. One click selects it: handles and the two tools appear.
        let box = img.getBoundingClientRect();
        press(at('.cm-image-wrap'), box.left + box.width / 2, box.top + box.height / 2, 'mousedown');
        await sleep(350);
        steps.handles = document.querySelectorAll('.cm-image-handle').length;
        steps.tools = document.querySelectorAll('.cm-image-tool').length;

        // 2. Drag the bottom-right handle left to make it narrower.
        const handle = at('.cm-image-handle-se');
        // Selecting rebuilt the widget, so the old node is detached and measures zero: re-query.
        img = at('.cm-image');
        box = img.getBoundingClientRect();
        steps.widthBefore = Math.round(box.width);
        press(handle, box.right, box.bottom, 'mousedown');
        document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: box.right - 60, clientY: box.bottom }));
        document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
        await sleep(400);
        steps.markdownAfterResize = view.state.doc.toString().split('\\n').find(l => l.startsWith('!['));
        steps.widthAfter = Math.round(at('.cm-image').getBoundingClientRect().width);
        return JSON.stringify(steps);
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            panel.card.editor.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let v): log("image edit — select + resize: \(v as? String ?? "nil")")
                case .failure(let e): log("image edit — select + resize: FAILED \(e)")
                }
                imageCropStep(note: note, panel: panel, out: out, then: next)
            }
        }
    }

    /// Crops to the right-hand (blue) half and checks the pixels that land in the vault.
    private static func imageCropStep(note: Note, panel: NotePanel, out: URL, then next: @escaping () -> Void) {
        let js = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const view = window.__pintack._view;
        const at = s => document.querySelector(s);
        // Click through REAL hit testing: whatever is painted on top receives it, exactly as a
        // mouse would. Dispatching straight at an element hid a bug where the crop shade covered
        // the tick and cross, so they rendered but could never be clicked.
        const clickAt = (x, y) => {
          const el = document.elementFromPoint(x, y);
          if (!el) return 'nothing';
          el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: x, clientY: y, button: 0 }));
          // Name what the click actually LANDED on. An SVG's className is an object, so walk up to
          // the nearest thing with a real class name.
          const named = el.closest('.cm-image-tool, .cm-crop-shade, .cm-crop-box, .cm-image-wrap, .cm-line');
          return named ? named.className : (el.tagName || 'unknown');
        };
        const press = (el, x, y, type) => el.dispatchEvent(new MouseEvent(type, { bubbles: true, clientX: x, clientY: y, button: 0 }));
        const steps = {};

        // Re-select (the resize rebuilt the widget), then open crop.
        let img = at('.cm-image');
        let box = img.getBoundingClientRect();
        press(at('.cm-image-wrap'), box.left + box.width / 2, box.top + box.height / 2, 'mousedown');
        await sleep(300);
        const cropButton = [...document.querySelectorAll('.cm-image-tool')][0];
        let r = cropButton.getBoundingClientRect();
        steps.cropButtonHit = clickAt(r.left + r.width / 2, r.top + r.height / 2);
        await sleep(300);
        steps.cropModeOpen = !!at('.cm-crop-shade');

        // Drag a box over the RIGHT half of the picture.
        img = at('.cm-image');
        box = img.getBoundingClientRect();
        const shade = at('.cm-crop-shade');
        press(shade, box.left + box.width / 2 + 2, box.top + 2, 'mousedown');
        document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: box.right - 2, clientY: box.bottom - 2 }));
        document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
        await sleep(200);

        // Apply: the tick is the first tool while cropping. Clicked by POSITION, so anything
        // painted over it fails this test instead of silently eating the click.
        const tick = [...document.querySelectorAll('.cm-image-tool')][0];
        r = tick.getBoundingClientRect();
        steps.tickRect = [Math.round(r.width), Math.round(r.height)];
        steps.tickHit = clickAt(r.left + r.width / 2, r.top + r.height / 2);
        for (let i = 0; i < 60; i++) {
          await sleep(100);
          const line = view.state.doc.toString().split('\\n').find(l => l.startsWith('!['));
          if (line && !line.includes(window.__cropStartPath)) { steps.markdownAfterCrop = line; break; }
        }
        if (!steps.markdownAfterCrop) steps.markdownAfterCrop = view.state.doc.toString().split('\\n').find(l => l.startsWith('!['));
        return JSON.stringify(steps);
        """
        let seed = "window.__cropStartPath = \(jsString(currentImagePath(note) ?? ""));"
        panel.card.editor.evaluateJavaScript(seed, completionHandler: nil)
        panel.card.editor.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let v): log("image edit — crop: \(v as? String ?? "nil")")
            case .failure(let e): log("image edit — crop: FAILED \(e)")
            }
            // Second crop, applied with the RETURN key rather than the tick, to prove the keyboard
            // path reaches Swift too (closing crop mode alone would not: Escape closes it as well).
            let enterJS = """
            const sleep = ms => new Promise(r => setTimeout(r, ms));
            const at = s => document.querySelector(s);
            const before = window.__pintack._view.state.doc.toString().split('\\n').find(l => l.startsWith('!['));
            let img = at('.cm-image');
            let b = img.getBoundingClientRect();
            at('.cm-image-wrap').dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: b.left + b.width / 2, clientY: b.top + b.height / 2, button: 0 }));
            await sleep(300);
            const cropBtn = [...document.querySelectorAll('.cm-image-tool')][0].getBoundingClientRect();
            document.elementFromPoint(cropBtn.left + cropBtn.width / 2, cropBtn.top + cropBtn.height / 2)
              .dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: cropBtn.left + 2, clientY: cropBtn.top + 2, button: 0 }));
            await sleep(300);
            img = at('.cm-image'); b = img.getBoundingClientRect();
            const shade = at('.cm-crop-shade');
            shade.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: b.left + 4, clientY: b.top + 4, button: 0 }));
            document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: b.left + b.width / 2, clientY: b.bottom - 4 }));
            document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
            await sleep(200);
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
            for (let i = 0; i < 60; i++) {
              await sleep(100);
              const now = window.__pintack._view.state.doc.toString().split('\\n').find(l => l.startsWith('!['));
              if (now !== before) return JSON.stringify({ appliedByReturn: true, before, after: now });
            }
            return JSON.stringify({ appliedByReturn: false, before });
            """
            panel.card.editor.callAsyncJavaScript(enterJS, arguments: [:], in: nil, in: .page) { r in
                if case .success(let v) = r { log("image edit — crop applied with Return: \(v as? String ?? "nil")") }
                if case .failure(let e) = r { log("image edit — crop applied with Return: FAILED \(e)") }
            }
            // What actually landed in the vault: the crop must be the BLUE half, half as wide.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let file = VaultStore.shared.vaultURL.appendingPathComponent(currentImagePath(note) ?? "")
                if let data = try? Data(contentsOf: file), let rep = NSBitmapImageRep(data: data) {
                    func sample(_ fx: Double, _ fy: Double) -> String {
                        let x = min(rep.pixelsWide - 1, max(0, Int(Double(rep.pixelsWide) * fx)))
                        let y = min(rep.pixelsHigh - 1, max(0, Int(Double(rep.pixelsHigh) * fy)))
                        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return "none" }
                        if c.blueComponent > 0.5 && c.redComponent < 0.4 { return "blue" }
                        if c.redComponent > 0.5 && c.blueComponent < 0.4 { return "red" }
                        return String(format: "rgb(%.2f,%.2f,%.2f)", c.redComponent, c.greenComponent, c.blueComponent)
                    }
                    log("image edit — cropped file: \(currentImagePath(note) ?? "?"), \(rep.pixelsWide)x\(rep.pixelsHigh) px; "
                        + "samples left=\(sample(0.2, 0.5)) middle=\(sample(0.5, 0.5)) right=\(sample(0.8, 0.5)) "
                        + "(cropping the right half must give all blue, ~half the original 400px width)")
                } else {
                    log("image edit — cropped file: NOT FOUND")
                }
                imageDeleteStep(note: note, panel: panel, out: out, then: next)
            }
        }
    }

    private static func imageDeleteStep(note: Note, panel: NotePanel, out: URL, then next: @escaping () -> Void) {
        let js = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const view = window.__pintack._view;
        const at = s => document.querySelector(s);
        // Click through REAL hit testing: whatever is painted on top receives it, exactly as a
        // mouse would. Dispatching straight at an element hid a bug where the crop shade covered
        // the tick and cross, so they rendered but could never be clicked.
        const clickAt = (x, y) => {
          const el = document.elementFromPoint(x, y);
          if (!el) return 'nothing';
          el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: x, clientY: y, button: 0 }));
          // Name what the click actually LANDED on. An SVG's className is an object, so walk up to
          // the nearest thing with a real class name.
          const named = el.closest('.cm-image-tool, .cm-crop-shade, .cm-crop-box, .cm-image-wrap, .cm-line');
          return named ? named.className : (el.tagName || 'unknown');
        };
        const press = (el, x, y, type) => el.dispatchEvent(new MouseEvent(type, { bubbles: true, clientX: x, clientY: y, button: 0 }));
        const img = at('.cm-image');
        if (!img) return JSON.stringify({ error: 'no image to delete' });
        const box = img.getBoundingClientRect();
        press(at('.cm-image-wrap'), box.left + box.width / 2, box.top + box.height / 2, 'mousedown');
        await sleep(300);
        const tools = [...document.querySelectorAll('.cm-image-tool')];
        const bin = tools[tools.length - 1].getBoundingClientRect();
        const hit = clickAt(bin.left + bin.width / 2, bin.top + bin.height / 2);
        await sleep(400);
        return JSON.stringify({ binHit: hit, imageGone: !at('.cm-image'), markdownHasImage: view.state.doc.toString().includes('![') });
        """
        panel.card.editor.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let v): log("image edit — bin: \(v as? String ?? "nil")")
            case .failure(let e): log("image edit — bin: FAILED \(e)")
            }
            snapshot(window: panel, to: out.appendingPathComponent("image-edit.png")) { next() }
        }
    }

    /// The attachment path the note's image link currently points at.
    private static func currentImagePath(_ note: Note) -> String? {
        guard let line = note.body.components(separatedBy: "\n").first(where: { $0.hasPrefix("![") }),
              let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close
        else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    /// Freeze mode, and above all the way back OUT of it. A frozen note takes no clicks at all,
    /// so if the live snowflake corner were wrong the note could never be thawed in place.
    private static func freezeTest(then next: @escaping () -> Void) {
        guard let panel = WindowManager.shared.openPanels.first else { return next() }
        let note = panel.note
        let wasFrozen = note.frozen

        panel.card.perform(.freeze)
        let card = NotePanel.cardRect(forWindow: panel.frame)
        let corner = FreezeMode.liveCornerRect(of: panel)
        log("freeze: note.frozen = \(note.frozen), panel ignores the mouse = \(panel.ignoresMouseEvents)")
        log("freeze: thaw corner \(Int(corner.width))x\(Int(corner.height)) pt at the card's bottom-right; "
            + "inside the card = \(card.contains(NSPoint(x: corner.midX, y: corner.midY)))")

        // The pointer being over that corner must hand the mouse back, or there is no way out.
        panel.ignoresMouseEvents = !corner.contains(NSPoint(x: corner.midX, y: corner.midY))
        log("freeze: pointer over the corner → ignores the mouse = \(panel.ignoresMouseEvents) (must be false)")
        panel.ignoresMouseEvents = !corner.contains(NSPoint(x: card.minX + 5, y: card.midY))
        log("freeze: pointer over the middle → ignores the mouse = \(panel.ignoresMouseEvents) (must be true)")

        let onDisk = { (try? String(contentsOf: note.fileURL, encoding: .utf8)) ?? "" }
        SaveCoordinator.shared.flush(noteID: note.id)
        log("freeze: written to the note file = \(onDisk().contains("frozen: true"))")

        panel.card.perform(.freeze)
        log("freeze: thawed again → frozen = \(note.frozen), ignores the mouse = \(panel.ignoresMouseEvents)")
        if note.frozen != wasFrozen { panel.card.perform(.freeze) }
        next()
    }

    /// The reminder bell: it appears on todo notes only, and its popover writes the date into the
    /// note. Notification delivery itself is the system's business and is not simulated here.
    private static func reminderTest(out: URL, then next: @escaping () -> Void) {
        // A second todo with a longer list, so the todo tab has something with real progress in it.
        let other = VaultStore.shared.createNote(
            body: "@Todo Cert rotation\n\nRenew before the audit\n\n- [x] export\n- [x] sign\n- [x] stage\n- [ ] deploy\n- [ ] verify\n",
            tags: ["todo"], frame: WindowManager.shared.nextCardFrame(size: NSSize(width: 300, height: 220)))
        other.due = Date().addingTimeInterval(7200)
        other.remindOnTime = true
        VaultStore.shared.save(other)

        let todo = VaultStore.shared.createNote(body: "@Todo Ship the pilot\n\nFirst ring goes out Monday\n\n- [ ] one\n- [x] two\n", tags: ["todo"],
                                                frame: WindowManager.shared.nextCardFrame(size: NSSize(width: 330, height: 240)))
        let plain = WindowManager.shared.openPanels.first { !$0.note.isTodo }
        let panel = WindowManager.shared.open(todo, focus: false)
        panel.card.debugCollapseActionBar()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            log("reminder bell: shown on a todo note = \(!panel.card.debugBellHidden), "
                + "on a plain note = \(plain.map { !$0.card.debugBellHidden } ?? false) (must be true, false)")

            // Set a date the way the popover does, then check what reached the file.
            todo.due = Date().addingTimeInterval(3600)
            todo.remindOnTime = true
            todo.remindAhead = Note.normalizedAhead("30m")
            VaultStore.shared.save(todo)
            panel.card.updateReminderGlyph()
            SaveCoordinator.shared.flush(noteID: todo.id)
            let onDisk = (try? String(contentsOf: todo.fileURL, encoding: .utf8)) ?? ""
            log("reminder written to the note: due = \(onDisk.contains("due:")), onTime = \(onDisk.contains("remindOnTime: true")), "
                + "ahead = \(onDisk.contains("remindAhead: 30m")); scheduled moments = \(todo.reminderDates.map(\.id))")

            // Close anything already up, or the snapshot below catches the wrong popover.
            panel.card.debugDismissPopover()
            WindowManager.shared.openPanels.forEach { $0.card.debugDismissPopover() }
            panel.card.debugShowReminderPopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let popover = panel.card.debugPopoverWindow, popover.isVisible {
                    snapshot(window: popover, to: out.appendingPathComponent("reminder-popover.png")) {
                        panel.card.debugDismissPopover(); next()
                    }
                } else {
                    log("reminder popover: NOT SHOWN")
                    next()
                }
            }
        }
    }

    /// /find: the quick-open overlay. The point of it is that opening another note does NOT take
    /// you there — the caret has to come back to where the search started.
    private static func findTest(out: URL, then next: @escaping () -> Void) {
        let panels = WindowManager.shared.openPanels.sorted { $0.note.created < $1.note.created }
        guard let home = panels.first, panels.count > 1 else { return next() }
        home.makeKeyAndOrderFront(nil)

        let js = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const view = window.__pintack._view;
        view.focus();
        view.dispatch({ selection: { anchor: 5 } });
        const steps = { caretBefore: view.state.selection.main.anchor };

        // Ask for the list exactly as the /find slash command does.
        window.__pintack.receive({ type: "notes.list", noteId: null, payload: { notes: [] } });
        await sleep(100);
        window.webkit.messageHandlers.pintack.postMessage({ type: "notes.list", noteId: null, payload: {} });
        for (let i = 0; i < 40 && !document.querySelector('.cm-find-row'); i++) await sleep(100);

        const rows = [...document.querySelectorAll('.cm-find-title')].map(e => e.textContent);
        steps.rowsOffered = rows.length;
        steps.firstRows = rows.slice(0, 3);
        steps.searchBoxHasFocus = document.activeElement === document.querySelector('.cm-find-input');

        // Type something that should narrow it down, then open the top hit.
        const input = document.querySelector('.cm-find-input');
        input.value = 'runner';
        input.dispatchEvent(new Event('input', { bubbles: true }));
        await sleep(150);
        steps.afterTyping = [...document.querySelectorAll('.cm-find-title')].map(e => e.textContent);
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
        await sleep(400);
        steps.overlayClosed = !document.querySelector('.cm-find');
        steps.caretAfter = view.state.selection.main.anchor;
        return JSON.stringify(steps);
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            home.card.editor.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let v): log("/find overlay: \(v as? String ?? "nil")")
                case .failure(let e): log("/find overlay: FAILED \(e)")
                }
                // The note it opened must be on screen, but the CARET must still be in this note.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let key = NSApp.keyWindow as? NotePanel
                    log("/find: key window is still the note the search started in = \(key === home) "
                        + "(it opened '\(key?.note.title ?? "?")')")
                    next()
                }
            }
        }
    }

    /// Quick capture: the Services entry has to be declared and registered, and the capture itself
    /// has to produce a real note with the text intact.
    private static func quickCaptureTest(then next: @escaping () -> Void) {
        let services = Bundle.main.infoDictionary?["NSServices"] as? [[String: Any]] ?? []
        let entry = services.first
        log("quick capture: NSServices declared = \(services.count), "
            + "menu item = \((entry?["NSMenuItem"] as? [String: String])?["default"] ?? "MISSING"), "
            + "message = \(entry?["NSMessage"] as? String ?? "MISSING")")
        log("quick capture: services provider registered = \(NSApp.servicesProvider != nil), "
            + "responds to captureSelection = \((NSApp.servicesProvider as? NSObject)?.responds(to: Selector(("captureSelection:userData:error:"))) ?? false)")

        let before = VaultStore.shared.notes.count
        let note = QuickCapture.shared.capture("Rollout plan\nring 1 on Monday\nring 2 on Friday", from: "Safari")
        SaveCoordinator.shared.flush(noteID: note.id)
        let onDisk = (try? String(contentsOf: note.fileURL, encoding: .utf8)) ?? ""
        log("quick capture: notes \(before) -> \(VaultStore.shared.notes.count), title = \(note.title.debugDescription), "
            + "source written = \(onDisk.contains("source: \"Safari\"")), text kept = \(onDisk.contains("ring 2 on Friday"))")

        // ⌥⌘C has to reach it from any app, so it must be one of the global hotkeys.
        log("quick capture: \(ShortcutStore.shared.combo(for: .quickCapture).display) is global = \(ShortcutAction.quickCapture.isGlobal), "
            + "registered OSStatus = \(GlobalHotKeyCenter.shared.lastStatus[.quickCapture].map(String.init) ?? "not registered")")
        next()
    }

    private static func renderWindows(out: URL) {
        runnerTest(out: out) { linkPreviewTest(out: out) { imageEditTest(out: out) { freezeTest { reminderTest(out: out) { findTest(out: out) { quickCaptureTest { renderWindowsNow(out: out) } } } } } } }
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
