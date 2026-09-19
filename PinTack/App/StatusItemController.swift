import AppKit

/// The menu-bar item. The tray popover from the prototype: New note, New todo,
/// All Notes, Recent, Auto-arrange, Toggle corners.
///
/// Built directly on NSStatusItem rather than SwiftUI's MenuBarExtra. The first
/// build used MenuBarExtra and no icon ever showed; NSStatusItem exposes its
/// window and visibility, so a missing icon is something we can test, not guess.
final class StatusItemController: NSObject, NSMenuDelegate {

    let statusItem: NSStatusItem
    private unowned let target: AppDelegate

    init(target: AppDelegate) {
        self.target = target

        // New status items are placed at the LEFT end of the status area, against the
        // notch on a MacBook Pro. With a crowded menu bar (and menu-bar managers such as
        // Thaw or Bartender) that is exactly where items get pushed out of sight, and it
        // is why the first two builds "had no icon". Seed a position near the clock
        // instead. This is only a first-run default: once the user drags the icon, or a
        // menu-bar manager arranges it, their choice wins. macOS stores the value as the
        // distance from the right edge of the screen, in points.
        let name = "PinTack"
        let key = "NSStatusItem Preferred Position \(name)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(160.0, forKey: key)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = name
        super.init()

        if let button = statusItem.button {
            button.image = StatusItemController.templateIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "PinTack"
            button.setAccessibilityLabel("PinTack")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// A monochrome template image, so macOS tints it for light, dark and
    /// highlighted menu bars. A pushpin, matching the note's pin.
    static func templateIcon() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let symbol = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "PinTack")?
            .withSymbolConfiguration(config)
        let image = symbol ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }

    // MARK: NSMenuDelegate: rebuilt each time it opens so "Recent" is current.

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        func add(_ title: String, _ action: ShortcutAction) {
            let i = target.item(title, action)
            MainMenuBuilder.apply(ShortcutStore.shared.combo(for: action), to: i)
            menu.addItem(i)
        }

        add("New Note", .newNote)
        add("New Todo List", .newTodo)
        add("All Notes", .toggleAllNotes)
        menu.addItem(.separator())

        let recent = VaultStore.shared.notes.sorted { $0.modified > $1.modified }.prefix(4)
        if !recent.isEmpty {
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for note in recent {
                let i = NSMenuItem(title: note.title, action: #selector(AppDelegate.revealNote(_:)), keyEquivalent: "")
                i.target = target
                i.representedObject = note.id
                i.image = swatch(for: note)
                menu.addItem(i)
            }
            menu.addItem(.separator())
        }

        add("Auto-Arrange Notes", .autoArrange)
        add("Round / Square Corners", .toggleCorners)
        add("Keyboard Shortcuts", .showShortcuts)
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        settings.target = target
        menu.addItem(withTitle: "Quit PinTack", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// A small dot in the note's color, like the prototype's list chips.
    private func swatch(for note: Note) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        return NSImage(size: size, flipped: false) { rect in
            note.color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            return true
        }
    }
}
