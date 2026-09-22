#if DEBUG
import AppKit

/// The tutorial's pictures (SPEC.md §8.4), taken from the running app rather than drawn by hand:
/// every slide shows a real note, a real window, a real menu.
///
///     scripts/make-tutorial-shots.sh
///
/// It builds one scene per slide against a throwaway vault, photographs the windows the same way
/// the self-test does, and writes the PNGs into `PinTack/Resources/Tutorial/`, where the app bundles
/// them. Debug only; nothing here ships.
enum TutorialShots {

    static var requestedDirectory: URL? {
        ProcessInfo.processInfo.environment["PINTACK_TUTORIAL_SHOTS"].map { URL(fileURLWithPath: $0) }
    }

    static func runIfRequested() {
        guard let out = requestedDirectory else { return }
        guard ProcessInfo.processInfo.environment["PINTACK_VAULT"]?.isEmpty == false else {
            print("TUTORIAL SHOTS refused: set PINTACK_VAULT to a throwaway folder")
            exit(2)
        }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        NSApp.activate(ignoringOtherApps: true)
        MainWindowController.shared.close()
        for panel in WindowManager.shared.openPanels { WindowManager.shared.close(noteID: panel.note.id) }
        AppSettings.shared.pinnedGlow = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { run(scenes, out: out) }
    }

    // MARK: - The scenes

    private typealias Scene = (name: String, build: (@escaping ([NotePanel]) -> Void) -> Void)

    private static var scenes: [Scene] {
        [
            ("live-preview", { done in
                note("""
                     Release checklist

                     **Friday**, before the *freeze*:

                     - drain `web01`
                     - tag the build
                     - tell #ops

                     > Rollback is one command.
                     """, size: NSSize(width: 380, height: 300), colour: "#FFE9A8", caret: 2, then: done)
            }),
            ("slash-menu", { done in
                note("Sprint notes\n", size: NSSize(width: 380, height: 320), colour: "#D9F3C9", caret: .max) { panels in
                    // The menu opens on the slash being TYPED, so it is typed, as the editor's own
                    // tests do it — putting a "/" in the text would just show a slash.
                    panels[0].card.editor.evaluateJavaScript("""
                        (() => { const v = window.__pintack._view; v.focus();
                          v.dispatch({ selection: { anchor: v.state.doc.length } });
                          for (const ch of "\\n/") { const s = v.state.selection.main;
                            v.dispatch({ changes: { from: s.from, to: s.to, insert: ch },
                                         selection: { anchor: s.from + 1 }, userEvent: "input.type" }); } })()
                        """)
                    after(1.0) { done(panels) }
                }
            }),
            ("code", { done in
                note("""
                     Useful commands

                     ```powershell
                     Get-Process |
                       Sort-Object CPU -Descending |
                       Select-Object -First 5
                     ```

                     ```bash
                     ssh web01 'uptime'
                     ```
                     """, size: NSSize(width: 420, height: 330), colour: "#CFE6FF", caret: 0, then: done)
            }),
            ("todo", { done in
                note("""
                     @Todo Patch Tuesday

                     - [x] snapshot the VMs
                     - [x] ring 1
                     - [ ] ring 2
                     - [ ] ring 3
                     - [ ] close the change
                     """, size: NSSize(width: 340, height: 280), colour: "#F6D6E8", tags: ["todo", "ops"], caret: 0, then: done)
            }),
            ("pin", { done in
                note("On-call numbers\n\nNOC  1-555-0134\nPager  1-555-0199",
                     size: NSSize(width: 320, height: 220), colour: "#FFD8B8", caret: 0) { panels in
                    panels[0].note.pinned = true
                    panels[0].applyPinned()
                    after(0.4) { done(panels) }
                }
            }),
            ("stack", { done in
                let bodies = ["Deploy plan\n\n1. drain\n2. deploy\n3. verify",
                              "Server list\n\nweb01\nweb02\ndb01",
                              "Rollback\n\n`git revert v4.2.1`"]
                let colours = ["#FFE9A8", "#D9F3C9", "#CFE6FF"]
                var notes: [Note] = []
                for (i, body) in bodies.enumerated() {
                    let n = VaultStore.shared.createNote(body: body, frame: NSRect(x: 420, y: 320, width: 340, height: 250))
                    n.colorHex = colours[i]
                    VaultStore.shared.save(n)
                    WindowManager.shared.open(n)
                    notes.append(n)
                }
                after(0.8) {
                    _ = StackManager.shared.create(name: "Tuesday release", noteIDs: notes.map(\.id))
                    after(1.2) { done(notes.compactMap { WindowManager.shared.panel(for: $0.id) }) }
                }
            }),
            ("vim", { done in
                AppSettings.shared.vimMode = true
                note("""
                     Runbook

                     | host | role |
                     | --- | --- |
                     | web01 | front |
                     | db01 | data |

                     last line
                     """, size: NSSize(width: 400, height: 300), colour: "#E7DFFA", caret: 0) { panels in
                    after(1.6) {
                        panels[0].card.editor.evaluateJavaScript(
                            "(() => { const v = window.__pintack._view; v.focus(); v.dispatchEvent; "
                            + "for (const k of ['j','j']) v.contentDOM.dispatchEvent(new KeyboardEvent('keydown', { key: k, bubbles: true })); })()")
                        after(0.8) { done(panels) }
                    }
                }
            }),
            ("tags", { done in
                note("Northwind ring\n\nPilot users: 40\nNext wave: Monday",
                     size: NSSize(width: 340, height: 240), colour: "#D9F3C9",
                     tags: ["ops", "northwind", "intune"], caret: 0, then: done)
            }),
            ("all-notes", { done in
                sampleVault()
                AllNotesModel.shared.mode = .folders
                AllNotesWindowController.shared.show()
                after(1.0) { done([]) }
            }),
            ("stacks-tab", { done in
                AllNotesModel.shared.mode = .stacks
                AllNotesWindowController.shared.show()
                after(0.8) { done([]) }
            }),
            ("todos-tab", { done in
                AllNotesModel.shared.mode = .todo
                AllNotesWindowController.shared.show()
                after(0.8) { done([]) }
            }),
            ("settings", { done in
                MainWindowModel.shared.settingsPane = .notes
                SettingsWindowController.shared.show()
                after(0.9) { done([]) }
            }),
        ]
    }

