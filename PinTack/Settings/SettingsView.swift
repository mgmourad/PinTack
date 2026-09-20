import SwiftUI
import AppKit

/// The seven settings panes. SPEC.md §9.
///
/// A sidebar rather than SwiftUI's TabView: seven tabs overflowed the window into a "»"
/// menu, which read as unfinished. The sidebar lists every pane at once.
struct SettingsView: View {

    enum Pane: String, CaseIterable, Identifiable {
        case appearance = "Appearance", notes = "Notes", shortcuts = "Shortcuts", editor = "Editor",
             vault = "Vault", plugins = "Plugins", about = "About"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .appearance: return "paintbrush.fill"
            case .notes:      return "note.text"
            case .shortcuts:  return "keyboard.fill"
            case .editor:     return "pencil.and.list.clipboard"
            case .vault:      return "externaldrive.fill"
            case .plugins:    return "puzzlepiece.extension.fill"
            case .about:      return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .appearance: return Color(red: 0.95, green: 0.45, blue: 0.20)
            case .notes:      return Color(red: 0.98, green: 0.72, blue: 0.10)
            case .shortcuts:  return Color(red: 0.36, green: 0.55, blue: 0.95)
            case .editor:     return Color(red: 0.55, green: 0.42, blue: 0.90)
            case .vault:      return Color(red: 0.30, green: 0.70, blue: 0.50)
            case .plugins:    return Color(red: 0.90, green: 0.35, blue: 0.55)
            case .about:      return Color(red: 0.55, green: 0.58, blue: 0.64)
            }
        }
    }

    /// The pane shown first. A variable so the self-test can render the others.
    static var initialPane: Pane = .appearance
    @State private var selection: Pane = SettingsView.initialPane
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 196)
                .background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(selection.rawValue)
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 40).padding(.horizontal, 26).padding(.bottom, 6)
                pane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))      // fills under the transparent title bar
        }
        .frame(width: 780, height: 540)
        .tint(Color(nsColor: Brand.accentNS))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Pane.allCases) { p in
                let selected = p == selection
                HStack(spacing: 10) {
                    Image(systemName: p.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(p.tint.gradient))
                    Text(p.rawValue).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color(nsColor: Brand.accentNS) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { selection = p }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)          // clears the traffic lights: the sidebar runs under the title bar
    }

    @ViewBuilder private var pane: some View {
        switch selection {
        case .appearance: AppearancePane()
        case .notes:      NotesPane()
        case .shortcuts:  ShortcutsPane()
        case .editor:     EditorPane()
        case .vault:      VaultPane()
        case .plugins:    PluginsSettingsPane()
        case .about:      AboutPane()
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @ObservedObject var s = AppSettings.shared
    @State private var custom = Color(nsColor: NSColor(hex: AppSettings.shared.defaultColorHex) ?? .yellow)
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginMessage: String? = LoginItem.needsApproval ? "Approve PinTack in System Settings → Login Items to finish." : nil

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            launchAtLogin = LoginItem.isEnabled || (on && LoginItem.needsApproval)
            loginMessage = LoginItem.needsApproval ? "Approve PinTack in System Settings → Login Items to finish." : nil
        } catch {
            // e.g. a build that is not properly signed can be refused. Say so rather than pretend.
            launchAtLogin = LoginItem.isEnabled
            loginMessage = "macOS would not allow it: \(error.localizedDescription)"
        }
    }

    var body: some View {
        Form {
            Picker("App theme", selection: $s.appTheme) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)

            Toggle("Open PinTack at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
            if let loginMessage {
                HStack {
                    Text(loginMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if LoginItem.needsApproval { Button("Open Login Items") { LoginItem.openLoginItemsSettings() } }
                }
            }

            Picker("New notes get", selection: $s.newNoteColor) {
                Text("The default color").tag("default")
                Text("A random color").tag("random")
            }
            .pickerStyle(.segmented)

            LabeledContent("Default note color") {
                HStack(spacing: 8) {
                    ForEach(NotePalette.presets, id: \.hex) { p in
                        Circle().fill(Color(nsColor: NSColor(hex: p.hex) ?? .yellow)).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.black.opacity(0.2)))
                            .overlay(Circle().strokeBorder(Color(nsColor: Brand.accentNS), lineWidth: s.defaultColorHex.uppercased() == p.hex ? 2.5 : 0).padding(-3))
                            .onTapGesture { s.defaultColorHex = p.hex; custom = Color(nsColor: NSColor(hex: p.hex) ?? .yellow) }
                            .help(p.name)
                    }
                    ColorPicker("Custom", selection: $custom, supportsOpacity: false).labelsHidden()
                        .onChange(of: custom) { _, new in s.defaultColorHex = NSColor(new).hexString }
                }
                .opacity(s.newNoteColor == "random" ? 0.35 : 1)
                .disabled(s.newNoteColor == "random")
            }
            Text(s.newNoteColor == "random"
                 ? "Every new note gets one of the five pastel colors at random."
                 : "Text color flips light or dark automatically, so no color can be unreadable.")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Corners", selection: $s.cornerStyle) {
                Text("Rounded").tag("rounded"); Text("Square").tag("square")
            }
            .pickerStyle(.segmented)

            LabeledContent("Default opacity") {
                HStack {
                    Slider(value: $s.defaultOpacity, in: 0.3...1.0).frame(width: 180)
                    Text("\(Int((s.defaultOpacity * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }

            Picker("Note font", selection: $s.fontFamily) {
                Text("System").tag("")
                ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
            }
            Stepper("Font size: \(Int(s.fontSize)) pt", value: $s.fontSize, in: 9...24)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notes

private struct NotesPane: View {
    @ObservedObject var s = AppSettings.shared
    @State private var outline = Color(nsColor: AppSettings.shared.outlineColor)

    var body: some View {
        Form {
            Section("Outline") {
                Toggle("Show outline", isOn: $s.outlineEnabled)
                ColorPicker("Outline color", selection: $outline, supportsOpacity: false)
                    .onChange(of: outline) { _, new in s.outlineColorHex = NSColor(new).hexString }
                LabeledContent("Outline width") {
                    HStack {
                        Slider(value: $s.outlineWidth, in: 1...3, step: 0.5).frame(width: 160)
                        Text(String(format: "%.1f pt", s.outlineWidth)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                Text("This color is also the accent for plugin-contributed UI.").font(.caption).foregroundStyle(.secondary)
                Toggle("Glow on pinned notes", isOn: $s.pinnedGlow)
            }
            Section("New notes") {
                Stepper("Default width: \(Int(s.defaultNoteWidth)) pt", value: $s.defaultNoteWidth, in: 190...700, step: 10)
                Stepper("Default height: \(Int(s.defaultNoteHeight)) pt", value: $s.defaultNoteHeight, in: 120...700, step: 10)
                Picker("Placement", selection: $s.placement) {
                    Text("Cascade").tag("cascade"); Text("Centered").tag("centered"); Text("At cursor").tag("cursor")
                }
                LabeledContent("Auto-save after") {
                    HStack {
                        Slider(value: $s.autosaveSeconds, in: 0.2...5, step: 0.1).frame(width: 160)
                        Text(String(format: "%.1f s", s.autosaveSeconds)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
            }
            Section("Action bar") {
                Toggle("Collapse the action bar again automatically", isOn: $s.actionBarAutoCollapse)
                LabeledContent("Collapse after") {
                    HStack {
                        Slider(value: $s.actionBarCollapseSeconds, in: 2...30, step: 1).frame(width: 160)
                        Text("\(Int(s.actionBarCollapseSeconds)) s").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(!s.actionBarAutoCollapse)
                Text("The action bar is the strip at the bottom of a note. Its > button opens bullets, bold, italic, code and an opacity slider. The countdown only runs while the pointer is away from the bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @State private var revision = 0
    @State private var errors: [ShortcutAction: String] = [:]
    @State private var pluginErrors: [String: String] = [:]
    @ObservedObject private var plugins = PluginManager.shared

    var body: some View {
        VStack(spacing: 0) {
            List {
                pluginSections
                ForEach(["Notes", "Appearance", "Windows", "Data"], id: \.self) { group in
                    Section(group) {
                        ForEach(ShortcutAction.allCases.filter { $0.group == group }, id: \.self) { action in
                            HStack {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(action.title)
                                    if action.isGlobal {
                                        Text("Works from any app").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let e = errors[action] { Text(e).font(.caption2).foregroundStyle(.red) }
                                }
                                Spacer()
                                ShortcutRecorder(onRecord: { combo in record(combo, for: action) },
                                                 current: ShortcutStore.shared.combo(for: action))
                                    .frame(width: 118, height: 24)
                                    .id(revision)
                            }
                        }
                    }
                }
            }
            HStack {
                Text("Click a shortcut, then press the new keys. ⌫ resets one.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset all") { ShortcutStore.shared.resetAll(); errors = [:]; revision += 1 }
            }
            .padding(10)
        }
    }

    /// One section per plugin that registered commands (SPEC.md §9: plugins get their own section).
    @ViewBuilder private var pluginSections: some View {
        let commands = PluginManager.shared.commands
        ForEach(Array(Set(commands.map(\.pluginID))).sorted(), id: \.self) { pid in
            Section(PluginManager.shared.plugin(id: pid)?.name ?? pid) {
                ForEach(commands.filter { $0.pluginID == pid }) { cmd in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(cmd.name)
                            Text("Plugin command · works while a note is focused").font(.caption2).foregroundStyle(.secondary)
                            if let e = pluginErrors[cmd.key] { Text(e).font(.caption2).foregroundStyle(.red) }
                        }
                        Spacer()
                        ShortcutRecorder(onRecord: { combo in recordPlugin(combo, for: cmd) }, current: ShortcutStore.shared.pluginCombo(for: cmd))
                            .frame(width: 118, height: 24)
                            .id(revision)
                    }
                }
            }
        }
    }

    private func recordPlugin(_ combo: KeyCombo?, for cmd: PluginCommand) -> String? {
        if let combo, let other = ShortcutStore.shared.conflictTitle(for: combo, excludingPlugin: cmd.key) {
            let msg = "Already used by “\(other)”"
            pluginErrors[cmd.key] = msg
            return msg
        }
        pluginErrors[cmd.key] = nil
        ShortcutStore.shared.setPlugin(combo, for: cmd)
        revision += 1
        return nil
    }

    private func record(_ combo: KeyCombo?, for action: ShortcutAction) -> String? {
        if let combo, let other = ShortcutStore.shared.conflictTitle(for: combo, excludingAction: action) {
            let msg = "Already used by “\(other)”"
            errors[action] = msg
            return msg
        }
        errors[action] = nil
        ShortcutStore.shared.set(combo, for: action)
        revision += 1
        return nil
    }
}

// MARK: - Editor

private struct EditorPane: View {
    @ObservedObject var s = AppSettings.shared

    var body: some View {
        Form {
            Picker("Default mode", selection: $s.defaultMode) {
                Text("Live Preview").tag("live"); Text("Source").tag("source")
            }
            .pickerStyle(.segmented)
            Toggle("Spellcheck", isOn: $s.spellcheck)
            Toggle("Slash commands (type / for a menu)", isOn: $s.slashCommands)
            Picker("Pasted or picked images", selection: $s.imagePaste) {
                Text("Copy into the vault").tag("copy"); Text("Link in place").tag("link")
            }
            Text("Copying keeps notes self-contained. Linking keeps the original where it is, using its full path.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Bullet") {
                HStack {
                    Text(s.bulletEmoji.isEmpty ? "•  default" : s.bulletEmoji).font(.system(size: 15))
                    Button("Use default") { s.bulletEmoji = "" }.disabled(s.bulletEmoji.isEmpty)
                }
            }
            Text("Right-click the bullet button in a note's action bar to choose an emoji bullet.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Vault

private struct VaultPane: View {
    @State private var orphans: [URL] = []
    @State private var showOrphans = false

    var body: some View {
        Form {
            LabeledContent("Location") {
                Text(VaultStore.shared.vaultURL.path).textSelection(.enabled).lineLimit(2)
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Button("Open in Finder") { NSWorkspace.shared.open(VaultStore.shared.vaultURL) }
                Button("Move vault…") { moveVault() }
            }
            Text("Point your sync client (iCloud Drive, Dropbox, Syncthing) at this folder. It is the whole database.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Export all as JSON…") { ArchiveIO.exportAll() }
                Button("Import archive…") { ArchiveIO.importArchive() }
            }
            Divider()
            Button("Find unused attachments…") { orphans = VaultStore.shared.orphanedAttachments(); showOrphans = true }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showOrphans) { OrphanSheet(orphans: $orphans, isPresented: $showOrphans) }
    }

    /// Moves the files, then relaunches so the new location is used everywhere. SPEC.md §9.
    private func moveVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = "Choose the folder that should contain the PinTack vault."
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let src = VaultStore.shared.vaultURL
        let dest = parent.appendingPathComponent(src.lastPathComponent, isDirectory: true)
        guard dest.standardizedFileURL != src.standardizedFileURL else { return }
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            let a = NSAlert(); a.messageText = "A folder named “\(dest.lastPathComponent)” already exists there."
            a.informativeText = "Pick a different location, or move that folder aside first."; a.runModal(); return
        }
        SaveCoordinator.shared.flushAll()
        do {
            try FileManager.default.moveItem(at: src, to: dest)
            UserDefaults.standard.set(dest.path, forKey: "vaultPath")
        } catch {
            let a = NSAlert(); a.messageText = "Could not move the vault"; a.informativeText = error.localizedDescription; a.runModal(); return
        }
        let a = NSAlert()
        a.messageText = "Vault moved"
        a.informativeText = "PinTack will relaunch to use the new location."
        a.runModal()
        AppRelauncher.relaunch()
    }
}

private struct OrphanSheet: View {
    @Binding var orphans: [URL]
    @Binding var isPresented: Bool
    @State private var selected = Set<URL>()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Unused attachments").font(.headline)
            if orphans.isEmpty {
                Text("Every file in attachments/ is referenced by a note.").foregroundStyle(.secondary)
            } else {
                Text("These files are not referenced by any note. Nothing is deleted until you choose.").font(.caption).foregroundStyle(.secondary)
                List(orphans, id: \.self, selection: $selected) { Text($0.lastPathComponent).font(.system(.body, design: .monospaced)) }
                    .frame(height: 180)
            }
            HStack {
                Spacer()
                Button("Move Selected to Trash") {
                    selected.forEach { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
                    orphans.removeAll { selected.contains($0) }; selected = []
                }
                .disabled(selected.isEmpty)
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 420)
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 10) {
            if let icon = NSApp.applicationIconImage { Image(nsImage: icon).resizable().frame(width: 72, height: 72) }
            Text("PinTack").font(.title.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                .foregroundStyle(.secondary)
            Text("Sticky notes backed by plain Markdown files.").foregroundStyle(.secondary)
            Text("Open source under the GPL-3.0-or-later license.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Window controller

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "PinTack Settings"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.setContentSize(NSSize(width: 780, height: 540))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum AppRelauncher {
    /// Starts a fresh copy of the app, then quits this one.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
