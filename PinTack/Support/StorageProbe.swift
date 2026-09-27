#if DEBUG
import AppKit

/// Whether two notes can see each other's web storage (SPEC.md §17, the memory work).
///
///     PINTACK_VAULT=/tmp/x PINTACK_STORAGEPROBE=1 build/Debug/PinTack.app/Contents/MacOS/PinTack
///     PINTACK_SHARED_WEBSTORE=1 …same…                  # with one store for every note
///
/// Every note's page is the same origin, so what keeps one note's `localStorage` out of another's
/// is the SEPARATE website data store each one gets. Any design that shares a store — or shares a
/// web view between notes — shares that storage too, and a key that is not unique per note would
/// have one note overwriting another's state.
///
/// This writes a key in the first note, reads it from the second, and says what it found. Debug
/// builds only, throwaway vaults only.
enum StorageProbe {

    static var requested: Bool { ProcessInfo.processInfo.environment["PINTACK_STORAGEPROBE"] == "1" }

    static func runIfRequested() {
        guard requested else { return }
        guard ProcessInfo.processInfo.environment["PINTACK_VAULT"]?.isEmpty == false else {
            print("STORAGEPROBE refused: set PINTACK_VAULT to a throwaway folder")
            exit(2)
        }
        NSApp.activate(ignoringOtherApps: true)
        MainWindowController.shared.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { run() }
    }

    private static func run() {
        let panels = WindowManager.shared.openPanels
        guard panels.count >= 2 else {
            finish(["needs at least two open notes; the vault has \(panels.count)"])
            return
        }
        let (a, b) = (panels[0], panels[1])
        var lines = ["PinTack storage probe",
                     "shared website data store: \(NoteEditorView.usesSharedStore ? "ON" : "off")",
                     "note A: \(a.note.title)   note B: \(b.note.title)"]

        // Write in A…
        a.card.editor.evaluateJavaScript("""
            (() => { try { localStorage.setItem("pintack-probe", "from-A");
                           sessionStorage.setItem("pintack-probe", "from-A");
                           return "wrote"; } catch (e) { return "refused: " + e.name } })()
            """) { wrote, _ in
            lines.append("A writes localStorage/sessionStorage: \(wrote as? String ?? "no answer")")
            // …read in B.
            b.card.editor.evaluateJavaScript("""
                (() => { try { return JSON.stringify({
                    local: localStorage.getItem("pintack-probe"),
                    session: sessionStorage.getItem("pintack-probe"),
                    localKeys: localStorage.length,
                    hasIndexedDB: typeof indexedDB !== "undefined",
                    hasCaches: typeof caches !== "undefined" }); } catch (e) { return "refused: " + e.name } })()
                """) { read, _ in
                let answer = read as? String ?? "no answer"
                lines.append("B reads: \(answer)")
                let leaked = answer.contains("\"local\":\"from-A\"") || answer.contains("\"session\":\"from-A\"")
                lines.append(leaked
                    ? "VERDICT: notes SHARE web storage — a key that is not unique per note would collide"
                    : "VERDICT: notes cannot see each other's web storage")
                finish(lines)
            }
        }
    }

    private static func finish(_ lines: [String]) {
        let report = lines.joined(separator: "\n")
        print(report)
        if let out = ProcessInfo.processInfo.environment["PINTACK_STORAGEPROBE_OUT"] {
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }
}
#endif
