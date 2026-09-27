import AppKit
import WebKit

// MARK: - Local content only

/// Serves the editor and vault attachments under `pintack-app://`. SPEC.md §4.4.
///
/// The webview has no other way to load anything: the CSP in Editor/index.html
/// forbids remote resources, and this handler refuses any path that resolves
/// outside the editor bundle, the vault's attachments folder, or an image file.
final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "pintack-app"

    private let editorRoot: URL = {
        (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Editor", isDirectory: true)
    }()

    private static let mime: [String: String] = [
        "html": "text/html", "js": "text/javascript", "css": "text/css",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "svg": "image/svg+xml", "webp": "image/webp", "heic": "image/heic",
    ]
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic"]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task, 404) }
        var name = url.path
        while name.hasPrefix("/") { name.removeFirst() }

        let data: Data
        let type: String
        if name.hasPrefix("plugins/") {
            // A plugin's own script, stylesheet or images, and only if it is enabled and valid. Its main
            // script is wrapped so it can only reach its own facade. See PluginManager.wrap.
            guard let served = PluginManager.shared.servedFile(forPath: name), let raw = try? Data(contentsOf: served.url) else { return fail(task, 404) }
            data = served.isMain ? Data(PluginManager.wrap(String(decoding: raw, as: UTF8.self)).utf8) : raw
            type = EditorSchemeHandler.mime[served.url.pathExtension.lowercased()] ?? "application/octet-stream"
        } else {
            guard let file = resolve(url), let raw = try? Data(contentsOf: file) else { return fail(task, 404) }
            data = raw
            type = EditorSchemeHandler.mime[file.pathExtension.lowercased()] ?? "application/octet-stream"
        }
        let headers = ["Content-Type": type, "Content-Length": "\(data.count)",
                       "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, _ code: Int) {
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist))
    }

    private func resolve(_ url: URL) -> URL? {
        var path = url.path
        while path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = "index.html" }

        let candidate: URL
        let allowedRoot: URL
        if path.hasPrefix("attachments/") {
            allowedRoot = VaultStore.shared.attachmentsURL
            candidate = VaultStore.shared.vaultURL.appendingPathComponent(path)
        } else if path.hasPrefix("__abs__/") {
            // Link-in-place images (Settings → Editor). Images only, never other files.
            let abs = URL(fileURLWithPath: "/" + path.dropFirst("__abs__/".count))
            guard EditorSchemeHandler.imageExts.contains(abs.pathExtension.lowercased()) else { return nil }
            return FileManager.default.fileExists(atPath: abs.path) ? abs : nil
        } else {
            allowedRoot = editorRoot
            candidate = editorRoot.appendingPathComponent(path)
        }

        // No `..` escapes out of the allowed root.
        let resolved = candidate.standardizedFileURL
        guard resolved.path.hasPrefix(allowedRoot.standardizedFileURL.path + "/") else { return nil }
        return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
    }
}

// MARK: - The editor view

/// One CodeMirror editor per note, hosted in a WKWebView. SPEC.md §2.1.
final class NoteEditorView: WKWebView, WKScriptMessageHandler, WKNavigationDelegate {

    private let note: Note
    private var isReady = false
    private var queued: [String] = []
    private lazy var lastTitle: String = note.title

    private(set) var mode: String

