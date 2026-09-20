import AppKit
import WebKit

/// A small web view that hosts one plugin's custom settings tab. It uses the same scheme handler, the
/// same CSP and the same bridge (and so the same permission checks) as a note's editor.
final class PluginSettingsHostView: WKWebView, WKScriptMessageHandler, WKNavigationDelegate {

    let pluginID: String
    private var isReady = false

    private final class Proxy: NSObject, WKScriptMessageHandler {
        weak var target: WKScriptMessageHandler?
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
    }

    init(pluginID: String) {
        self.pluginID = pluginID
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: EditorSchemeHandler.scheme)
        config.websiteDataStore = .nonPersistent()
        let proxy = Proxy()
        config.userContentController.add(proxy, name: "pintack")
        super.init(frame: .zero, configuration: config)
        proxy.target = self
        navigationDelegate = self
        setValue(false, forKey: "drawsBackground")
        load(URLRequest(url: URL(string: "\(EditorSchemeHandler.scheme)://editor/plugin-settings.html")!))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        PluginManager.shared.endSession(for: self)
        PluginBridge.shared.cancelRuns(owner: self)
    }

    func send(_ type: String, _ payload: [String: Any]) {
        let msg: [String: Any] = ["type": type, "noteId": NSNull(), "payload": payload]
        guard isReady, let data = try? JSONSerialization.data(withJSONObject: msg), let json = String(data: data, encoding: .utf8) else { return }
        evaluateJavaScript("window.__pintack.receive(\(json))", completionHandler: nil)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let type = dict["type"] as? String else { return }
        let payload = dict["payload"] as? [String: Any] ?? [:]
        switch type {
        case "ready":
            isReady = true
            let entry = PluginManager.shared.makeSession(for: self).first { ($0["id"] as? String) == pluginID }
            send("plugin.settingsHost", ["plugin": entry ?? NSNull()])
        case "plugin.host":
            PluginBridge.shared.handle(payload, from: PluginBridge.Sender(owner: self, noteID: nil,
                                                                          send: { [weak self] t, p in self?.send(t, p) }))
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.scheme == EditorSchemeHandler.scheme && action.navigationType == .other ? .allow : .cancel)
    }
}

/// One window per plugin that shows its custom settings page.
final class PluginSettingsWindows {
    static let shared = PluginSettingsWindows()
    private var windows: [String: NSWindow] = [:]

    func show(pluginID: String, title: String) {
        if let w = windows[pluginID], w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "\(title) Settings"
        w.contentView = PluginSettingsHostView(pluginID: pluginID)
        w.isReleasedWhenClosed = false
        w.center()
        windows[pluginID] = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
