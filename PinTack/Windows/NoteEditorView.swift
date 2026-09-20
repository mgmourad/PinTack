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

    init(note: Note) {
        self.note = note
        self.mode = AppSettings.shared.defaultMode

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: EditorSchemeHandler.scheme)
        config.websiteDataStore = .nonPersistent()
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
    func setTitle(_ title: String) { send("title.set", ["title": title]) }
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
            "surface": dark ? "rgba(0, 0, 0, 0.14)" : "rgba(255, 255, 255, 0.16)",
            "rule": dark ? "rgba(0, 0, 0, 0.22)" : "rgba(255, 255, 255, 0.28)",
            "highlight": dark ? "rgba(255, 214, 0, 0.5)" : "rgba(255, 214, 0, 0.32)",
            "font": stack,
            "size": s.fontSize,
            "bullet": s.bulletEmoji,
            "spellcheck": s.spellcheck,
            "slashCommands": s.slashCommands,
        ]
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
            SaveCoordinator.shared.scheduleSave(note)
            NotificationCenter.default.post(name: .noteBodyDidChange, object: note)
            if note.title != lastTitle {
                sendPluginEvent("note:rename", ["noteId": note.id, "oldTitle": lastTitle, "newTitle": note.title])
                lastTitle = note.title
            }

        case "focus.changed":
            onFocusChange?(payload["focused"] as? Bool ?? false)

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
            if AppSettings.shared.imagePaste == "link" {
                self.send("image.inserted", ["path": url.path, "alt": url.deletingPathExtension().lastPathComponent])
            } else if let path = VaultStore.shared.importAttachment(from: url) {
                self.send("image.inserted", ["path": path, "alt": url.deletingPathExtension().lastPathComponent])
            }
        }
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
