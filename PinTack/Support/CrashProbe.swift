#if DEBUG
import AppKit
import Darwin

/// What happens to your notes when a note's web page process is killed (SPEC.md §17).
///
///     PINTACK_VAULT=/tmp/x PINTACK_CRASHPROBE=1 build/Debug/PinTack.app/Contents/MacOS/PinTack
///     PINTACK_SHARED_WEBSTORE=1 …same…      # with one data store for every note
///
/// A web page can die on its own — WebKit kills a page that runs out of memory, and a page can
/// crash. This types into a note, kills that note's page process on purpose, and reports three
/// things that matter to somebody's work:
///
///   1. is the text still there, in the app and on disk;
///   2. does the note come back by itself;
///   3. do the OTHER notes survive — the question any design that shares one page between notes
///      has to answer, because then one crash takes all of them.
///
/// Debug builds only, throwaway vaults only.
enum CrashProbe {

    static var requested: Bool { ProcessInfo.processInfo.environment["PINTACK_CRASHPROBE"] == "1" }

    static func runIfRequested() {
        guard requested else { return }
        guard ProcessInfo.processInfo.environment["PINTACK_VAULT"]?.isEmpty == false else {
            print("CRASHPROBE refused: set PINTACK_VAULT to a throwaway folder")
            exit(2)
        }
        NSApp.activate(ignoringOtherApps: true)
        MainWindowController.shared.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { run() }
    }

    private static var lines: [String] = []

    private static func run() {
        let panels = WindowManager.shared.openPanels
        guard panels.count >= 2, let victim = panels.first else {
            return finish(["needs at least two open notes; the vault has \(panels.count)"])
        }
        let bystander = panels[1]
        lines = ["PinTack crash probe",
                 "shared website data store: \(NoteEditorView.usesSharedStore ? "ON" : "off")",
                 "victim: \(victim.note.title)   bystander: \(bystander.note.title)"]

        let marker = "CRASHMARK"
        // Typed through the page, as a person types: the text has to travel page → app → disk.
        victim.card.editor.evaluateJavaScript("""
            (() => { const v = window.__pintack && window.__pintack._view; if (!v) return "no editor";
              v.dispatch({ changes: { from: v.state.doc.length, insert: "\\n\(marker)" } }); return "typed"; })()
            """) { typed, _ in
            lines.append("typed into the victim: \(typed as? String ?? "no answer")")
            // Past the page's own 120 ms debounce, so the app has been told. Anything typed inside
            // that window is the part a crash can still take.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let inModel = victim.note.body.contains(marker)
                SaveCoordinator.shared.flush(noteID: victim.note.id)
                let onDisk = (try? String(contentsOf: victim.note.fileURL, encoding: .utf8))?
                    .contains(marker) ?? false
                lines.append("before the kill — in the app: \(inModel), on disk: \(onDisk)")
                kill(victim: victim, bystander: bystander, marker: marker)
            }
        }
    }

    private static func kill(victim: NotePanel, bystander: NotePanel, marker: String) {
        guard let pid = (victim.card.editor.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value,
              pid > 0 else {
            return finish(lines + ["could not find the victim's page process"])
        }
        let bystanderPID = (bystander.card.editor.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
        lines.append("victim page process: \(pid), bystander page process: \(bystanderPID)"
                     + (pid == bystanderPID ? "  (THE SAME PROCESS — one crash takes both)" : "  (separate processes)"))
        Darwin.kill(pid, SIGKILL)

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let inModel = victim.note.body.contains(marker)
            let onDisk = (try? String(contentsOf: victim.note.fileURL, encoding: .utf8))?
                .contains(marker) ?? false
            lines.append("after the kill — in the app: \(inModel), on disk: \(onDisk)")

            // Does either page answer any more? A page that cannot answer is a blank note.
            victim.card.editor.evaluateJavaScript("window.__pintack ? 'alive' : 'no runtime'") { v, error in
                lines.append("victim page: \(v as? String ?? "DEAD (\(error?.localizedDescription ?? "no answer"))")")
                bystander.card.editor.evaluateJavaScript("window.__pintack ? 'alive' : 'no runtime'") { b, error in
                    lines.append("bystander page: \(b as? String ?? "DEAD (\(error?.localizedDescription ?? "no answer"))")")
                    finish(lines)
                }
            }
        }
    }

    private static func finish(_ lines: [String]) {
        let report = lines.joined(separator: "\n")
        print(report)
        if let out = ProcessInfo.processInfo.environment["PINTACK_CRASHPROBE_OUT"] {
            try? report.write(toFile: out, atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }
}
#endif
