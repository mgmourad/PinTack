import AppKit

@main
enum PinTackMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItemController: StatusItemController?
    private var keyMonitor: Any?

    /// Unit tests load the app as their host; they must not create windows or touch a real vault.
    private var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isRunningTests else { return }

        // A regular app: Dock icon, menu bar, Cmd-Tab. The notes themselves are
        // non-activating panels, so typing in one still doesn't pull the app forward.
        NSApp.setActivationPolicy(.regular)
        installAppIcon()

        let vault = VaultStore.shared
        vault.bootstrap()
        AppSettings.shared.load(from: vault.metaURL)
        ShortcutStore.shared.load(from: vault.metaURL)

        NSApp.mainMenu = MainMenuBuilder.build(target: self)
        statusItemController = StatusItemController(target: self)

        WindowManager.shared.restoreVisibleNotes()
        if WindowManager.shared.openPanels.isEmpty { AllNotesWindowController.shared.show() }

        if ProcessInfo.processInfo.environment["PINTACK_NO_HOTKEYS"] == nil {
            GlobalHotKeyCenter.shared.reload()
        }
        installKeyMonitor()

        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged),
                                               name: .shortcutsDidChange, object: nil)

        #if DEBUG
        SelfTest.runIfRequested(appDelegate: self, statusItem: statusItemController)
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        SaveCoordinator.shared.flushAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with nothing on screen should show something.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if WindowManager.shared.openPanels.isEmpty && !AllNotesWindowController.shared.isVisible {
            AllNotesWindowController.shared.show()
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("New Note", .newNote))
        menu.addItem(item("All Notes", .toggleAllNotes))
        return menu
    }

    // MARK: - Icon

    /// The Dock icon comes from the asset catalog. Setting it explicitly as well means
    /// a Debug build run from DerivedData shows it even before LaunchServices caches it.
    private func installAppIcon() {
        if let image = NSImage(named: "AppIcon") { NSApp.applicationIconImage = image }
    }

    // MARK: - Shortcuts

    /// In-app shortcuts. Notes are non-activating, so while typing in one PinTack is
    /// not the active app and its menu bar is not shown: menu key equivalents alone
    /// would never fire. A local monitor sees keys sent to any of our windows.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Let the shortcut recorder see the raw key.
            if NSApp.keyWindow?.firstResponder is ShortcutRecorder.RecorderButton { return event }
            guard let action = ShortcutStore.shared.action(for: event) else { return event }
            // Carbon already handles global actions system-wide, so don't run them twice.
            if action.isGlobal && GlobalHotKeyCenter.shared.lastStatus[action] == noErr { return event }
            if ActionRouter.needsFocusedNote(action) && WindowManager.shared.focusedPanel == nil { return event }
            ActionRouter.perform(action)
            return nil
        }
    }

    @objc private func shortcutsChanged() {
        GlobalHotKeyCenter.shared.reload()
        NSApp.mainMenu = MainMenuBuilder.build(target: self)
    }

    // MARK: - Menu targets

    func item(_ title: String, _ action: ShortcutAction) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
        i.target = self
        i.representedObject = action.rawValue
        return i
    }

    @objc func performAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = ShortcutAction(rawValue: raw) else { return }
        ActionRouter.perform(action)
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }
    @objc func showAllNotesOnDesktop(_ sender: Any?) { WindowManager.shared.showAll() }
    @objc func openVaultInFinder(_ sender: Any?) { NSWorkspace.shared.open(VaultStore.shared.vaultURL) }

    @objc func revealNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let note = VaultStore.shared.note(id: id) else { return }
        WindowManager.shared.reveal(note)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let raw = menuItem.representedObject as? String, let action = ShortcutAction(rawValue: raw) else { return true }
        return !ActionRouter.needsFocusedNote(action) || WindowManager.shared.focusedPanel != nil
    }
}
