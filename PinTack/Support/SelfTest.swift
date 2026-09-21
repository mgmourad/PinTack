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

    /// Whether this launch is a self-test run, so the app can leave out anything that would take
    /// the keyboard away from it.
    static var isRequested: Bool { ProcessInfo.processInfo.environment["PINTACK_SELFTEST_DIR"] != nil }

    static func runIfRequested(appDelegate: AppDelegate, statusItem: StatusItemController?) {
        guard let dir = ProcessInfo.processInfo.environment["PINTACK_SELFTEST_DIR"] else { return }
        app = appDelegate
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { run(out: out, statusItem: statusItem) }
    }

    private static func log(_ s: String) { lines.append(s); NSLog("PinTack selftest: \(s)") }

    // MARK: Checks
    //
    // The report used to be prose that a person had to read and judge. That made it useless to
    // anyone who did not already know what "good" looked like, and it could not gate a build.
    // Every fact worth checking now goes through `check`, failures are collected, and the process
    // exits non-zero so this can run in CI.

    private static var failures: [String] = []
    private static var checksRun = 0

    /// Records one expectation. `detail` is always logged, so the report still reads as a story.
    @discardableResult
    static func check(_ what: String, _ passed: Bool, _ detail: String = "") -> Bool {
        checksRun += 1
        let line = (passed ? "PASS  " : "FAIL  ") + what + (detail.isEmpty ? "" : ": " + detail)
        log(line)
        if !passed { failures.append(what + (detail.isEmpty ? "" : ": " + detail)) }
        return passed
    }

    /// For values worth recording that nothing asserts on (sizes, ids, timings).
    static func note(_ what: String, _ detail: String) { log("      " + what + ": " + detail) }

    /// Reads one field out of a JSON string a page returned, for checking.
    static func field(_ json: String?, _ key: String) -> Any? {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object[key]
    }

    static func bool(_ json: String?, _ key: String) -> Bool { field(json, key) as? Bool ?? false }
    static func int(_ json: String?, _ key: String) -> Int { field(json, key) as? Int ?? -1 }
    static func text(_ json: String?, _ key: String) -> String { field(json, key) as? String ?? "" }

    private static func run(out: URL, statusItem: StatusItemController?) {
        // Take the foreground first. Several checks read the KEY window — whether /find gave focus
        // back, what a paste landed in — and they measure nothing at all if some other app (an
        // installed copy of PinTack, the terminal that started this) is in front.
        NSApp.activate(ignoringOtherApps: true)

        check("Dock icon shown (activation policy is regular)", NSApp.activationPolicy() == .regular)
        log("vault = \(VaultStore.shared.vaultURL.path)")
        log("notes in vault = \(VaultStore.shared.notes.count), open panels = \(WindowManager.shared.openPanels.count)")

        // Dock icon
        if let icon = NSApp.applicationIconImage {
            check("the app has a Dock icon", icon.size.width > 0, "\(Int(icon.size.width))x\(Int(icon.size.height)) pt")
            save(icon, to: out.appendingPathComponent("dock-icon.png"))
        } else { check("the app has a Dock icon", false, "MISSING") }

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

        // Every action's menu entry, with the key AppKit will show beside it. A shortcut that is
        // in the overlay but missing from the menus is half-wired.
        if let main = NSApp.mainMenu {
            var shown: [String] = []
            for top in main.items {
                for item in top.submenu?.items ?? [] where !item.keyEquivalent.isEmpty {
                    guard let raw = item.representedObject as? String, ShortcutAction(rawValue: raw) != nil else { continue }
                    var mods = ""
                    if item.keyEquivalentModifierMask.contains(.control) { mods += "⌃" }
                    if item.keyEquivalentModifierMask.contains(.option) { mods += "⌥" }
                    if item.keyEquivalentModifierMask.contains(.shift) { mods += "⇧" }
                    if item.keyEquivalentModifierMask.contains(.command) { mods += "⌘" }
                    shown.append("\(top.title)>\(item.title) \(mods)\(item.keyEquivalent.uppercased())")
                }
            }
            for wanted in [ShortcutAction.deleteNote, .allNotesByTag, .showTodos, .showTemplates, .showAllOnDesktop] {
                let hit = shown.first { $0.hasSuffix(ShortcutStore.shared.combo(for: wanted).display) }
                check("\(wanted.rawValue) has a menu entry with its shortcut", hit != nil, hit ?? "MISSING")
            }
        }

        // Hotkeys: registration status per global action, then push a simulated press
        // through the same Carbon handler path and check that a note appears.
        for (action, status) in GlobalHotKeyCenter.shared.lastStatus.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            check("global hotkey \(ShortcutStore.shared.combo(for: action).display) registers (\(action.rawValue))",
                  status == noErr, status == noErr ? "" : "OSStatus \(status)")
        }
        let before = VaultStore.shared.notes.count
        let delivered = GlobalHotKeyCenter.shared.simulatePress(of: .newNote)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            check("⌥⌘N through the Carbon handler makes exactly one note", delivered && VaultStore.shared.notes.count == before + 1,
                  "delivered=\(delivered), notes \(before) -> \(VaultStore.shared.notes.count)")
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
            // Tall enough to hold the whole sample at once: this note is the one photographed as
            // proof the renderer works, and a default-sized card cuts it off at the checklist.
            p2.applyCardFrame(NSRect(x: p2.note.cardFrame.minX, y: p2.note.cardFrame.maxY - 560,
                                     width: 440, height: 560))
            p2.card.refreshFromNote()
            p2.card.editor.reloadBody()
        }

        let js = "(()=>{const v=window.__pintack._view; v.dispatch({changes:{from:v.state.doc.length, insert:'\\n\\nBRIDGE-TEST-OK #selftest'}}); return v.state.doc.length})()"
        target.card.editor.evaluateJavaScript(js) { result, error in
            log("JS edit dispatched: result=\(String(describing: result)) error=\(String(describing: error))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            let onDisk = (try? String(contentsOf: target.note.fileURL, encoding: .utf8)) ?? ""
            check("typing reaches the file (JS → Swift → atomic save)", onDisk.contains("BRIDGE-TEST-OK"))
            check("an inline #tag is merged into the frontmatter", onDisk.contains("selftest"))
            codeHighlightTest(panels: panels, out: out) { shortcutTest(out: out) { interactionTest(out: out) } }
        }
    }

    /// The ```powershell block in `sampleBody`, highlighted inside the real web view. This is the only
    /// place that proves the page's CSP lets editor.js import a language module at run time: over the
    /// dev server the CSP is rewritten, so a browser check cannot tell us.
    private static func codeHighlightTest(panels: [NotePanel], out: URL, then next: @escaping () -> Void) {
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
        // How light a colour is, 0..1, so the checks can talk about dark and light panels.
        const lum = (c) => { const m = (c.match(/[\\d.]+/g) || [0,0,0]).map(Number);
          return (0.2126*m[0] + 0.7152*m[1] + 0.0722*m[2]) / 255; };
        const block = document.querySelector('.cm-codeblock');
        const quote = document.querySelector('.cm-quote');
        return JSON.stringify({
          badge: badge ? badge.dataset.lang : null,
          logo,
          tokens: spans.length,
          distinctColours: new Set(spans.map(colour)).size,
          codePaper: document.documentElement.dataset.codePaper,
          blockBackground: block ? getComputedStyle(block).backgroundColor : null,
          blockLuminance: block ? lum(getComputedStyle(block).backgroundColor).toFixed(2) : null,
          // The dimmest token in the block. On a dark panel every one of them has to be light.
          dimmestToken: spans.length ? Math.min(...spans.map(e => lum(colour(e)))).toFixed(2) : null,
          quoteBar: quote ? getComputedStyle(quote).borderLeftColor : null,
          badgeColour: badge ? getComputedStyle(badge, '::after').color : null,
          badgeLuminance: badge ? lum(getComputedStyle(badge, '::after').color).toFixed(2) : null,
        });
        """
        panels[1].card.editor.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            let json = (try? result.get()) as? String
            check("a fenced block is syntax highlighted", int(json, "tokens") > 0 && int(json, "distinctColours") > 1,
                  json ?? "no result")
            check("the language logo loads under the page's CSP", text(json, "logo").contains(".svg"), text(json, "logo"))
            check("the block carries its language badge", text(json, "badge") == "PowerShell", text(json, "badge"))

            // This note's paper is a light blue (#A3D5FF), so a block that followed the paper the
            // way it used to would come out a pale wash. It is its own dark panel now. Measured
            // in Swift, on the panel composited over the paper: the page can only report the
            // colour the panel DECLARES, which says nothing while it is translucent.
            let panelOnLight = panels[1].card.editor.compositedCodeBlockColor.relativeLuminance
            check("a fenced block is a dark panel even on a light note",
                  panelOnLight < 0.1,
                  String(format: "%@ over the paper reads %.3f", text(json, "blockBackground"), panelOnLight))
            // And the stylesheet really uses that colour. Everything above is measured in Swift and
            // would go on passing if .cm-codeblock had quietly fallen back to the note's surface.
            // Compared as numbers: the two sides format the alpha differently (0.92 against 0.920).
            func channels(_ s: String) -> [Double] {
                s.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap(Double.init)
            }
            let drawn = channels(text(json, "blockBackground"))
            let sent = channels(panels[1].card.editor.debugCodeBlockCSS)
            check("the block is painted with the panel colour, not the note's surface wash",
                  drawn.count == sent.count && zip(drawn, sent).allSatisfy { abs($0 - $1) < 0.01 },
                  "page says \(text(json, "blockBackground")), Swift sent \(panels[1].card.editor.debugCodeBlockCSS)")
            check("the code palette follows the panel, not the note's paper",
                  text(json, "codePaper") == "dark", text(json, "codePaper"))
            // The whole point of the palette switch: dark tokens on a dark panel would be the same
            // black-on-black fault the slash menu had.
            let dimmest = Double(text(json, "dimmestToken")) ?? 0
            check("every token stays readable on the dark panel",
                  dimmest > 0.3, "dimmest token luminance \(text(json, "dimmestToken"))")

            // The badge rides ON the dark panel, so it must not take the note's own dim colour.
            let badge = Double(text(json, "badgeLuminance")) ?? 0
            check("the language badge is readable on the panel it sits on", badge > 0.3,
                  "\(text(json, "badgeColour")), luminance \(text(json, "badgeLuminance"))")

            let bar = text(json, "quoteBar")
            let rgb = bar.split(whereSeparator: { !"0123456789".contains($0) }).compactMap { Double($0) }
            check("a blockquote's bar is bright red", rgb.count >= 3 && rgb[0] > 200 && rgb[1] < 110 && rgb[2] < 110,
                  bar)
            // Worth a picture of its own: this note is the only one carrying every construct at
            // once, and by the end of the run it has been closed and reopened several times over.
            snapshot(window: panels[1], to: out.appendingPathComponent("code-and-quote.png")) {
                darkNoteCodeBlockCheck(panel: panels[1], then: next)
            }
        }
    }

    /// The other half of the panel's job: on a DARK note it must still read as a panel and not melt
    /// into the paper. Measured rather than eyeballed, because the two are close by design.
    private static func darkNoteCodeBlockCheck(panel: NotePanel, then next: @escaping () -> Void) {
        let wasLight = panel.note.colorHex
        panel.note.colorHex = "#2F3140"                 // a dark paper
        panel.card.refreshFromNote()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let js = "return JSON.stringify({ codePaper: document.documentElement.dataset.codePaper });"
            panel.card.editor.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                let json = (try? result.get()) as? String
                let paper = panel.note.color.relativeLuminance
                let block = panel.card.editor.compositedCodeBlockColor.relativeLuminance
                check("on a dark note the panel is darker still, not lost in the paper",
                      block < paper && text(json, "codePaper") == "dark",
                      String(format: "paper %.3f, panel %.3f", paper, block))
                panel.note.colorHex = wasLight
                panel.card.refreshFromNote()
                next()
            }
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
                let j = r as? String
                check("pasted rich text becomes Markdown instead of being flattened",
                      bool(j, "markdown") && !bool(j, "flattened"), j ?? "no result")
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
        let pinned0 = n.pinned; press(.pin); check("⌥⌘P pins the focused note", n.pinned != pinned0)
        press(.pin)
        let col0 = n.collapsed; press(.collapse); check("⌥⌘K collapses the focused note", n.collapsed != col0); press(.collapse)
        let mode0 = p.card.editor.mode; press(.toggleMode); check("⌥⌘M switches Live Preview / Source", p.card.editor.mode != mode0); press(.toggleMode)
        press(.color3)
        check("⌥⌘3 applies the third swatch", n.colorHex.caseInsensitiveCompare(NotePalette.set(for: n.theme)[2].hex) == .orderedSame,
              "got \(n.colorHex)")
        let op0 = n.opacity; press(.lessOpaque); check("⌥⌘, fades the note", n.opacity < op0); press(.moreOpaque)

        // Key repeat: a held ⌥⌘P must act once, not flip back and forth.
        let before = n.pinned
        press(.pin); press(.pin, rep: true); press(.pin, rep: true); press(.pin, rep: true)
        check("a HELD ⌥⌘P toggles once, not once per repeat", n.pinned != before)
        press(.pin, rep: false)

        // The same press arriving by two paths (Carbon + key monitor) must act ONCE.
        ActionRouter.dedupeInterval = 0.25
        ActionRouter.resetDedupeMemory()
        let beforeDup = n.pinned
        press(.pin); press(.pin)
        check("one press arriving by two paths acts once", n.pinned != beforeDup)
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
            check("a REAL ⌥⌘K press collapses the note exactly once",
                  n.collapsed != realBefore && NoteCardView.collapseRunCount == 1,
                  "ran \(NoteCardView.collapseRunCount)x")
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
            check("five rapid ⌥⌘N presses make one note", VaultStore.shared.notes.count == notesBefore + 1,
                  "notes \(notesBefore) -> \(VaultStore.shared.notes.count)")
            // Active note when the key window is something else (All Notes): falls back to the last focused note.
            AllNotesWindowController.shared.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let target = WindowManager.shared.focusedPanel
                check("with All Notes key, note shortcuts still find a target", target != nil,
                      target?.note.title ?? "none")
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
            let card = (try? result.get()) as? String
            check("a pasted link renders a card with its title and thumbnail",
                  bool(card, "card") && !text(card, "title").isEmpty && bool(card, "thumbLoaded"), card ?? "no result")
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
                let j = (try? r2.get()) as? String
                check("the card's ✕ restores the plain URL and sticks",
                      bool(j, "cardGone") && bool(j, "showsURL")
                      && LinkPreviewStore.shared.isDismissed(noteID: note.id, url: url), j ?? "no result")
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
                let j = (try? result.get()) as? String
                check("clicking an image gives it 4 handles and 2 tools",
                      int(j, "handles") == 4 && int(j, "tools") == 2, j ?? "no result")
                check("dragging a corner resizes the image and writes the width",
                      int(j, "widthAfter") < int(j, "widthBefore") && text(j, "markdownAfterResize").contains("|"),
                      text(j, "markdownAfterResize"))
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
            let j = (try? result.get()) as? String
            check("the crop tool opens and its tick is clickable",
                  bool(j, "cropModeOpen") && text(j, "tickHit") == "cm-image-tool", j ?? "no result")
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
                let j = (try? r.get()) as? String
                check("Return applies a crop as well as the tick", bool(j, "appliedByReturn"), j ?? "no result")
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
                    let allBlue = sample(0.2, 0.5) == "blue" && sample(0.5, 0.5) == "blue" && sample(0.8, 0.5) == "blue"
                    check("cropping the right half keeps the right PIXELS, not just the right size",
                          allBlue && rep.pixelsWide < 260,
                          "\(rep.pixelsWide)x\(rep.pixelsHigh) px, samples \(sample(0.2, 0.5))/\(sample(0.5, 0.5))/\(sample(0.8, 0.5))")
                } else {
                    check("the cropped file is written into the vault", false, "NOT FOUND")
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
            let j = (try? result.get()) as? String
            check("the bin removes the image and its Markdown",
                  bool(j, "imageGone") && !bool(j, "markdownHasImage"), j ?? "no result")
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
        check("freezing makes the note ignore the mouse", note.frozen && panel.ignoresMouseEvents)
        check("the thaw corner is inside the card", card.contains(NSPoint(x: corner.midX, y: corner.midY)),
              "\(Int(corner.width))x\(Int(corner.height)) pt")

        // The pointer being over that corner must hand the mouse back, or there is no way out.
        panel.ignoresMouseEvents = !corner.contains(NSPoint(x: corner.midX, y: corner.midY))
        check("a pointer over the thaw corner hands the mouse back", !panel.ignoresMouseEvents)
        panel.ignoresMouseEvents = !corner.contains(NSPoint(x: card.minX + 5, y: card.midY))
        check("a pointer over the middle still passes through", panel.ignoresMouseEvents)

        let onDisk = { (try? String(contentsOf: note.fileURL, encoding: .utf8)) ?? "" }
        SaveCoordinator.shared.flush(noteID: note.id)
        check("frozen is written to the note file", onDisk().contains("frozen: true"))

        panel.card.perform(.freeze)
        check("thawing puts it back", !note.frozen && !panel.ignoresMouseEvents)
        if note.frozen != wasFrozen { panel.card.perform(.freeze) }
        next()
    }

    /// The reminder bell: it appears on todo notes only, and its popover writes the date into the
    /// note. Notification delivery itself is the system's business and is not simulated here.
    private static func reminderTest(out: URL, then next: @escaping () -> Void) {
        // A note with more tags than a narrow card can lay out, to exercise the "+N" pill.
        let tagged = VaultStore.shared.createNote(
            body: "@Todo Cert rotation checks\n\n- [x] export\n- [x] sign\n- [ ] deploy\n",
            tags: ["todo", "priority", "intune", "azure", "q4"],
            frame: WindowManager.shared.nextCardFrame(size: NSSize(width: 250, height: 200)))
        VaultStore.shared.save(tagged)
        let taggedPanel = WindowManager.shared.open(tagged, focus: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let pills = taggedPanel.card.debugTagPills
            let hits = pills.hitTest(pills.convert(NSPoint(x: pills.overflowRect.midX, y: pills.overflowRect.midY), to: taggedPanel.card)) != nil
            check("too many tags collapse into a clickable +N pill", !pills.overflowRect.isEmpty && hits,
                  "\(tagged.tags.count) tags")
        }

        // A template, so the templates tab and the @ menu have something in them.
        let template = VaultStore.shared.createNote(
            body: "# Change record\n\n| Step | Owner |\n| --- | --- |\n| Raise | me |\n",
            frame: WindowManager.shared.nextCardFrame(size: NSSize(width: 300, height: 200)))
        template.templateName = "change-record"
        VaultStore.shared.save(template)

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
            check("the reminder bell is on todo notes and only todo notes",
                  !panel.card.debugBellHidden && !(plain.map { !$0.card.debugBellHidden } ?? false))

            // Set a date the way the popover does, then check what reached the file.
            todo.due = Date().addingTimeInterval(3600)
            todo.remindOnTime = true
            todo.remindAhead = Note.normalizedAhead("30m")
            VaultStore.shared.save(todo)
            panel.card.updateReminderGlyph()
            SaveCoordinator.shared.flush(noteID: todo.id)
            let onDisk = (try? String(contentsOf: todo.fileURL, encoding: .utf8)) ?? ""
            check("a due date and both reminders reach the note file",
                  onDisk.contains("due:") && onDisk.contains("remindOnTime: true") && onDisk.contains("remindAhead: 30m"))
            check("both reminder moments are scheduled", todo.reminderDates.count == 2,
                  "\(todo.reminderDates.map(\.id))")

            // What actually reaches the notification store, which the self-test can look inside
            // now that it has one of its own. It used to check only the dates written in the note,
            // which is why nobody noticed every run was posting real reminders to whoever was
            // logged in, an hour after the run.
            check("the self-test never touches the real notification centre",
                  Reminders.shared.store is MemoryReminderStore,
                  String(describing: Swift.type(of: Reminders.shared.store)))
            Reminders.shared.schedule(todo, requestPermission: false)
            // Scheduling asks for the authorisation status first, so it lands a couple of main-queue
            // hops later, not on this one.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                reminderStoreChecks(todo: todo)
                reminderPopoverSnapshot(panel: panel, out: out, then: next)
            }
        }
    }

    private static func reminderStoreChecks(todo: Note) {
        guard let store = Reminders.shared.store as? MemoryReminderStore else { return }
        let onTime = Reminders.identifier(todo, "ontime")
        let ahead = Reminders.identifier(todo, "ahead")
        check("a reminder is queued for the due time and one 30 minutes before",
              store.requests[onTime] != nil && store.requests[ahead] != nil,
              "\(store.requests.keys.sorted())")
        if let due = store.fireDate(onTime), let early = store.fireDate(ahead) {
            check("the early one really is half an hour earlier",
                  abs(due.timeIntervalSince(early) - 1800) < 90,
                  String(format: "%.0f minutes apart", due.timeIntervalSince(early) / 60))
        }
        check("the banner is titled PinTack - @Todo and names the note, marker stripped",
              store.title(onTime) == "PinTack - @Todo" && store.body(onTime) == "Ship the pilot",
              "\(store.title(onTime) ?? "no title") / \(store.body(onTime) ?? "no body")")
        Reminders.shared.cancel(todo)
        check("clearing a note's reminders takes both of them away",
              store.requests[onTime] == nil && store.requests[ahead] == nil,
              "\(store.requests.keys.sorted())")
    }

    private static func reminderPopoverSnapshot(panel: NotePanel, out: URL, then next: @escaping () -> Void) {
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
                check("the reminder popover opens", false, "NOT SHOWN")
                next()
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
                let j = (try? result.get()) as? String
                check("/find opens with the search box focused and every note offered",
                      bool(j, "searchBoxHasFocus") && int(j, "rowsOffered") > 0, j ?? "no result")
                check("typing narrows the results", (field(j, "afterTyping") as? [String])?.count == 1,
                      "\(field(j, "afterTyping") ?? "none")")
                check("opening a note from /find puts the caret back where the search started",
                      bool(j, "overlayClosed") && int(j, "caretAfter") == int(j, "caretBefore"),
                      "caret \(int(j, "caretBefore")) -> \(int(j, "caretAfter"))")
                // The note it opened must be on screen, but the CARET must still be in this note.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let key = NSApp.keyWindow as? NotePanel
                    check("/find does not steal focus to the note it opened", key === home,
                          "key window is '\(key?.note.title ?? "none")'")
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
        check("the Services entry is declared in Info.plist",
              (entry?["NSMenuItem"] as? [String: String])?["default"] == "New PinTack Note"
              && entry?["NSMessage"] as? String == "captureSelection",
              "\(services.count) service(s)")
        check("the services provider is registered and answers to it",
              NSApp.servicesProvider != nil
              && ((NSApp.servicesProvider as? NSObject)?.responds(to: Selector(("captureSelection:userData:error:"))) ?? false))

        let before = VaultStore.shared.notes.count
        let note = QuickCapture.shared.capture("Rollout plan\nring 1 on Monday\nring 2 on Friday", from: "Safari")
        SaveCoordinator.shared.flush(noteID: note.id)
        let onDisk = (try? String(contentsOf: note.fileURL, encoding: .utf8)) ?? ""
        check("a capture writes a real note with its source and all its text",
              VaultStore.shared.notes.count == before + 1 && note.title == "Rollout plan"
              && onDisk.contains("source: \"Safari\"") && onDisk.contains("ring 2 on Friday"))

        // ⌥⌘C has to reach it from any app, so it must be one of the global hotkeys.
        check("quick capture works from any app (global hotkey registered)",
              ShortcutAction.quickCapture.isGlobal && GlobalHotKeyCenter.shared.lastStatus[.quickCapture] == noErr)
        next()
    }

    /// Templates and the @ conversions, in the real page: the template list has to reach it, an
    /// @-recall has to paste the whole template, and @todo has to tag the note on the Swift side.
    private static func templateTest(then next: @escaping () -> Void) {
        let plain = VaultStore.shared.createNote(body: "# Plain note\n\nSome content.\n",
                                                 frame: WindowManager.shared.nextCardFrame(size: NSSize(width: 320, height: 240)))
        let panel = WindowManager.shared.open(plain, focus: false)
        check("the vault has a template to recall", !VaultStore.shared.notes.filter(\.isTemplate).isEmpty,
              "\(VaultStore.shared.notes.filter(\.isTemplate).map(\.templateName))")

        let js = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const view = window.__pintack._view;
        const type = (text) => { for (const ch of text) { const s = view.state.selection.main;
          view.dispatch({ changes: { from: s.from, to: s.to, insert: ch }, selection: { anchor: s.from + 1 }, userEvent: "input.type" }); } };
        const steps = {};
        view.focus();

        // 1. Recall a template by name.
        view.dispatch({ selection: { anchor: view.state.doc.length } });
        type("@chan");
        await sleep(400);
        const menu = document.querySelector('.cm-tooltip-autocomplete');
        steps.templateOffered = menu ? [...menu.querySelectorAll('li')].map(l => l.textContent) : [];
        view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
        await sleep(400);
        steps.templateInserted = view.state.doc.toString().includes('| Step | Owner |');

        // 2. Convert the note to a todo.
        view.dispatch({ selection: { anchor: view.state.doc.length } });
        type("@tod");
        await sleep(400);
        view.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }));
        await sleep(500);
        steps.firstLine = view.state.doc.toString().split('\\n')[0];
        steps.hintShown = !!document.querySelector('.cm-hint');
        return JSON.stringify(steps);
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            panel.card.editor.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                let j = (try? result.get()) as? String
                check("@name offers a template and Enter inserts the whole thing",
                      (field(j, "templateOffered") as? [String])?.isEmpty == false && bool(j, "templateInserted"),
                      j ?? "no result")
                check("@todo converts the note, marker on line 1 with the title hint",
                      text(j, "firstLine").hasPrefix("@Todo") && bool(j, "hintShown"), text(j, "firstLine"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    SaveCoordinator.shared.flush(noteID: plain.id)
                    check("@todo tags the note and brings up its bell",
                          plain.isTodo && !(WindowManager.shared.panel(for: plain.id)?.card.debugBellHidden ?? true),
                          "tags \(plain.tags)")
                    next()
                }
            }
        }
    }

    /// The action bar's tools should cross-fade with the tag side, not blink. Caught mid-flight:
    /// the arriving control must already be visible but still partly transparent.
    private static func actionBarTest(then next: @escaping () -> Void) {
        guard let panel = WindowManager.shared.openPanels.first, let card = panel.card else { return next() }
        card.debugCollapseActionBar()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let before = card.debugActionBarState
            card.debugToggleActionBar()                     // open it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                let during = card.debugActionBarState
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let after = card.debugActionBarState
                    check("the action bar starts closed", before.toolHidden && !before.tagHidden)
                    // Caught mid-flight BOTH sides are part-way, which is what a cross-fade looks
                    // like and a snap does not.
                    check("opening the action bar cross-fades rather than snapping",
                          !during.toolHidden && during.toolAlpha > 0 && during.toolAlpha < 1 && during.tagAlpha < 1,
                          "tools \(String(format: "%.2f", during.toolAlpha)), tags \(String(format: "%.2f", during.tagAlpha))")
                    check("the action bar settles with the tools shown and the tags away",
                          !after.toolHidden && after.tagHidden)
                    card.debugCollapseActionBar()
                    next()
                }
            }
        }
    }

    /// Three things reported from a real tester's Mac (2026-09-20).
    private static func testerBugsTest(then next: @escaping () -> Void) {
        // 1. Show / hide opened notes is a TOGGLE.
        let windows = WindowManager.shared
        let openBefore = windows.openPanels.count
        check("notes are on the desktop to start with", openBefore > 0, "\(openBefore) open")
        windows.toggleAllOnDesktop()
        let afterHide = windows.openPanels.count
        windows.toggleAllOnDesktop()
        let afterShow = windows.openPanels.count
        check("the show/hide key clears the desktop, then puts it back",
              afterHide == 0 && afterShow > 0, "\(openBefore) → \(afterHide) → \(afterShow)")
        check("the action is named for what it does", ShortcutAction.showAllOnDesktop.title.lowercased().contains("hide"),
              ShortcutAction.showAllOnDesktop.title)

        // The toggle just closed and reopened every panel, so their pages are loading again. Calling
        // into one now would find an empty document and prove nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { testerBugsEditorChecks(then: next) }
    }

    private static func testerBugsEditorChecks(then next: @escaping () -> Void) {
        guard let panel = WindowManager.shared.openPanels.first, let card = panel.card else { return next() }

        // Reproduce the condition the bug was reported under: an outline colour with little
        // contrast against the note's paper makes accentForNote() fall back to near-black. If the
        // menu still used that colour, its selected row would be black text on a black background.
        let previousOutline = AppSettings.shared.outlineColorHex
        AppSettings.shared.outlineColorHex = "#F7E7A8"          // pale, barely different from the paper
        card.editor.pushSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            testerBugsMenuCheck(card: card, restoring: previousOutline, then: next)
        }
    }

    private static func testerBugsMenuCheck(card: NoteCardView, restoring previousOutline: String,
                                            then next: @escaping () -> Void) {
        // 2. The slash menu's selected row must be readable, and 3. a bare @ must list templates.
        //    The menu floats on its own dark panel, so it must NOT use the note-relative accent:
        //    that colour falls back to near-black and painted the row black-on-black.
        let js = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const view = window.__pintack._view;
        const type = (text) => { for (const ch of text) { const s = view.state.selection.main;
          view.dispatch({ changes: { from: s.from, to: s.to, insert: ch }, selection: { anchor: s.from + 1 }, userEvent: "input.type" }); } };
        const out = {};
        view.focus();
        view.dispatch({ selection: { anchor: view.state.doc.length } });

        type("\\n/");
        await sleep(450);
        const menu = document.querySelector('.cm-tooltip-autocomplete');
        const row = menu && menu.querySelector('li[aria-selected]');
        if (row) {
          const cs = getComputedStyle(row);
          out.rowBackground = cs.backgroundColor;
          out.rowColour = cs.color;
          // Contrast, crudely: a readable row cannot have text and background at the same lightness.
          const lum = (c) => { const m = c.match(/[\\d.]+/g) || [0,0,0];
            return (0.2126*m[0] + 0.7152*m[1] + 0.0722*m[2]) / 255; };
          out.contrast = Math.abs(lum(cs.backgroundColor) - lum(cs.color)).toFixed(2);
        }
        view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: "x\\n" }, selection: { anchor: 2 } });
        await sleep(250);

        // A bare "@" must list every template, the way a bare "/" lists every command.
        type("@");
        await sleep(450);
        const atMenu = document.querySelector('.cm-tooltip-autocomplete');
        out.atMenuRows = atMenu ? [...atMenu.querySelectorAll('li')].map(l => l.textContent) : [];
        return JSON.stringify(out);
        """
        card.editor.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            let j = (try? result.get()) as? String
            let contrast = Double(text(j, "contrast")) ?? 0
            check("the slash menu's selected row is readable, not black on black",
                  contrast > 0.25,
                  "bg \(text(j, "rowBackground")) on text \(text(j, "rowColour")), contrast \(text(j, "contrast"))")
            let rows = (field(j, "atMenuRows") as? [String]) ?? []
            check("a bare @ lists the templates, like a bare / lists the commands",
                  !rows.isEmpty, "\(rows)")
            AppSettings.shared.outlineColorHex = previousOutline
            next()
        }
    }

    /// The action bar, from a tester's Mac (2026-09-20). Two faults, one cause: the tracker was
    /// only ever built when the note was opened, and it was drawn on a single row that simply
    /// disappeared once it no longer fitted — taking the tags with it at about seven tasks.
    private static func todoBarTest(out: URL, then next: @escaping () -> Void) {
        let note = VaultStore.shared.createNote(
            body: "@Todo Rollout\n\nNo boxes yet\n",
            tags: ["todo", "intune", "azure", "q4", "pilot", "ring1"],
            frame: WindowManager.shared.nextCardFrame(size: NSSize(width: 360, height: 260)))
        VaultStore.shared.save(note)
        let panel = WindowManager.shared.open(note, focus: true)
        panel.card.debugCollapseActionBar()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let card = panel.card!
            check("a todo note with no boxes has no tracker", card.debugProgress.isHidden)
            let topBefore = panel.frame.maxY
            let barBefore = card.debugFooterHeight

            // Typed through the editor, which is the path that used to leave the bar untouched.
            let js = """
            const view = window.__pintack._view;
            view.focus();
            view.dispatch({ selection: { anchor: view.state.doc.length } });
            for (const ch of "\\n- [ ] first") { const s = view.state.selection.main;
              view.dispatch({ changes: { from: s.from, to: s.to, insert: ch },
                              selection: { anchor: s.from + 1 }, userEvent: "input.type" }); }
            return "typed";
            """
            card.editor.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    check("the tracker appears the moment the first box is typed, with no reopening",
                          note.taskCounts.total == 1 && !card.debugProgress.isHidden,
                          "\(note.taskCounts.total) task(s), tracker hidden: \(card.debugProgress.isHidden)")
                    todoBarRowsTest(out: out, panel: panel, topBefore: topBefore, barBefore: barBefore, then: next)
                }
            }
        }
    }

    private static func todoBarRowsTest(out: URL, panel: NotePanel, topBefore: CGFloat,
                                        barBefore: CGFloat, then next: @escaping () -> Void) {
        let note = panel.note
        let card = panel.card!
        // Fourteen boxes: six to a row is three rows, so the bar is two rows thicker than a plain one.
        let boxes = (1...14).map { "- [\($0 <= 5 ? "x" : " ")] item \($0)" }.joined(separator: "\n")
        note.body = "@Todo Rollout\n\n" + boxes + "\n"
        NotificationCenter.default.post(name: .noteBodyDidChange, object: note)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            card.layoutSubtreeIfNeeded()
            check("the tracker wraps at six squares a row", card.debugProgressPerRow == 6,
                  "\(card.debugProgressPerRow) per row")
            let expected = barBefore + 2 * NotePanel.footerRowHeight
            check("fourteen tasks make the action bar two rows thicker",
                  abs(card.debugFooterHeight - expected) < 0.5,
                  "bar \(Int(barBefore)) → \(Int(card.debugFooterHeight))pt, expected \(Int(expected))")
            check("the tracker is still there at fourteen tasks, where it used to vanish",
                  !card.debugProgress.isHidden && card.debugProgress.frame.width > 0,
                  "frame \(NSStringFromRect(card.debugProgress.frame))")
            check("the bar grew DOWNWARD: the top of the note did not move",
                  abs(panel.frame.maxY - topBefore) < 0.5,
                  "top \(Int(topBefore)) → \(Int(panel.frame.maxY))")
            let pills = card.debugTagPills
            check("the tags survive a thick bar instead of disappearing with the tracker",
                  !pills.isHidden && (!pills.debugPillRects.isEmpty || !pills.overflowRect.isEmpty),
                  "\(pills.debugPillRects.count) of \(note.tags.count) pills, overflow: \(!pills.overflowRect.isEmpty)")
            check("the tags use the extra thickness, wrapping onto a second line",
                  pills.debugLineCount > 1 || Set(pills.debugPillRects.map(\.minY)).count > 1,
                  "\(pills.debugLineCount) line(s) of tags in \(Int(pills.frame.height))pt")

            // Unlimited, not capped: forty tasks is seven rows, not four.
            let many = (1...40).map { _ in "- [ ] x" }.joined(separator: "\n")
            note.body = "@Todo Rollout\n\n" + many + "\n"
            NotificationCenter.default.post(name: .noteBodyDidChange, object: note)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let rows = 1 + (card.debugFooterHeight - NotePanel.footerHeight) / NotePanel.footerRowHeight
                check("rows keep coming: forty tasks is seven rows, not a capped four",
                      Int(rows.rounded()) == 7 && !card.debugProgress.isHidden,
                      "\(Int(rows.rounded())) rows, bar \(Int(card.debugFooterHeight))pt")

                // Back to a short list: the bar has to give the height back again.
                note.body = "@Todo Rollout\n\n- [ ] one\n- [x] two\n"
                NotificationCenter.default.post(name: .noteBodyDidChange, object: note)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    check("deleting the tasks gives the height back",
                          abs(card.debugFooterHeight - NotePanel.footerHeight) < 0.5 &&
                          abs(panel.frame.maxY - topBefore) < 0.5,
                          "bar \(Int(card.debugFooterHeight))pt, top \(Int(panel.frame.maxY))")
                    // Leave it wrapped, so the rendered note at the end of the run shows the
                    // thick bar rather than a one-row one.
                    note.body = "@Todo Rollout\n\n" + boxes + "\n"
                    NotificationCenter.default.post(name: .noteBodyDidChange, object: note)
                    VaultStore.shared.save(note)
                    narrowTodoTest(out: out, panel: panel, then: next)
                }
            }
        }
    }

    /// A narrow note is where the old bar gave up first. Six squares a row plus the count plus the
    /// tags do not all fit at 250pt, so the tracker gives things up in a fixed order — the count
    /// goes before the squares, and the tags never go at all.
    private static func narrowTodoTest(out: URL, panel: NotePanel, then next: @escaping () -> Void) {
        let narrow = VaultStore.shared.createNote(
            body: "@Todo Narrow\n\n" + (1...14).map { _ in "- [ ] x" }.joined(separator: "\n") + "\n",
            tags: ["todo", "intune", "azure"],
            frame: WindowManager.shared.nextCardFrame(size: NSSize(width: 250, height: 200)))
        VaultStore.shared.save(narrow)
        let small = WindowManager.shared.open(narrow, focus: false)
        small.card.debugCollapseActionBar()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            let card = small.card!
            card.layoutSubtreeIfNeeded()
            let pills = card.debugTagPills
            // Six a row plus the count plus the tags do not fit at 250pt. Squares a row is what
            // gives, and only after the count has already gone.
            check("a narrow note keeps a sensible row of squares", card.debugProgressPerRow >= 4,
                  "\(card.debugProgressPerRow) per row, bar \(Int(card.debugFooterHeight))pt")
            check("the tracker is drawn on a narrow note rather than hidden",
                  !card.debugProgress.isHidden && card.debugProgress.frame.width > 0)
            check("the tags keep their place on a narrow note, even if only as a +N",
                  !pills.debugPillRects.isEmpty || !pills.overflowRect.isEmpty,
                  "\(pills.debugPillRects.count) pills, overflow: \(!pills.overflowRect.isEmpty), \(Int(pills.frame.width))pt wide")
            reminderPopoverTest(out: out, panel: panel, then: next)
        }
    }

    /// The first-run card. Driven through the real entry point, marker and all, because "shown
    /// once, ever" is the whole contract and a `show()` that skipped the marker would prove none
    /// of it.
    private static func onboardingTest(out: URL, then next: @escaping () -> Void) {
        let marker = VaultStore.shared.metaURL.appendingPathComponent("onboarded")
        try? FileManager.default.removeItem(at: marker)

        OnboardingWindow.showIfFirstRun()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            check("the first run is greeted", OnboardingWindow.isShowing)
            check("being greeted is remembered in the vault, not in defaults",
                  FileManager.default.fileExists(atPath: marker.path))

            guard let window = OnboardingWindow.panelForTesting else {
                check("the greeting has a window to render", false)
                return next()
            }
            // The words, read from the model rather than the rendered card: SwiftUI puts none of
            // its views into the accessibility tree an NSView hands out, so there is nothing to
            // read back off the window itself.
            let words = ([OnboardingContent.title, OnboardingContent.subtitle, OnboardingContent.footnote,
                          OnboardingContent.dismiss]
                         + OnboardingContent.features.flatMap { [$0.title, $0.detail] }).joined(separator: " ")
            check("the greeting names the app, the vault and the way out",
                  words.contains("PinTack") && words.contains("~/Documents/PinTack") && words.contains("OK"),
                  "\(OnboardingContent.features.count) features, \(words.count) characters")
            check("every feature it lists has an icon that exists",
                  OnboardingContent.features.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil },
                  OnboardingContent.features.map(\.symbol).joined(separator: " "))
            check("the shortcuts it shows are the live bindings, not hard-coded text",
                  OnboardingContent.shortcuts.allSatisfy { !ShortcutStore.shared.combo(for: $0).display.isEmpty },
                  OnboardingContent.shortcuts.map { ShortcutStore.shared.combo(for: $0).display }.joined(separator: " "))

            // And the card really drew: a window that laid out to nothing, or came up blank, would
            // pass every check above.
            let size = window.frame.size
            check("the card is a card, not a sliver", size.width > 600 && size.height > 380,
                  "\(Int(size.width))×\(Int(size.height))")
            let painted = paintedFraction(of: window)
            check("the card actually painted itself", painted > 0.5,
                  String(format: "%.0f%% of it is drawn", painted * 100))

            snapshot(window: window, to: out.appendingPathComponent("onboarding.png")) {
                OnboardingWindow.dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    check("OK puts the greeting away", !OnboardingWindow.isShowing)
                    // The second launch: the marker is there now, so nothing should appear.
                    OnboardingWindow.showIfFirstRun()
                    check("it never greets the same vault twice", !OnboardingWindow.isShowing)
                    next()
                }
            }
        }
    }

    /// How much of a window's content is actually painted. A view that laid out but never drew
    /// comes back transparent, which every other kind of check would sail straight past.
    private static func paintedFraction(of window: NSWindow) -> Double {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        var opaque = 0, sampled = 0
        for x in stride(from: 4, to: Int(rep.pixelsWide), by: 7) {
            for y in stride(from: 4, to: Int(rep.pixelsHigh), by: 7) {
                sampled += 1
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { opaque += 1 }
            }
        }
        return sampled == 0 ? 0 : Double(opaque) / Double(sampled)
    }

    /// The reminder popover, from the same tester: Done left it on screen, and a two-digit minute
    /// came out as its second digit alone.
    private static func reminderPopoverTest(out: URL, panel: NotePanel, then next: @escaping () -> Void) {
        let card = panel.card!
        WindowManager.shared.openPanels.forEach { $0.card.debugDismissPopover() }
        card.debugShowReminderPopover()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard card.debugPopoverShown, let picker = ReminderPopoverDebug.datePicker else {
                check("the reminder popover opens with a date field", false, "no NSDatePicker found")
                return next()
            }
            NSApp.activate(ignoringOtherApps: true)
            picker.window?.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            picker.window?.makeFirstResponder(picker)

            // Two digits into the segment the field opens on. That is exactly what was reported:
            // the first digit was committed, the panel re-rendered, and the second digit started
            // over — "37" became 7. The starting date holds no 12 and no 2, so both readings are
            // unambiguous whichever segment the locale puts first.
            let before = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: picker.dateValue)
            typeKeys("12", into: picker)
            let after = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: picker.dateValue)
            let fields = [after.month ?? 0, after.day ?? 0, after.hour ?? 0, after.minute ?? 0]
            check("a two-digit entry survives: the second digit does not replace the first",
                  fields.contains(12) && !fields.contains(2),
                  "typed \"12\"; fields were \([before.month ?? 0, before.day ?? 0, before.hour ?? 0, before.minute ?? 0]), now \(fields)")
            check("typing does not throw the keyboard out of the date field",
                  picker.window?.firstResponder === picker,
                  (picker.window?.firstResponder).map { String(describing: Swift.type(of: $0)) } ?? "none")

            // Done carries the panel's default-action shortcut, so Return runs the very closure the
            // button runs. SwiftUI draws its own buttons and puts none of them in the accessibility
            // tree, so there is nothing else here to press.
            check("the reminder popover is open before Done", card.debugPopoverShown)
            pressReturn(in: picker.window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                check("Done closes the reminder popover instead of leaving it on screen",
                      !card.debugPopoverShown)
                card.debugDismissPopover()
                next()
            }
        }
    }

    /// Real key presses through the app's own event dispatch, so the control's multi-digit entry
    /// state machine is what is being exercised. Delivering them straight to the view instead runs
    /// only half of it: every digit lands in the first segment and nothing ever advances.
    private static func typeKeys(_ digits: String, into view: NSView) {
        let codes: [Character: UInt16] = ["0": 29, "1": 18, "2": 19, "3": 20, "4": 21,
                                          "5": 23, "6": 22, "7": 26, "8": 28, "9": 25]
        for ch in digits {
            guard let code = codes[ch] else { continue }
            let s = String(ch)
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                               characters: s, charactersIgnoringModifiers: s,
                                               isARepeat: false, keyCode: code) else { continue }
            if let window = view.window { window.sendEvent(event) } else { view.keyDown(with: event) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Return, which is the Done button's keyboard shortcut.
    private static func pressReturn(in window: NSWindow?) {
        guard let window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "\r", charactersIgnoringModifiers: "\r",
                                           isARepeat: false, keyCode: 36) else { return }
        window.sendEvent(event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    /// A display unplugged with notes on it. The window server reports it as a screen-parameters
    /// change; the check sends the same notification after putting two notes where no screen is.
    private static func strandedNotesTest(then next: @escaping () -> Void) {
        let panels = Array(WindowManager.shared.openPanels.prefix(2))
        guard panels.count == 2 else { return next() }
        let far = NSPoint(x: -30_000, y: -30_000)          // where an unplugged display used to be
        for (i, p) in panels.enumerated() { p.setFrameOrigin(NSPoint(x: far.x + CGFloat(i) * 40, y: far.y)) }
        panels.forEach { $0.syncFrameToNote() }
        let stranded = panels.filter { !WindowManager.isReachable(NotePanel.cardRect(forWindow: $0.frame)) }.count
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let back = panels.filter { WindowManager.isReachable(NotePanel.cardRect(forWindow: $0.frame)) }
            check("notes left on a display that has gone come back onto a screen",
                  stranded == 2 && back.count == 2, "\(stranded) stranded, \(back.count) back")
            // The FILE has to agree, or the next launch puts them straight back off-screen.
            check("the rescued position is what gets saved",
                  panels.allSatisfy { WindowManager.isReachable($0.note.cardFrame) })
            check("rescued notes land apart, not in one pile",
                  panels[0].frame.origin != panels[1].frame.origin)
            next()
        }
    }

    /// A collapsed todo keeps its progress in the title bar, as a plain bar (owner, 2026-09-21).
    private static func collapsedTodoTest(out: URL, then next: @escaping () -> Void) {
        let todo = VaultStore.shared.createNote(
            body: "@Todo Patch Tuesday\n\n- [x] pilot ring\n- [x] broad ring\n- [ ] servers\n- [ ] stragglers\n- [ ] report\n",
            tags: ["todo"], frame: WindowManager.shared.nextCardFrame(size: NSSize(width: 320, height: 220)))
        VaultStore.shared.save(todo)
        let panel = WindowManager.shared.open(todo, focus: false)
        todo.collapsed = true
        panel.applyCollapsed(animated: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let card = panel.card!
            card.layoutSubtreeIfNeeded()
            let bar = card.debugCollapsedProgress
            check("a collapsed todo shows its progress in the title bar",
                  !bar.isHidden && bar.counts.done == 2 && bar.counts.total == 5 && bar.frame.width > 0,
                  "hidden \(bar.isHidden), \(bar.counts.done)/\(bar.counts.total)")
            check("the bar sits between the title and the header buttons",
                  bar.frame.minX >= card.debugTitleFrame.maxX && bar.frame.maxX <= card.debugPinFrame.minX,
                  "title ends \(Int(card.debugTitleFrame.maxX)), bar \(Int(bar.frame.minX))–\(Int(bar.frame.maxX)), pin at \(Int(card.debugPinFrame.minX))")
            snapshot(window: panel, to: out.appendingPathComponent("collapsed-todo.png")) {
                todo.collapsed = false
                panel.applyCollapsed(animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    check("expanded again, the bar leaves the title bar to the squares below",
                          card.debugCollapsedProgress.isHidden)
                    doneTodoTest(panel: panel, out: out, then: next)
                }
            }
        }
    }

    /// A finished todo looks finished: ticked, struck through and a little dimmed (owner, 2026-09-21).
    private static func doneTodoTest(panel: NotePanel, out: URL, then next: @escaping () -> Void) {
        let note = panel.note, card = panel.card!
        let before = panel.alphaValue
        let plainTitle = note.title
        // Tick the last three boxes, through the same notification the editor posts on a keystroke.
        note.body = note.body.replacingOccurrences(of: "- [ ]", with: "- [x]")
        card.editor.reloadBody()          // so the picture below shows the boxes ticked too
        NotificationCenter.default.post(name: .noteBodyDidChange, object: note)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let title = card.debugTitleText
            var struck = false
            title.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: title.length)) { v, _, _ in
                if (v as? Int ?? 0) != 0 { struck = true }
            }
            check("a finished todo's title gets a tick and is struck through",
                  note.isDone && title.string.hasPrefix("✓") && struck, title.string)
            check("a finished todo is dimmed, on top of its own opacity",
                  abs(panel.alphaValue - before * NotePanel.doneDimming) < 0.02,
                  String(format: "%.2f → %.2f", before, panel.alphaValue))
            check("the tick is drawn, never written: the note keeps its plain title",
                  note.title == plainTitle && !note.body.contains("✓"), note.title)
            snapshot(window: panel, to: out.appendingPathComponent("done-todo.png")) {
                // One box back open and it is a live todo again.
                note.body = note.body.replacingOccurrences(of: "- [x] report", with: "- [ ] report")
                NotificationCenter.default.post(name: .noteBodyDidChange, object: note)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    check("unticking a box undoes all of it",
                          !card.debugTitleText.string.hasPrefix("✓") && abs(panel.alphaValue - before) < 0.02,
                          String(format: "%@, %.2f", card.debugTitleText.string, panel.alphaValue))
                    windowTweenTest(panel: panel) { hoverRevealTest(panel: panel, then: next) }
                }
            }
        }
    }

    /// Window fades have to RUN, not just arrive, while PinTack is not the active app — which is
    /// how notes are normally used. AppKit's own window animator did not run at all in that case.
    private static func windowTweenTest(panel: NotePanel, then next: @escaping () -> Void) {
        let active = NSApp.isActive
        panel.alphaValue = 0.2
        Motion.fade(panel, to: 1, duration: 0.4, curve: Motion.Curve.easeInOut)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let midway = panel.alphaValue
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                check("a window fade is under way halfway through, and lands on its value",
                      midway > 0.3 && midway < 0.95 && abs(panel.alphaValue - 1) < 0.01,
                      String(format: "0.20 → %.2f at half time → %.2f (app active: %@)", midway, panel.alphaValue,
                             active ? "yes" : "no"))
                let start = panel.frame
                var target = start; target.size.height += 60; target.origin.y -= 60
                Motion.springFrame(panel, to: target)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    check("a window frame animation runs to its exact end", panel.frame == target,
                          "\(Int(start.height)) → \(Int(panel.frame.height)), wanted \(Int(target.height))")
                    panel.setFrame(start, display: true)
                    panel.applyOpacity()
                    next()
                }
            }
        }
    }

    /// Hover-to-reveal (Settings → Notes → Faded notes).
    private static func hoverRevealTest(panel: NotePanel, then next: @escaping () -> Void) {
        let note = panel.note, card = panel.card!
        let wasOn = AppSettings.shared.hoverRevealsNote
        note.opacity = 0.45
        panel.applyOpacity()
        AppSettings.shared.hoverRevealsNote = false
        card.setHovered(true)
        let whileOff = panel.alphaValue
        card.setHovered(false)
        check("with the option off, hovering leaves a faded note faded", abs(whileOff - 0.45) < 0.02,
              String(format: "%.2f", whileOff))

        AppSettings.shared.hoverRevealsNote = true
        // The REAL pointer is live now that hover does something: if it happens to rest over this
        // note, the window server's own enter/exit events join in. Park the note away from it.
        let pointer = NSEvent.mouseLocation
        if panel.frame.insetBy(dx: -40, dy: -40).contains(pointer), let screen = NSScreen.main?.visibleFrame {
            let x = pointer.x < screen.midX ? screen.maxX - panel.frame.width : screen.minX
            panel.setFrameOrigin(NSPoint(x: x, y: panel.frame.minY))
        }
        let pointerWasOver = panel.frame.contains(NSEvent.mouseLocation)
        card.setHovered(true)
        // The fade animates; wait it out, then read what is on screen now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let revealed = panel.alphaValue
            card.setHovered(false)
            waitFor(0.45, on: panel, started: Date()) { settledAfter in
                check("with the option on, hovering shows the note fully, and leaving fades it back",
                      abs(revealed - 1) < 0.02 && abs(panel.alphaValue - 0.45) < 0.02,
                      String(format: "0.45 → %.2f → %.2f, settled in %.2fs, pointer over it: %@", revealed,
                             panel.alphaValue, settledAfter, pointerWasOver ? "yes" : "no"))
                check("hovering never rewrites the opacity the user chose", abs(note.opacity - 0.45) < 0.001)
                note.opacity = 1
                AppSettings.shared.hoverRevealsNote = wasOn
                panel.applyOpacity()
                next()
            }
        }
    }

    /// Closing an empty note discards it instead of hiding it (owner, 2026-09-21), through the
    /// same closeNote the ✕ button and ⌘W use.
    private static func blankCloseTest(then next: @escaping () -> Void) {
        let blank = WindowManager.shared.newNote()
        let kept = VaultStore.shared.createNote(body: "Keep me",
                                                frame: WindowManager.shared.nextCardFrame(size: NSSize(width: 300, height: 250)))
        let keptPanel = WindowManager.shared.open(kept, focus: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let blankFile = blank.fileURL, keptFile = kept.fileURL
            WindowManager.shared.panel(for: blank.id)?.card.closeNote()
            keptPanel.card.closeNote()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                check("closing an empty note leaves no file behind",
                      !FileManager.default.fileExists(atPath: blankFile.path) && VaultStore.shared.note(id: blank.id) == nil)
                check("closing a note with words in it only hides it",
                      FileManager.default.fileExists(atPath: keptFile.path) && VaultStore.shared.note(id: kept.id) != nil)
                next()
            }
        }
    }

    /// ⌥⌘D offers Undo for five seconds, and Undo puts back the same note (owner, 2026-09-21).
    private static func undoDeleteTest(then next: @escaping () -> Void) {
        let note = VaultStore.shared.createNote(body: "Undo me\n\nstill here",
                                                frame: WindowManager.shared.nextCardFrame(size: NSSize(width: 300, height: 250)))
        let panel = WindowManager.shared.open(note, focus: false)
        let path = note.fileURL.path, id = note.id, frame = note.cardFrame
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            panel.card.deleteNote()
            let gone = !FileManager.default.fileExists(atPath: path) && VaultStore.shared.note(id: id) == nil
            check("deleting moves the note away", gone)
            check("the Moved to Trash toast offers Undo", Toast.debugOffersAction)
            if let clicks = Toast.debugTakesClicks {
                check("the toast takes the click on Undo instead of letting it through", clicks)
            }
            Toast.debugPerformAction()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let back = VaultStore.shared.note(id: id)
                check("Undo puts the SAME note back where it was, window and all",
                      FileManager.default.fileExists(atPath: path) && back === note
                          && back?.cardFrame == frame && WindowManager.shared.panel(for: id) != nil,
                      "file \(FileManager.default.fileExists(atPath: path)), same note \(back === note)")
                check("the words came back with it",
                      ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").contains("still here"))
                check("Undo is spent once used", !Toast.debugOffersAction)
                next()
            }
        }
    }

    /// Polls a window's opacity until it reaches `target` or two seconds pass, and reports how
    /// long it took. A fixed wait conflated "never fades" with "fades slowly".
    private static func waitFor(_ target: CGFloat, on window: NSWindow, started: Date,
                                then done: @escaping (TimeInterval) -> Void) {
        let elapsed = Date().timeIntervalSince(started)
        if abs(window.alphaValue - target) < 0.02 || elapsed > 2 { return done(elapsed) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { waitFor(target, on: window, started: started, then: done) }
    }

    private static func renderWindows(out: URL) {
        runnerTest(out: out) { linkPreviewTest(out: out) { imageEditTest(out: out) { freezeTest { reminderTest(out: out) { findTest(out: out) { quickCaptureTest { templateTest { actionBarTest { testerBugsTest { todoBarTest(out: out) { onboardingTest(out: out) { strandedNotesTest { collapsedTodoTest(out: out) { blankCloseTest { undoDeleteTest { renderWindowsNow(out: out) } } } } } } } } } } } } } } } }
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
        let summary = failures.isEmpty
            ? "\nSELFTEST PASSED — \(checksRun) checks"
            : "\nSELFTEST FAILED — \(failures.count) of \(checksRun) checks:\n"
              + failures.map { "  • " + $0 }.joined(separator: "\n")
        log(summary)
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)

        if ProcessInfo.processInfo.environment["PINTACK_SELFTEST_QUIT"] != nil {
            SaveCoordinator.shared.flushAll()
            // Exit non-zero on failure so a build script can rely on this. NSApp.terminate would
            // always exit 0, which is how a red report could pass unnoticed.
            if failures.isEmpty {
                NSApp.terminate(nil)
            } else {
                exit(1)
            }
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
