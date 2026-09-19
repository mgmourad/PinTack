import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: - App

@main
struct PinTackApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("PinTack", systemImage: "pin.fill") {
            Button("New Note") { WindowManager.shared.newNote() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Show All Notes") { WindowManager.shared.showAll() }
            Button("Open Vault in Finder") {
                NSWorkspace.shared.open(VaultStore.shared.vaultURL)
            }
            Divider()
            Button("Quit PinTack") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar utility, not a Dock app.
        NSApp.setActivationPolicy(.accessory)

        VaultStore.shared.bootstrap()
        WindowManager.shared.restoreVisibleNotes()

        // ⌥⌘N, system-wide. Carbon rather than CGEventTap so no Accessibility
        // permission prompt is required. SPEC.md §10.1.
        GlobalHotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_N),
                                           modifiers: UInt32(cmdKey | optionKey)) {
            WindowManager.shared.newNote()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SaveCoordinator.shared.flushAll()
    }
}

// MARK: - Window manager

final class WindowManager {

    static let shared = WindowManager()
    private var panels: [String: NotePanel] = [:]

    func restoreVisibleNotes() {
        for note in VaultStore.shared.notes where note.visible {
            open(note)
        }
    }

    @discardableResult
    func open(_ note: Note) -> NotePanel {
        if let existing = panels[note.id] {
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        clampToScreen(note)
        let panel = NotePanel(note: note)
        panels[note.id] = panel
        panel.orderFront(nil)
        return panel
    }

    func newNote() {
        let note = VaultStore.shared.createNote()
        let panel = open(note)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(noteID: String) {
        panels[noteID]?.close()
        panels.removeValue(forKey: noteID)
    }

    func showAll() {
        for note in VaultStore.shared.notes {
            note.visible = true
            VaultStore.shared.save(note)
            open(note)
        }
    }

    /// A frame restored from a disconnected display must come back on-screen.
    /// SPEC.md §5.5.
    private func clampToScreen(_ note: Note) {
        let visible = NSScreen.screens.map { $0.visibleFrame }
        if visible.contains(where: { $0.intersects(note.cardFrame) }) { return }
        guard let main = NSScreen.main?.visibleFrame else { return }
        note.cardFrame.origin = NSPoint(x: main.midX - note.cardFrame.width / 2,
                                        y: main.midY - note.cardFrame.height / 2)
    }
}

// MARK: - Settings

/// Phase 1 stub. Full inventory in SPEC.md §9.
final class Settings {

    static let shared = Settings()
    private let d = UserDefaults.standard

    var outlineEnabled: Bool {
        get { d.object(forKey: "outlineEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "outlineEnabled") }
    }

    var outlineWidth: CGFloat {
        get { CGFloat(d.object(forKey: "outlineWidth") as? Double ?? 1.5) }
        set { d.set(Double(newValue), forKey: "outlineWidth") }
    }

    /// Universal accent. Also tints plugin UI, including Runner buttons. SPEC.md §9.
    var outlineColor: NSColor {
        get { NSColor(hex: d.string(forKey: "outlineColor") ?? "#FF9F0A") ?? .systemOrange }
        set { d.set(newValue.hexString, forKey: "outlineColor") }
    }
}

extension NSColor {
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FF9F0A" }
        return String(format: "#%02X%02X%02X",
                      Int(c.redComponent * 255),
                      Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }
}

// MARK: - Global hotkeys

/// Carbon RegisterEventHotKey wrapper.
///
/// This is still the only way to get a true system-wide hotkey on macOS without
/// requiring Accessibility permission. CGEventTap (which does require it) is
/// only needed for modifier-free single-key hotkeys, which v1 does not support.
/// SPEC.md §10.1.
final class GlobalHotKeyCenter {

    static let shared = GlobalHotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false
    private let signature: OSType = 0x50544B59   // 'PTKY'

    private init() {}

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: signature, id: id)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("PinTack: hotkey registration failed with status \(status)")
            return nil
        }
        refs[id] = ref
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs[id] { UnregisterEventHotKey(ref) }
        refs.removeValue(forKey: id)
        handlers.removeValue(forKey: id)
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            guard status == noErr else { return status }
            DispatchQueue.main.async {
                GlobalHotKeyCenter.shared.fire(id: hotKeyID.id)
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
