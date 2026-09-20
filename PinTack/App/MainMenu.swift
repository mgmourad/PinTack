import AppKit
import Carbon.HIToolbox

/// The main menu bar, shown while PinTack is the active app (after a Dock click,
/// or while All Notes / Settings is open). Layout follows the prototype:
/// PinTack, File, Edit, Note, Window, Help.
enum MainMenuBuilder {

    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            build(menu)
            item.submenu = menu
            main.addItem(item)
        }

        // Adds an item bound to a ShortcutAction and shows its current binding.
        func action(_ menu: NSMenu, _ title: String, _ a: ShortcutAction) {
            let i = target.item(title, a)
            apply(ShortcutStore.shared.combo(for: a), to: i)
            menu.addItem(i)
        }

        submenu("PinTack") { m in
            m.addItem(withTitle: "About PinTack", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            m.addItem(.separator())
            let settings = m.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
            settings.target = target
            m.addItem(.separator())
            m.addItem(withTitle: "Hide PinTack", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            let others = m.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            others.keyEquivalentModifierMask = [.command, .option]
            m.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Quit PinTack", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }

        submenu("File") { m in
            action(m, "New Note", .newNote)
            action(m, "New Todo List", .newTodo)
            m.addItem(.separator())
            action(m, "Close Note", .close)
            m.addItem(.separator())
            action(m, "Import Archive…", .importArchive)
            action(m, "Export All Notes…", .exportAll)
            m.addItem(.separator())
            let open = m.addItem(withTitle: "Open Vault in Finder", action: #selector(AppDelegate.openVaultInFinder(_:)), keyEquivalent: "")
            open.target = target
        }

        submenu("Edit") { m in
            m.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            let redo = m.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            m.addItem(.separator())
            m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        }

        submenu("Note") { m in
            action(m, "Pin on Top", .pin)
            action(m, "Collapse / Expand", .collapse)
            action(m, "Switch Live Preview / Source", .toggleMode)
            action(m, "Emoji…", .emoji)
            m.addItem(.separator())
            let colors = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "Color")
            for (i, a) in [ShortcutAction.color1, .color2, .color3, .color4, .color5, .color6].enumerated() {
                let item = target.item(NotePalette.presets[i].name, a)
                apply(ShortcutStore.shared.combo(for: a), to: item)
                sub.addItem(item)
            }
            colors.submenu = sub
            m.addItem(colors)
            action(m, "Less Opaque", .lessOpaque)
            action(m, "More Opaque", .moreOpaque)
            action(m, "Round / Square Corners", .toggleCorners)
            m.addItem(.separator())
            action(m, "Delete Note", .deleteNote)
        }

        submenu("Window") { m in
            action(m, "All Notes", .toggleAllNotes)
            action(m, "All Notes by Tag", .allNotesByTag)
            action(m, "Todos", .showTodos)
            action(m, "Templates", .showTemplates)
            m.addItem(.separator())
            action(m, "Auto-Arrange Notes", .autoArrange)
            action(m, "Show All Notes on Desktop", .showAllOnDesktop)
            m.addItem(.separator())
            m.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            m.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
            NSApp.windowsMenu = m
        }

        submenu("Help") { m in
            action(m, "Keyboard Shortcuts", .showShortcuts)
        }
        return main
    }

    /// Shows the binding in the menu without letting AppKit fire it a second time:
    /// the key monitor and Carbon already handle the keys, so the menu item is
    /// display-only when the app is inactive and a normal fallback when it is active.
    static func apply(_ combo: KeyCombo, to item: NSMenuItem) {
        let name = KeyCombo.keyName(combo.keyCode)
        guard name.count == 1 else { return }
        // Lowercased with an explicit .shift in the mask: setting an uppercase keyEquivalent makes
        // AppKit add shift itself and the two ways of saying it fight.
        item.keyEquivalent = name.lowercased()
        var mask: NSEvent.ModifierFlags = []
        if combo.modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        if combo.modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if combo.modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if combo.modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        item.keyEquivalentModifierMask = mask
    }
}