    // MARK: - Running them

    private static func run(_ rest: [Scene], out: URL) {
        guard let scene = rest.first else {
            print("TUTORIAL SHOTS written to \(out.path)")
            NSApp.terminate(nil)
            return
        }
        scene.build { panels in
            let url = out.appendingPathComponent("\(scene.name).png")
            let finish = {
                for panel in WindowManager.shared.openPanels { WindowManager.shared.close(noteID: panel.note.id) }
                MainWindowController.shared.close()
                AppSettings.shared.vimMode = false
                after(0.5) { run(Array(rest.dropFirst()), out: out) }
            }
            if panels.isEmpty {
                guard let window = MainWindowController.shared.window else { finish(); return }
                SelfTest.snapshot(window: window, to: url, backdrop: nil) { finish() }
            } else if panels.count > 1 {
                SelfTest.snapshotPile(panels, to: url) { finish() }
            } else {
                SelfTest.snapshot(window: panels[0], to: url, backdrop: nil) { finish() }
            }
        }
    }

    /// One note, opened, its caret put where the slide wants it, photographed once it has settled.
    private static func note(_ body: String, size: NSSize, colour: String, tags: [String] = [],
                             caret: Int = 0, then done: @escaping ([NotePanel]) -> Void) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                           width: size.width, height: size.height)
        let note = VaultStore.shared.createNote(body: body, tags: tags, frame: frame)
        note.colorHex = colour
        VaultStore.shared.save(note)
        let panel = WindowManager.shared.open(note, focus: true)
        after(1.4) {
            // Live Preview shows the raw Markdown of the caret's own line, so where the caret sits
            // is part of the picture: line 0 keeps every line rendered.
            let line = caret == .max ? "view.state.doc.lines" : String(caret)
            panel.card.editor.evaluateJavaScript("""
                (() => { const v = window.__pintack._view; const n = Math.min(\(line), v.state.doc.lines);
                  v.dispatch({ selection: { anchor: n > 0 ? v.state.doc.line(n).to : 0 } }); v.focus(); })()
                """)
            after(0.7) { done([panel]) }
        }
    }

    /// Enough notes, folders and a stack for the windows to look like somebody's actual desk.
    private static func sampleVault() {
        let folder = VaultStore.shared.createFolder("Operations") ?? ""
        let samples: [(String, String, [String])] = [
            ("Patch Tuesday\n\n- [x] ring 1\n- [ ] ring 2", "#F6D6E8", ["todo", "ops"]),
            ("Cert renewal\n\nExpires 14 Oct. Renew on the build agent.", "#FFE9A8", ["ops"]),
            ("Intune baseline\n\nBitLocker, Defender, updates.", "#D9F3C9", ["intune"]),
            ("Standup\n\n@Todo Standup\n- [ ] blockers", "#CFE6FF", ["todo"]),
            ("Useful commands\n\n```bash\nssh web01 uptime\n```", "#E7DFFA", ["ops"]),
        ]
        for (body, colour, tags) in samples {
            let n = VaultStore.shared.createNote(body: body, folder: folder, tags: tags,
                                                 frame: NSRect(x: 200, y: 200, width: 300, height: 250))
            n.colorHex = colour
            n.visible = false
            VaultStore.shared.save(n)
        }
        NotificationCenter.default.post(name: .vaultDidChange, object: nil)
    }

    private static func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
#endif
