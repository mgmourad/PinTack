#if DEBUG
import AppKit

/// What it costs to bring a note's editor up, three ways (SPEC.md §5.11).
///
///     PINTACK_VAULT=/tmp/x PINTACK_WAKEPROBE=5 build/Debug/PinTack.app/Contents/MacOS/PinTack
///
/// A note that has been parked has to get its editor back when you click it, and how that is done
/// decides whether parking is usable at all:
///
///   cold      a brand-new web view: a new WebKit process, then the page
///   reload    an existing warm view told to load the page again: same process, page parsed again
///   rebind    an existing warm view handed a different note, page left alone
///
/// Debug builds only, throwaway vaults only.
enum WakeProbe {

    static var requested: Int? {
        guard let raw = ProcessInfo.processInfo.environment["PINTACK_WAKEPROBE"] else { return nil }
        return Int(raw).map { max(1, $0) } ?? 5
    }

    static func runIfRequested() {
        guard let runs = requested else { return }
        guard ProcessInfo.processInfo.environment["PINTACK_VAULT"]?.isEmpty == false else {
            print("WAKEPROBE refused: set PINTACK_VAULT to a throwaway folder"); exit(2)
        }
        NSApp.activate(ignoringOtherApps: true)
        MainWindowController.shared.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { NSLog("WAKEPROBE: starting"); cold(runs: runs, left: runs, times: []) }
    }

    private static var host: NSWindow?
    private static var kept: [NoteEditorView] = []

    /// A window to hold the views being timed: a web view outside a window does not load.
    private static func stage() -> NSWindow {
        if let host { return host }
        let w = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 360, height: 280),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.alphaValue = 0.01
        w.orderFront(nil)
        host = w
        return w
    }

    private static func cold(runs: Int, left: Int, times: [Double]) {
        NSLog("WAKEPROBE: cold %d left", left)
        guard left > 0 else { return reload(runs: runs, left: runs, cold: times, times: []) }
        guard let note = VaultStore.shared.notes.first else { return report(cold: times, reload: [], rebind: []) }
        let start = Date()
        let view = NoteEditorView(note: note)
        view.frame = NSRect(x: 0, y: 0, width: 340, height: 260)
        view.debugOnReady = {
            let ms = Date().timeIntervalSince(start) * 1000
            kept.append(view)                     // kept alive: releasing it would skew the next run
            cold(runs: runs, left: left - 1, times: times + [ms])
        }
        stage().contentView?.addSubview(view)
    }

    private static func reload(runs: Int, left: Int, cold: [Double], times: [Double]) {
        NSLog("WAKEPROBE: reload %d left", left)
        guard left > 0, let view = kept.first else {
            return rebind(runs: runs, left: runs, cold: cold, reload: times, times: [])
        }
        let start = Date()
        view.debugOnReady = {
            reload(runs: runs, left: left - 1, cold: cold, times: times + [Date().timeIntervalSince(start) * 1000])
        }
        view.load(URLRequest(url: NoteEditorView.pageURL))
    }

    private static func rebind(runs: Int, left: Int, cold: [Double], reload: [Double], times: [Double]) {
        NSLog("WAKEPROBE: rebind %d left", left)
        guard left > 0, let view = kept.first else { return report(cold: cold, reload: reload, rebind: times) }
        let notes = VaultStore.shared.notes
        guard notes.count > 1 else { return report(cold: cold, reload: reload, rebind: times) }
        let note = notes[(runs - left + 1) % notes.count]
        let start = Date()
        // Rebinding does not restart the page, so "ready" never fires again: the page answering with
        // the new note's text is what finished means here.
        view.rebind(to: note, focus: false)
        func poll() {
            view.evaluateJavaScript("window.__pintack && window.__pintack._view ? window.__pintack._view.state.doc.toString().slice(0, 24) : null") { result, _ in
                if let text = result as? String, note.body.hasPrefix(text.prefix(12)) || text.hasPrefix(String(note.body.prefix(12))) {
                    rebind(runs: runs, left: left - 1, cold: cold, reload: reload,
                           times: times + [Date().timeIntervalSince(start) * 1000])
                } else if Date().timeIntervalSince(start) > 5 {
                    rebind(runs: runs, left: left - 1, cold: cold, reload: reload, times: times + [-1])
                } else { poll() }
            }
        }
        poll()
    }

    private static func report(cold: [Double], reload: [Double], rebind: [Double]) {
        func line(_ name: String, _ v: [Double]) -> String {
            let ok = v.filter { $0 >= 0 }.sorted()
            guard !ok.isEmpty else { return "\(name): no measurement" }
            return String(format: "%-8s median %6.0f ms   min %6.0f   max %6.0f   (%d runs)",
                          (name as NSString).utf8String!, ok[ok.count / 2], ok.first!, ok.last!, ok.count)
        }
        let report = ["PinTack wake probe: what it costs to give a note its editor",
                      line("cold", cold), line("reload", reload), line("rebind", rebind)].joined(separator: "\n")
        print(report)
        if let out = ProcessInfo.processInfo.environment["PINTACK_WAKEPROBE_OUT"] {
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }
}
#endif
