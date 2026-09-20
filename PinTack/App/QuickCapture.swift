import AppKit

/// Quick capture: turning something you are looking at in another app into a note. SPEC.md §8.
///
/// Two ways in, and neither needs Accessibility permission — which matters, because the obvious
/// implementation (synthesising ⌘C into the other app) does, and a sticky-note app has no business
/// asking for the right to watch every keystroke on the machine:
///
///   * **Services.** "New PinTack Note" appears in any app's Services menu whenever text is
///     selected, and macOS hands us that selection because the user chose the item. A keyboard
///     shortcut can be bound to it in System Settings → Keyboard → Keyboard Shortcuts → Services.
///   * **⌥⌘C from anywhere**, which captures what is on the clipboard. Predictable, instant, and
///     it asks for nothing.
///
/// The app the text came from is recorded in the note's frontmatter, so weeks later it is obvious
/// where a stray paragraph came from.
final class QuickCapture: NSObject {

    static let shared = QuickCapture()

    /// Registered as the app's services provider at launch.
    func install() {
        NSApp.servicesProvider = self
        // Without this a freshly built copy can take minutes to appear in other apps' Services
        // menus, which looks exactly like the feature being broken.
        NSUpdateDynamicServices()
    }

    /// The Services entry declared in Info.plist. The signature is fixed by AppKit.
    @objc func captureSelection(_ pasteboard: NSPasteboard, userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error?.pointee = "There was no text to capture." as NSString
            return
        }
        DispatchQueue.main.async { self.capture(text, from: QuickCapture.frontmostAppName()) }
    }

    /// ⌥⌘C from any app: capture the clipboard.
    func captureFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSApp.activate(ignoringOtherApps: true)
            Toast.show("Nothing on the clipboard to capture")
            return
        }
        capture(text, from: QuickCapture.frontmostAppName())
    }

    /// The app in front RIGHT NOW. Read before PinTack activates, or the answer is always PinTack.
    static func frontmostAppName() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return "" }
        return app.localizedName ?? ""
    }

    /// Makes the note, opens it and puts the caret at the end so you can keep typing.
    @discardableResult
    func capture(_ text: String, from source: String) -> Note {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = VaultStore.shared.createNote(body: QuickCapture.body(for: trimmed),
                                                frame: WindowManager.shared.nextCardFrame(size: AppSettings.shared.noteDefaults.size))
        note.source = source
        VaultStore.shared.save(note)

        NSApp.activate(ignoringOtherApps: true)
        let panel = WindowManager.shared.open(note, focus: true, animated: true)
        panel.makeKeyAndOrderFront(nil)
        Toast.show(source.isEmpty ? "Captured" : "Captured from \(source)")
        return note
    }

    /// A first line to find it by, then the text. A single short line is its own title; anything
    /// longer gets the first line promoted to a heading so the note is not called "Lorem ipsum…".
    static func body(for text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let first = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        if lines.count <= 1 && first.count <= 60 { return text + "\n" }
        let title = String(first.prefix(60)) + (first.count > 60 ? "…" : "")
        return "# \(title.isEmpty ? "Captured" : title)\n\n\(text)\n"
    }
}
