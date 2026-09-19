import SwiftUI
import AppKit

/// The seven settings panes. SPEC.md §9.
struct SettingsView: View {

    var body: some View {
        TabView {
            AppearancePane().tabItem { Label("Appearance", systemImage: "paintbrush") }
            NotesPane().tabItem { Label("Notes", systemImage: "note.text") }
            ShortcutsPane().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            EditorPane().tabItem { Label("Editor", systemImage: "pencil.and.list.clipboard") }
            VaultPane().tabItem { Label("Vault", systemImage: "externaldrive") }
            PluginsPane().tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
            AboutPane().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 430)
        .tint(Color(nsColor: AppSettings.shared.outlineColor))
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @ObservedObject var s = AppSettings.shared
    @State private var custom = Color(nsColor: AppSettings.shared.noteDefaults.colorHex.isEmpty ? .yellow : (NSColor(hex: AppSettings.shared.defaultColorHex) ?? .yellow))

    var body: some View {
        Form {
            Picker("App theme", selection: $s.appTheme) {
                Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)

            LabeledContent("Default note color") {
                HStack(spacing: 8) {
                    ForEach(NotePalette.presets, id: \.hex) { p in
                        Circle().fill(Color(nsColor: NSColor(hex: p.hex) ?? .yellow)).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.black.opacity(0.2)))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: s.defaultColorHex.uppercased() == p.hex ? 2.5 : 0).padding(-3))
                            .onTapGesture { s.defaultColorHex = p.hex; custom = Color(nsColor: NSColor(hex: p.hex) ?? .yellow) }
                            .help(p.name)
                    }
                    ColorPicker("Custom", selection: $custom, supportsOpacity: false).labelsHidden()
                        .onChange(of: custom) { _, new in s.defaultColorHex = NSColor(new).hexString }
                }
            }
            Text("Text color flips light or dark automatically, so no color can be unreadable.")
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
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @State private var revision = 0
    @State private var errors: [ShortcutAction: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            List {
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
                                ShortcutRecorder(action: action, onRecord: { combo in record(combo, for: action) },
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

    private func record(_ combo: KeyCombo?, for action: ShortcutAction) -> String? {
        if let combo, let other = ShortcutStore.shared.conflict(for: combo, excluding: action) {
            let msg = "Already used by “\(other.title)”"
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

// MARK: - Plugins

private struct PluginsPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Plugins are not built yet").font(.headline)
            Text("The plugin system and the Runner plugin are Phase 4 in SPEC.md. This pane is where installed plugins, their toggles and their settings will live.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            Button("Open plugins folder") {
                try? FileManager.default.createDirectory(at: VaultStore.shared.pluginsURL, withIntermediateDirectories: true)
                NSWorkspace.shared.open(VaultStore.shared.pluginsURL)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "PinTack Settings"
            w.contentViewController = NSHostingController(rootView: SettingsView())
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