    /// Called when the editor asks for a mode change or reports focus, so the
    /// card can update its header glyph.
    var onModeChange: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    /// WKWebView retains its message handlers; a weak proxy avoids a retain cycle.
    private final class Proxy: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            target?.userContentController(c, didReceive: m)
        }
    }

    /// One website data store for every note, rather than one each (SPEC.md §17, the memory work).
    ///
    /// Two web views may only share a WebContent process if they share a data store: a store is a
    /// browsing session, and WebKit will not put two sessions in one process. With one store each —
    /// which is what this has always done, from the first build, with no reason recorded — twenty
    /// open notes mean twenty WebContent processes and about 27 MB apiece.
    ///
    /// Still non-persistent: nothing a note's page holds belongs on disk.
    private static let sharedStore: WKWebsiteDataStore = .nonPersistent()

    /// A development switch, off by default, so the old behaviour is one flag away:
    /// `PINTACK_SHARED_WEBSTORE=1`. Honoured in Release too, so the shipped build can be measured
    /// and tested in both positions.
    static var usesSharedStore: Bool {
        ProcessInfo.processInfo.environment["PINTACK_SHARED_WEBSTORE"] == "1"
    }

    init(note: Note) {
        self.note = note
        self.mode = AppSettings.shared.defaultMode

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: EditorSchemeHandler.scheme)
        config.websiteDataStore = NoteEditorView.usesSharedStore ? NoteEditorView.sharedStore : .nonPersistent()
        let proxy = Proxy()
        config.userContentController.add(proxy, name: "pintack")
        super.init(frame: .zero, configuration: config)
        proxy.target = self

        navigationDelegate = self
        setValue(false, forKey: "drawsBackground")       // the note color shows through
        #if DEBUG
        if #available(macOS 13.3, *) { isInspectable = true }
        #endif

        load(URLRequest(url: URL(string: "\(EditorSchemeHandler.scheme)://editor/index.html")!))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A click on a note that isn't focused should both focus and place the caret.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The note supplies its own right-click menu (Cut/Copy/Paste, the Note menu, All Notes, note
    /// management). WebKit's default menu offers things a code-mirror editor cannot act on (Fonts,
    /// Speech...) and choosing them did nothing, so the click is taken here and WebKit never sees it.
    var contextMenuItems: (() -> [NSMenuItem])?

    override func rightMouseDown(with event: NSEvent) {
        guard let items = contextMenuItems?(), !items.isEmpty else { super.rightMouseDown(with: event); return }
        window?.makeKey()                       // so Paste and friends reach this note's editor
        let menu = NSMenu()
        items.forEach { menu.addItem($0) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Swift → JS

    func send(_ type: String, _ payload: [String: Any] = [:]) {
        let msg: [String: Any] = ["type": type, "noteId": note.id, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__pintack.receive(\(json))"
        if isReady { evaluateJavaScript(js, completionHandler: nil) } else { queued.append(js) }
    }

    func loadNote(focus: Bool) {
        send("note.load", [
            "body": note.body,
            "mode": mode,
            "tags": VaultStore.shared.tagCounts().map(\.tag),
            "settings": settingsPayload(),
            "focus": focus,
            "plugins": pluginSession(),
            "templates": NoteEditorView.templatePayload(),
        ])
    }

    // MARK: Plugins

    private(set) var hasPlugins = false

    /// Enabled plugins for this page load, each with a fresh capability token. SPEC.md §12.
    private func pluginSession() -> [[String: Any]] {
        let session = PluginManager.shared.makeSession(for: self)
        hasPlugins = !session.isEmpty
        return session
    }

    func sendPluginEvent(_ name: String, _ payload: [String: Any] = [:]) {
        guard hasPlugins else { return }
        send("plugin.event", ["name": name, "payload": payload])
    }

    func sendPluginSettings(_ id: String) {
        guard hasPlugins, let p = PluginManager.shared.plugin(id: id) else { return }
        send("plugin.settings", ["id": id, "settings": PluginManager.shared.settingsValues(for: p)])
    }

    /// Reloads the page (and so the plugins). Used when a plugin is switched on or off.
    func reloadEditor() {
        PluginBridge.shared.cancelRuns(owner: self)
        isReady = false
        queued.removeAll()
        reload()
    }

    deinit {
        PluginManager.shared.endSession(for: self)
        PluginBridge.shared.cancelRuns(owner: self)
    }

    func reloadBody() { send("note.reload", ["body": note.body]) }
    func pushSettings() { send("settings.changed", settingsPayload()) }
    func pushTags() { send("tags.changed", ["tags": VaultStore.shared.tagCounts().map(\.tag)]) }
    func openEmoji() { send("emoji.open") }

    /// Action-bar buttons: "bold", "italic", "code", "bullet".
    func format(_ kind: String) {
        send("format.apply", ["kind": kind])
        window?.makeFirstResponder(self)          // keep typing after a button click
    }

    /// Right-click on the bullet button: pick an emoji bullet (or clear the choice).
    func pickBullet() { send("bullet.pick") }
    func focusEditor() { send("focus"); window?.makeFirstResponder(self) }

    func setMode(_ newMode: String) {
        mode = newMode
        send("mode.set", ["mode": newMode])
        onModeChange?(newMode)
    }

    func toggleMode() { setMode(mode == "live" ? "source" : "live") }

    /// Colors are decided natively so contrast is always right for the note color.
    /// SPEC.md §4.3, §9.
    /// Asks for a template name, checks it, and marks this note as a template.
    private func promptForTemplateName() {
        let suggestion = Note.sanitizedTemplateName(note.templateName.isEmpty ? note.title : note.templateName)
        guard let raw = Prompt.text(title: "Save as template",
                                    message: "One word: letters, numbers, hyphens, dots and underscores. "
                                           + "Recall it in any note by typing @name.",
                                    placeholder: suggestion.isEmpty ? "meeting-notes" : suggestion,
                                    confirm: "Save") else { return }

        TemplateNaming.apply(raw, to: note)
    }

    /// Every template the vault holds, for the @ menu.
    static func templatePayload() -> [[String: Any]] {
        VaultStore.shared.notes.filter(\.isTemplate).map { template in
            ["name": template.templateName, "title": template.title, "body": template.body]
        }
    }

    /// Pushes one freshly fetched preview to the page.
    private func sendPreview(_ url: String) {
        guard !LinkPreviewStore.shared.isDismissed(noteID: note.id, url: url) else { return }
        if let data = LinkPreviewStore.shared.cached(url) { send("linkpreview.result", ["previews": [data]]) }
        else { send("linkpreview.failed", ["url": url]) }
    }

    private func settingsPayload() -> [String: Any] {
        let s = AppSettings.shared
        let dark = note.isDarkText
        let fg: NSColor = dark ? NSColor(white: 0.08, alpha: 0.88) : NSColor(white: 1, alpha: 0.94)
        let stack = s.fontFamily.isEmpty
            ? "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", system-ui, sans-serif"
            : "\"\(s.fontFamily.replacingOccurrences(of: "\"", with: ""))\", \"Comic Sans MS\", -apple-system, system-ui, sans-serif"
        return [
            "fg": fg.css(),
            "fgDim": fg.css(alpha: 0.55),
            "fgHint": fg.css(alpha: 0.62),         // placeholders and the @Todo hint: readable on any note color
            "accent": accentForNote().css(),
            // Menus and overlays float on their own dark panel, not on the note's paper, so they
            // must NOT use accentForNote(): its low-contrast fallback is near-black, which painted
            // the selected row of the slash menu black-on-black. Same rule as Settings chrome.
            "chromeAccent": Brand.accentNS.css(),
            // `dark` is dark TEXT, which means light paper. Code tokens need the opposite sense.
            "paper": dark ? "light" : "dark",
            // Inline code's own background. Automatic keeps the old behaviour (a wash of black on
            // light paper, white on dark); a chosen colour is used as-is on every note.
            "inlineCode": (NSColor(hex: s.inlineCodeColorHex) ?? (dark ? .black : .white)).css(alpha: s.inlineCodeOpacity),
            // A fenced block is its own panel, not a wash of the note's paper: a dark slate on
            // every note, whatever colour the note is (owner decision, 2026-09-20). Code is read,
            // not skimmed, and a 16% white veil over a dark note was neither one thing nor other.
            "codeBlock": codeBlockColor.css(alpha: s.codeBlockOpacity),
            // Which of the two token palettes to use INSIDE a block. It follows the block's own
            // background, not the note's paper: a dark panel on a light note still needs light
            // tokens, and the two used to be the same decision.
            "codePaper": codeBlockPaper(),
            "surface": dark ? "rgba(0, 0, 0, 0.14)" : "rgba(255, 255, 255, 0.16)",
            "rule": dark ? "rgba(0, 0, 0, 0.22)" : "rgba(255, 255, 255, 0.28)",
            "highlight": dark ? "rgba(255, 214, 0, 0.5)" : "rgba(255, 214, 0, 0.32)",
            "font": stack,
            "size": s.fontSize,
            "bullet": s.bulletEmoji,
            "spellcheck": s.spellcheck,
            "slashCommands": s.slashCommands,
            "pasteAsMarkdown": s.pasteAsMarkdown,
            "linkPreviews": s.linkPreviews,
            "vim": s.vimMode,
            "codeLineNumbers": s.codeLineNumbers,
        ]
    }

    /// The fenced-code panel: the user's colour, or the automatic dark slate. Not pure black —
    /// a flat black hole in the middle of a coloured note looks like a rendering fault.
    private var codeBlockColor: NSColor {
        NSColor(hex: AppSettings.shared.codeBlockColorHex)
            ?? NSColor(srgbRed: 0.106, green: 0.118, blue: 0.149, alpha: 1)      // #1B1E26
    }

    /// What the panel actually LOOKS like once it is composited over the note's own paper. The
    /// panel is translucent, so its declared colour says little: a pale colour at 30% over a dark
    /// note is still dark.
    var compositedCodeBlockColor: NSColor {
        let alpha = AppSettings.shared.codeBlockOpacity
        guard let panel = codeBlockColor.usingColorSpace(.sRGB),
              let paper = note.color.usingColorSpace(.sRGB) else { return codeBlockColor }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * alpha + b * (1 - alpha) }
        return NSColor(srgbRed: mix(panel.redComponent, paper.redComponent),
                       green: mix(panel.greenComponent, paper.greenComponent),
                       blue: mix(panel.blueComponent, paper.blueComponent), alpha: 1)
    }

    #if DEBUG
    /// Exactly the colour string the page is sent for `--code-bg`, so the self-test can prove the
    /// stylesheet actually uses it rather than quietly falling back to the note's surface wash.
    var debugCodeBlockCSS: String { codeBlockColor.css(alpha: AppSettings.shared.codeBlockOpacity) }
    #endif

    /// Whether code tokens inside a block need the light or the dark palette.
    private func codeBlockPaper() -> String {
        compositedCodeBlockColor.relativeLuminance < 0.45 ? "dark" : "light"
    }

    /// The universal outline color is the accent. On a note where it would be
    /// unreadable against the paper, fall back to a readable one.
    private func accentForNote() -> NSColor {
        let accent = AppSettings.shared.outlineColor
        let contrast = abs(accent.relativeLuminance - note.color.relativeLuminance)
        return contrast < 0.18 ? (note.isDarkText ? NSColor(white: 0.1, alpha: 1) : .white) : accent
    }

    // MARK: JS → Swift

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let type = dict["type"] as? String else { return }
        let payload = dict["payload"] as? [String: Any] ?? [:]

        switch type {
        case "ready":
            // The page just (re)loaded, so it has no note and no plugins yet: send them first, then
            // anything that was waiting (a focus request, say).
            isReady = true
            loadNote(focus: false)
            queued.forEach { evaluateJavaScript($0, completionHandler: nil) }
            queued.removeAll()

        case "content.changed":
            guard let body = payload["body"] as? String, body != note.body else { return }
            note.body = body
            // A ✕'d preview is forgotten once its link is gone, so pasting the link again previews it.
            LinkPreviewStore.shared.pruneDismissals(noteID: note.id, body: body)
            SaveCoordinator.shared.scheduleSave(note)
            NotificationCenter.default.post(name: .noteBodyDidChange, object: note)
            if note.title != lastTitle {
                sendPluginEvent("note:rename", ["noteId": note.id, "oldTitle": lastTitle, "newTitle": note.title])
                lastTitle = note.title
            }

        case "focus.changed":
            onFocusChange?(payload["focused"] as? Bool ?? false)

        // Link previews. The page asks; Swift is the only side that may touch the network, and only
        // while the setting is on. SPEC.md §4.4, PinTack/Vault/LinkPreview.swift.
        case "linkpreview.request":
            guard AppSettings.shared.linkPreviews, let urls = payload["urls"] as? [String] else { return }
            let store = LinkPreviewStore.shared
            var known: [[String: Any]] = []
            for url in urls where !store.isDismissed(noteID: note.id, url: url) {
                if let data = store.cached(url) { known.append(data) }
                else { store.fetch(url) { [weak self] fetched in self?.sendPreview(fetched) } }
            }
            if !known.isEmpty { send("linkpreview.result", ["previews": known]) }

        case "linkpreview.dismiss":
            guard let url = payload["url"] as? String else { return }
            LinkPreviewStore.shared.dismiss(noteID: note.id, url: url)
            send("linkpreview.dismissed", ["url": url])

        case "plugin.host":
            PluginBridge.shared.handle(payload, from: PluginBridge.Sender(owner: self, noteID: note.id,
                                                                          send: { [weak self] type, body in self?.send(type, body) }))

        case "plugin.commands":
            // The page reports what its plugins registered; the manager only accepts enabled plugins.
            let raw = payload["commands"] as? [[String: Any]] ?? []
            for id in Set(raw.compactMap { $0["pluginId"] as? String }) {
                PluginManager.shared.setCommands(pluginID: id, from: raw.filter { ($0["pluginId"] as? String) == id })
            }

        case "image.paste":
            guard let b64 = payload["data"] as? String, let data = Data(base64Encoded: b64) else { return }
            insertImage(data: data, ext: payload["ext"] as? String ?? "png")

        case "image.pick":
            pickImage()

        // /find asked for something to search. Titles and a short preview only: the whole vault's
        // text would be a lot to hand a web view, and the overlay matches on these.
        case "notes.list":
            let list = VaultStore.shared.notes.map { other -> [String: Any] in
                ["id": other.id, "title": other.title,
                 "folder": VaultStore.shared.folder(of: other),
                 "preview": String(other.previewLine.prefix(90))]
            }
            send("notes.list", ["notes": list])

        // Opening from /find deliberately does NOT take you there: the note appears, but the caret
        // stays where the search started, which the page restores on its side.
        case "note.open":
            guard let id = payload["id"] as? String, let target = VaultStore.shared.note(id: id) else { return }
            if target.id == note.id { return }
            let panel = WindowManager.shared.open(target, focus: false)
            panel.orderFront(nil)
            panel.pulse()
            window?.makeKeyAndOrderFront(nil)

        // /template: name this note and it becomes one, recallable with @name anywhere.
        case "template.save":
            promptForTemplateName()

        // A slash command asking for something the note itself does (e.g. /freeze).
        case "note.action":
            if payload["action"] as? String == "tagTodo" {
                // The page put "@Todo" on line 1; the tag is Swift's side of the same change.
                if !note.isTodo || !note.tags.contains(where: { $0.caseInsensitiveCompare("todo") == .orderedSame }) {
                    note.tags.append("todo")
                    VaultStore.shared.save(note)
                    NotificationCenter.default.post(name: .vaultDidChange, object: nil)
                }
                WindowManager.shared.panel(for: note.id)?.card.refreshFromNote()
            } else if payload["action"] as? String == "stack" {
                WindowManager.shared.panel(for: note.id)?.card.showStackCreatorFromCommand()
            } else if payload["action"] as? String == "save" {
                // Vim's :w. Notes save themselves anyway; this just does it now and says so.
                SaveCoordinator.shared.flush(noteID: note.id)
                Toast.show("Saved")
            } else if let raw = payload["action"] as? String, let action = ShortcutAction(rawValue: raw) {
                WindowManager.shared.panel(for: note.id)?.card.perform(action)
            }

        case "image.crop":
            cropImage(payload)

        // Vim mode: the mode for the action bar, and the ":" / "/" prompt, which Swift draws in the
        // action bar instead of the page drawing it (owner, 2026-09-21). SPEC.md §4.6.
        case "vim.mode", "vim.prompt.open", "vim.prompt.value", "vim.prompt.close", "vim.notify":
            WindowManager.shared.panel(for: note.id)?.card.vimEvent(type, payload)

        case "bullet.changed":
            let emoji = payload["emoji"] as? String ?? ""
            AppSettings.shared.bulletEmoji = emoji
            Toast.show(emoji.isEmpty ? "Default bullet" : "Bullet: \(emoji)")

        case "link.open":
            // Only web and mail links leave the app. SPEC.md §4.4.
            if let s = payload["url"] as? String, let url = URL(string: s),
               ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }

        default:
            break
        }
    }

    // MARK: Images (SPEC.md §7)

    /// Pasting inserts the image straight away. Cropping and resizing happen afterwards, inside
    /// the note: click the image and it grows corner handles, a crop tool and a bin.
    private func insertImage(data: Data, ext: String) {
        guard let path = VaultStore.shared.writeAttachment(data, ext: ext) else { return }
        send("image.inserted", ["path": path])
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let alt = url.deletingPathExtension().lastPathComponent
            // "Link in place" points at the user's own file, so it is used exactly as it is.
            if AppSettings.shared.imagePaste == "link" {
                self.send("image.inserted", ["path": url.path, "alt": alt])
            } else if let path = VaultStore.shared.importAttachment(from: url) {
                self.send("image.inserted", ["path": path, "alt": alt])
            }
        }
    }

    /// Crops an image the user framed inside the note. The result is written as a NEW attachment
    /// and the note's link is repointed at it, so the picture they started from is never destroyed.
    private func cropImage(_ payload: [String: Any]) {
        guard let path = payload["path"] as? String,
              let x = payload["x"] as? Double, let y = payload["y"] as? Double,
              let w = payload["w"] as? Double, let h = payload["h"] as? Double,
              w >= 1, h >= 1,
              let file = resolveAttachment(path), let image = NSImage(contentsOf: file) else { return }

        // The page measures from the TOP left, as CSS does; NSImage draws from the bottom left.
        let pixels = ImageEditing.pixelSize(of: image)
        let rect = NSRect(x: x, y: pixels.height - (y + h), width: w, height: h)
            .intersection(NSRect(origin: .zero, size: pixels))
        guard rect.width >= 1, rect.height >= 1,
              let cropped = ImageEditing.png(from: image, crop: rect, size: rect.size),
              let newPath = VaultStore.shared.writeAttachment(cropped, ext: "png") else { return }
        send("image.cropped", ["path": path, "newPath": newPath])
    }

    /// Where an image link points on disk: a vault attachment, or an absolute path for a
    /// linked-in-place image. Anything else is refused.
    private func resolveAttachment(_ path: String) -> URL? {
        if path.hasPrefix("attachments/") {
            let url = VaultStore.shared.vaultURL.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(VaultStore.shared.attachmentsURL.standardizedFileURL.path + "/") else { return nil }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Navigation lockdown

    /// The editor may load itself once and nothing else. SPEC.md §4.4.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let ok = action.request.url?.scheme == EditorSchemeHandler.scheme && action.navigationType == .other
        decisionHandler(ok ? .allow : .cancel)
    }
}

extension Notification.Name {
    /// A note's body changed in an editor. `object` is the Note.
    static let noteBodyDidChange = Notification.Name("PinTack.noteBodyDidChange")
}
