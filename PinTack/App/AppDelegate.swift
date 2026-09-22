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
        // The Dock icon comes from the bundle (AppIcon.icon) and nothing else. An earlier version also set
        // NSApp.applicationIconImage at launch, which made the Dock show one icon and then swap to another.

        let vault = VaultStore.shared
        vault.bootstrap()
        AppSettings.shared.load(from: vault.metaURL)
        ShortcutStore.shared.load(from: vault.metaURL)
        LinkPreviewStore.shared.load(from: vault.metaURL)
        StackManager.shared.load(from: vault.metaURL)
        // Re-arm due reminders: anything still in the future goes back on the schedule, and
        // anything that no longer exists is cleared out.
        QuickCapture.shared.install()
        // BEFORE anything can schedule: the self-test shares this bundle identifier, and therefore
        // one notification store, with any installed copy of PinTack. See `ReminderStore`.
        #if DEBUG
        if SelfTest.isRequested { Reminders.shared.store = MemoryReminderStore() }
        #endif
        Reminders.shared.start()
        Reminders.shared.rescheduleAll(vault.notes)
        // Plugins must be known BEFORE the first note window loads, because each page asks for its plugins.
        PluginManager.shared.installBundledPlugins()
        PluginManager.shared.reload()

        NSApp.mainMenu = MainMenuBuilder.build(target: self)
        statusItemController = StatusItemController(target: self)

        #if DEBUG
        MemoryProbe.recordBaseline()
        #endif
        WindowManager.shared.restoreVisibleNotes()
        StackManager.shared.layoutAll()
        if WindowManager.shared.openPanels.isEmpty { AllNotesWindowController.shared.show() }

        if ProcessInfo.processInfo.environment["PINTACK_NO_HOTKEYS"] == nil {
            GlobalHotKeyCenter.shared.reload()
        }
        installKeyMonitor()

        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged),
                                               name: .shortcutsDidChange, object: nil)

        // The first-run card. Skipped under the self-test, which drives it deliberately later on:
        // a modal panel taking key status at launch would break every check that types into a note.
        #if DEBUG
        if !SelfTest.isRequested && MemoryProbe.requested == nil { OnboardingWindow.showIfFirstRun() }
        SelfTest.runIfRequested(appDelegate: self, statusItem: statusItemController)
        MemoryProbe.runIfRequested()
        #else
        OnboardingWindow.showIfFirstRun()
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

    // MARK: - Shortcuts

    /// In-app shortcuts. Notes are non-activating, so while typing in one PinTack is
    /// not the active app and its menu bar is not shown: menu key equivalents alone
    /// would never fire. A local monitor sees keys sent to any of our windows.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleShortcut(event) ?? event
        }
    }

    /// Returns nil when the event was a shortcut and has been handled (or deliberately swallowed),
    /// otherwise the event unchanged. Internal so the self-test can drive it with synthetic keys.
    func handleShortcut(_ event: NSEvent) -> NSEvent? {
        // Let the shortcut recorder see the raw key.
        if NSApp.keyWindow?.firstResponder is ShortcutRecorder.RecorderButton { return event }
        guard let action = ShortcutStore.shared.action(for: event) else {
            // Not one of the app's own shortcuts: is it a plugin command's?
            guard let command = ShortcutStore.shared.pluginCommand(for: event) else { return event }
            if !event.isARepeat { runPluginCommand(command) }
            return nil
        }

        // A held key sends auto-repeat presses. Swallow them: they must not act again (holding
        // ⌥⌘N used to keep making notes) and must not leak into the editor as stray characters.
        // Opacity is the exception, because holding it to fade a note is natural.
        // A stack key with no stacked note in front is not ours: ⌘1 in Settings, ⌥Tab in a lone note.
        if action.isStackAction, StackManager.shared.stack(containing: WindowManager.shared.keyPanel?.note.id ?? "") == nil {
            return event
        }
        if event.isARepeat { return (action == .lessOpaque || action == .moreOpaque) ? handle(action) : nil }
        return handle(action)
    }

    /// Plugin commands run in the focused note's page, where the plugin's code lives.
    private func runPluginCommand(_ command: PluginCommand) {
        guard let panel = WindowManager.shared.focusedPanel else { Toast.show("Click a note first"); return }
        panel.card.editor.send("command.run", ["key": command.key])
    }

    private func handle(_ action: ShortcutAction) -> NSEvent? {
        // Global actions may ALSO arrive here (if Carbon did not consume the press, or in a pass-through
        // case), and Carbon may deliver the same press too. ActionRouter runs a given action once per
        // press regardless of which path gets there first.
        ActionRouter.perform(action)
        return nil
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
    @objc func showAllNotesOnDesktop(_ sender: Any?) { WindowManager.shared.toggleAllOnDesktop() }
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
