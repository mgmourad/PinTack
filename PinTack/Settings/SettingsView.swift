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

        /// Monochrome glyphs, no coloured tiles (owner decision, 2026-09-21): the tiles made the
        /// sidebar look like a copy of System Settings. Outline at rest, filled when chosen.
        /// The pane's tooltip description.
        var summary: String {
            switch self {
            case .appearance: return "App theme, note colours, corners, opacity and font"
            case .notes:      return "Outline, pinned glow, faded notes, new-note size and the action bar"
            case .shortcuts:  return "Every keyboard shortcut, and changing them"
            case .editor:     return "Live Preview or Source, vim mode, pasting, code colours and link previews"
            case .vault:      return "Where the notes live, moving, export, import and tidying up"
            case .plugins:    return "Installed plugins, their permissions and approved commands"
            case .about:      return "Version and licence"
            }
        }

        var symbol: String {
            switch self {
            case .appearance: return "paintpalette"
            case .notes:      return "note.text"
            case .shortcuts:  return "command"
            case .editor:     return "pencil.line"
            case .vault:      return "archivebox"
            case .plugins:    return "puzzlepiece.extension"
            case .about:      return "info.circle"
            }
        }
    }

    /// The pane shown first. A variable so the self-test can render the others.
    static var initialPane: Pane = .appearance
    @ObservedObject private var window = MainWindowModel.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var hovered: Pane?
    @Namespace private var pill

    private var selection: Pane { window.settingsPane }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 208)
                .background(Color.chromeSidebar)
            Rectangle().fill(Color.chromeHairline).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(selection.rawValue)
                    .font(.system(size: 24, weight: .bold))
                    .padding(.top, 22).padding(.horizontal, 26).padding(.bottom, 4)
                pane
                    .id(selection)
                    .transition(.opacity.combined(with: .offset(y: Motion.enabled ? 10 : 0)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.chromeWindow)
            .animation(ChromeMotion.spring, value: selection)
        }
        .tint(Color.chromeHighlight)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Pane.allCases) { p in
                let selected = p == selection
                HStack(spacing: 12) {
                    Image(systemName: p.symbol)
                        .symbolVariant(selected ? .fill : .none)
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 24)
                    Text(p.rawValue).font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    Spacer()
                }
                .padding(.horizontal, 12).frame(height: 36)
                .foregroundStyle(selected ? Color.chromeOnHighlight : Color.primary.opacity(0.82))
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 10).fill(Color.chromeHighlight)
                            .matchedGeometryEffect(id: "pane", in: pill)
                            .shadow(color: Color.chromeHighlight.opacity(0.35), radius: 8, y: 2)
                    } else if hovered == p {
                        RoundedRectangle(cornerRadius: 10).fill(Color.chromeSurfaceHover)
                    }
                }
                .contentShape(Rectangle())
                .onHover { inside in hovered = inside ? p : (hovered == p ? nil : hovered) }
                .onTapGesture { withAnimation(ChromeMotion.spring) { window.settingsPane = p } }
                .tip(p.rawValue, p.summary)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
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
            LabeledContent("App theme") {
                ChromeSegmented(selection: $s.appTheme,
                                options: [("System", "system"), ("Light", "light"), ("Dark", "dark")])
                                    .tip("App theme", "Light, dark, or follow macOS, for this window and the popovers")
            }
            .labeledContentStyle(CentredRow())

            Toggle("Open PinTack at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                .tip("Open at login", "Start PinTack when you log in to your Mac")
            if let loginMessage {
                HStack {
                    Text(loginMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if LoginItem.needsApproval {
                        Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                            .tip("Open Login Items", "Approve PinTack starting at login, in System Settings")
                    }
                }
            }

            LabeledContent("New notes get") {
                ChromeSegmented(selection: $s.newNoteColor,
                                options: [("The default color", "default"), ("A random color", "random")])
                                    .tip("New notes get", "Every new note in the default colour, or one picked at random")
            }
            .labeledContentStyle(CentredRow())

            LabeledContent("Default note color") {
                HStack(spacing: 8) {
                    ForEach(NotePalette.presets, id: \.hex) { p in
                        Circle().fill(Color(nsColor: NSColor(hex: p.hex) ?? .yellow)).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.black.opacity(0.2)))
                            .overlay(Circle().strokeBorder(Color(nsColor: Brand.accentNS), lineWidth: s.defaultColorHex.uppercased() == p.hex ? 2.5 : 0).padding(-3))
                            .onTapGesture { s.defaultColorHex = p.hex; custom = Color(nsColor: NSColor(hex: p.hex) ?? .yellow) }
                            .tip(p.name, "Make this the colour new notes start in")
                    }
                    ColorPicker("Custom", selection: $custom, supportsOpacity: false).labelsHidden()
                        .tip("Custom colour", "Pick any colour for new notes")
                        .onChange(of: custom) { _, new in s.defaultColorHex = NSColor(new).hexString }
                }
                .opacity(s.newNoteColor == "random" ? 0.35 : 1)
                .disabled(s.newNoteColor == "random")
            }
            Text(s.newNoteColor == "random"
                 ? "Every new note gets one of the five pastel colors at random."
                 : "Text color flips light or dark automatically, so no color can be unreadable.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Corners") {
                ChromeSegmented(selection: $s.cornerStyle, options: [("Rounded", "rounded"), ("Square", "square")])
                    .tip("Corners", "Rounded or square corners on every note")
            }
            .labeledContentStyle(CentredRow())

            LabeledContent("Default opacity") {
                HStack {
                    Slider(value: $s.defaultOpacity, in: 0.3...1.0).frame(width: 180)
                        .tip("Default opacity", "How see-through new notes start")
                    Text("\(Int((s.defaultOpacity * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }

            Picker("Note font", selection: $s.fontFamily) {
                Text("System").tag("")
                ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
            }
                    .tip("Note font", "The typeface every note is written in")
            Stepper("Font size: \(Int(s.fontSize)) pt", value: $s.fontSize, in: 9...24)
                .tip("Font size", "The text size in every note")
        }
        .chromeForm()
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
                    .tip("Show outline", "Draw a border around every note")
                ColorPicker("Outline color", selection: $outline, supportsOpacity: false)
                    .tip("Outline colour", "The colour of that border")
                    .onChange(of: outline) { _, new in s.outlineColorHex = NSColor(new).hexString }
                LabeledContent("Outline width") {
                    HStack {
                        Slider(value: $s.outlineWidth, in: 1...3, step: 0.5).frame(width: 160)
                            .tip("Outline width", "How thick the border is")
                        Text(String(format: "%.1f pt", s.outlineWidth)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                Text("This color is also the accent for plugin-contributed UI.").font(.caption).foregroundStyle(.secondary)
                Toggle("Glow on pinned notes", isOn: $s.pinnedGlow)
                    .tip("Pinned glow", "A halo around notes pinned on top")
                LabeledContent("Glow strength") {
                    HStack {
                        Slider(value: $s.pinnedGlowStrength, in: 0.25...AppSettings.maxGlowStrength).frame(width: 160)
                            .tip("Glow strength", "How bright the pinned glow is, up to 200%")
                        Text("\(Int((s.pinnedGlowStrength * 100).rounded()))%")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!s.pinnedGlow)
            }
            Section("Faded notes") {
                Toggle("Show a faded note fully while the pointer is over it", isOn: $s.hoverRevealsNote)
                    .tip("Reveal on hover", "A see-through note turns solid while the pointer is over it")
                Text("Keep notes see-through so they stay out of the way, and still read one the moment you reach for it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("New notes") {
                Stepper("Default width: \(Int(s.defaultNoteWidth)) pt", value: $s.defaultNoteWidth, in: 190...700, step: 10)
                    .tip("Default width", "How wide a new note is")
                Stepper("Default height: \(Int(s.defaultNoteHeight)) pt", value: $s.defaultNoteHeight, in: 120...700, step: 10)
                    .tip("Default height", "How tall a new note is")
                Picker("Placement", selection: $s.placement) {
                    Text("Cascade").tag("cascade"); Text("Centered").tag("centered"); Text("At cursor").tag("cursor")
                }
                        .tip("Placement", "Where a new note appears on the screen")
                LabeledContent("Auto-save after") {
                    HStack {
                        Slider(value: $s.autosaveSeconds, in: 0.2...5, step: 0.1).frame(width: 160)
                            .tip("Auto-save", "How long after you stop typing a note is saved")
                        Text(String(format: "%.1f s", s.autosaveSeconds)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
            }
            Section("Action bar") {
                Toggle("Collapse the action bar again automatically", isOn: $s.actionBarAutoCollapse)
                    .tip("Auto-collapse", "Fold the action bar's tools away again by themselves")
                LabeledContent("Collapse after") {
                    HStack {
                        Slider(value: $s.actionBarCollapseSeconds, in: 2...30, step: 1).frame(width: 160)
                            .tip("Collapse after", "How long the action bar's tools stay open")
                        Text("\(Int(s.actionBarCollapseSeconds)) s").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                .disabled(!s.actionBarAutoCollapse)
                Text("The action bar is the strip at the bottom of a note. Its > button opens bullets, bold, italic, code and an opacity slider. The countdown only runs while the pointer is away from the bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .chromeForm()
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
                ForEach(["Notes", "Appearance", "Windows", "Stacks", "Data"], id: \.self) { group in
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
                                    .tip(action.title, "Click, then press the new keys; ⌫ resets it")
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
                    .tip("Reset all", "Put every shortcut back to its default")
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
                            .tip(cmd.name, "Click, then press the new keys; ⌫ resets it")
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
    @State private var inlineCode = Color(nsColor: NSColor(hex: AppSettings.shared.inlineCodeColorHex) ?? .black)
    @State private var codeBlock = Color(nsColor: NSColor(hex: AppSettings.shared.codeBlockColorHex)
                                         ?? NSColor(srgbRed: 0.106, green: 0.118, blue: 0.149, alpha: 1))

    var body: some View {
        Form {
            LabeledContent("Default mode") {
                ChromeSegmented(selection: $s.defaultMode, options: [("Live Preview", "live"), ("Source", "source")])
                    .tip("Default mode", "How notes open: formatted, or as plain Markdown")
            }
            .labeledContentStyle(CentredRow())

            Section("Vim mode") {
                Toggle("Vim keys in every note", isOn: $s.vimMode)
                    .tip("Vim mode", "Vim keys in every note, with a command bar and line numbers")
                Text("For people who never want to reach for the mouse. Esc for normal mode; : or / turns the note's action bar into a command bar. :w saves, :q closes the note. A line-number gutter runs down every note.")
                    .font(.caption).foregroundStyle(.secondary)
                if s.vimMode && !s.vimNoticeShown { VimNoticeBanner { s.vimNoticeShown = true } }
            }

            Section {
            Toggle("Spellcheck", isOn: $s.spellcheck)
                .tip("Spellcheck", "Underline misspelled words as you type")
            Toggle("Slash commands (type / for a menu)", isOn: $s.slashCommands)
                .tip("Slash commands", "Type / in a note for a menu of formatting and actions")
            Toggle("Paste rich text as Markdown", isOn: $s.pasteAsMarkdown)
                .tip("Paste as Markdown", "Keep headings, links, lists and tables when pasting from a web page")
            Text("Copying from a web page or an email keeps its headings, links, lists and tables. Hold Shift when pasting (⇧⌘V) to paste the plain text instead.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Pasted or picked images", selection: $s.imagePaste) {
                Text("Copy into the vault").tag("copy"); Text("Link in place").tag("link")
            }
                    .tip("Pasted images", "Copy pictures into the vault, or link to where they already are")
            Text("Copying keeps notes self-contained. Linking keeps the original where it is, using its full path.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Bullet") {
                HStack {
                    Text(s.bulletEmoji.isEmpty ? "•  default" : s.bulletEmoji).font(.system(size: 15))
                    Button("Use default") { s.bulletEmoji = "" }.disabled(s.bulletEmoji.isEmpty)
                        .tip("Use default bullet", "Go back to the plain • bullet")
                }
            }
            Text("Right-click the bullet button in a note's action bar to choose an emoji bullet.")
                .font(.caption).foregroundStyle(.secondary)

            }

            Section("Inline code") {
                ColorPicker("Background", selection: $inlineCode, supportsOpacity: false)
                    .tip("Inline code background", "The colour behind `code` between single backticks")
                    .onChange(of: inlineCode) { _, new in s.inlineCodeColorHex = NSColor(new).hexString }
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: $s.inlineCodeOpacity, in: 0...1).frame(width: 160)
                            .tip("Inline code opacity", "How solid that background is")
                        Text("\(Int((s.inlineCodeOpacity * 100).rounded()))%")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                HStack {
                    Text(s.inlineCodeColorHex.isEmpty
                         ? "Automatic: dark on light notes, light on dark ones."
                         : "Used on every note, whatever its color.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Automatic") { s.inlineCodeColorHex = "" }
                        .tip("Automatic", "Dark on light notes, light on dark ones")
                        .disabled(s.inlineCodeColorHex.isEmpty)
                }
                Text("The background behind `code` written between single backticks.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Code blocks") {
                ColorPicker("Background", selection: $codeBlock, supportsOpacity: false)
                    .tip("Code block background", "The panel behind a fenced code block")
                    .onChange(of: codeBlock) { _, new in s.codeBlockColorHex = NSColor(new).hexString }
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: $s.codeBlockOpacity, in: 0...1).frame(width: 160)
                            .tip("Code block opacity", "How solid that panel is")
                        Text("\(Int((s.codeBlockOpacity * 100).rounded()))%")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                HStack {
                    Text(s.codeBlockColorHex.isEmpty
                         ? "Automatic: a dark panel on every note, whatever colour it is."
                         : "Used on every note, whatever its color.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Automatic") { s.codeBlockColorHex = "" }
                        .tip("Automatic", "A dark panel on every note, whatever its colour")
                        .disabled(s.codeBlockColorHex.isEmpty)
                }
                Text("The panel behind a fenced block written between triple backticks. Syntax colours follow the panel, so a light background switches them back to the light set.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Line numbers in code blocks", isOn: $s.codeLineNumbers)
                    .tip("Code line numbers", "Number each code block's lines from 1")
                Text(s.vimMode
                     ? "Vim mode is on, so the note numbers every line itself and code blocks follow it."
                     : "Each block numbers its own lines from 1. The numbers are drawn beside the code, never copied with it.")
                    .font(.caption).foregroundStyle(.secondary)
            }


            Section {
                Toggle("Link previews", isOn: $s.linkPreviews)
                    .tip("Link previews", "Show a web address on its own line as a card; contacts that site")
                Text("""
                     A web address pasted on a line of its own is shown as a card with the page's \
                     title, description and picture. Hover the card and click ✕ to go back to the \
                     plain address.

                     This is the only feature that contacts a website. While it is on, pasting a \
                     link asks that site for the page, so the site can see your IP address and that \
                     you saved the link. Everything it sends back is stored in your vault and \
                     nothing else about you is sent. Off by default.
                     """)
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear saved previews") { LinkPreviewStore.shared.clearCache() }
                    .tip("Clear saved previews", "Forget every preview card fetched so far")
                    .disabled(!s.linkPreviews)
            }
        }
        .chromeForm()
    }
}

// MARK: - Vault

private struct VaultPane: View {
    @State private var orphans: [VaultStore.Orphan] = []
    @State private var scannedNotes = 0
    @State private var showOrphans = false

    var body: some View {
        Form {
            LabeledContent("Location") {
                Text(VaultStore.shared.vaultURL.path).textSelection(.enabled).lineLimit(2)
                    .tip("Vault location", "The folder that holds every note; point your sync client at it")
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Button("Open in Finder") { NSWorkspace.shared.open(VaultStore.shared.vaultURL) }
                    .tip("Open in Finder", "Show the vault folder in Finder")
                Button("Move vault…") { moveVault() }
                    .tip("Move vault", "Move the whole vault to another folder, then relaunch")
            }
            Text("Point your sync client (iCloud Drive, Dropbox, Syncthing) at this folder. It is the whole database.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Export all as JSON…") { ArchiveIO.exportAll() }
                    .tip("Export all", "Save every note into one JSON archive")
                Button("Import archive…") { ArchiveIO.importArchive() }
                    .tip("Import archive", "Bring notes in from a PinTack archive")
            }
            Divider()
            Button("Find unused attachments…") {
                let result = VaultStore.shared.orphanedAttachments()
                orphans = result.orphans
                scannedNotes = result.scannedNotes
                showOrphans = true
            }
            .tip("Find unused attachments", "List pictures no note mentions any more, to clear them out")
            Text("Editing a picture writes a new file and keeps the original, so spare copies build up over time.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .chromeForm()
        .sheet(isPresented: $showOrphans) { OrphanSheet(orphans: $orphans, scannedNotes: scannedNotes, isPresented: $showOrphans) }
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
    @Binding var orphans: [VaultStore.Orphan]
    let scannedNotes: Int
    @Binding var isPresented: Bool
    @State private var selected = Set<VaultStore.Orphan>()

    private var totalBytes: Int { orphans.filter { selected.contains($0) }.reduce(0) { $0 + $1.bytes } }
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Unused attachments").font(.headline)

            if scannedNotes == 0 {
                // Never offer to delete pictures when the scan read no notes at all: with nothing to
                // compare against, EVERY attachment looks unreferenced.
                Label("No notes could be read, so nothing can be called unused. Nothing will be deleted.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            } else if orphans.isEmpty {
                Text("Every file in attachments/ is referenced by a note.").foregroundStyle(.secondary)
            } else {
                Text("Checked against \(scannedNotes) notes. These files are not mentioned by any of them. "
                     + "Nothing is deleted until you choose, and deleting moves them to the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
                List(orphans, id: \.self, selection: $selected) { orphan in
                    HStack {
                        Text(orphan.name).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(OrphanSheet.formatter.string(fromByteCount: Int64(orphan.bytes)))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .frame(height: 200)
                HStack {
                    Button(selected.count == orphans.count ? "Select None" : "Select All") {
                        selected = selected.count == orphans.count ? [] : Set(orphans)
                    }
                    .tip(selected.count == orphans.count ? "Select None" : "Select All", "Pick every unused file, or none")
                    Text(selected.isEmpty
                         ? "\(orphans.count) unused, \(OrphanSheet.formatter.string(fromByteCount: Int64(orphans.reduce(0) { $0 + $1.bytes }))) in total"
                         : "\(selected.count) selected, \(OrphanSheet.formatter.string(fromByteCount: Int64(totalBytes)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Move Selected to Trash") {
                    for orphan in selected { try? FileManager.default.trashItem(at: orphan.url, resultingItemURL: nil) }
                    orphans.removeAll { selected.contains($0) }
                    selected = []
                }
                .disabled(selected.isEmpty || scannedNotes == 0)
                .tip("Move Selected to Trash", "Put the picked files in the Trash; notes are not touched")
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
                    .tip("Done", "Close this list")
            }
        }
        .padding(18).frame(width: 460)
    }
}

// MARK: - About

private struct AboutPane: View {
    /// Height of the pane heading above this view ("About": 22pt bold plus its padding). Taking it
    /// off the bottom centres the block in the WINDOW rather than in the space under the heading,
    /// which is what the eye reads as centred.
    private static let headingHeight: CGFloat = 72

    var body: some View {
        // Bigger than it was (owner, 2026-09-26): this pane is mostly empty, and the icon is the
        // owner's own artwork.
        VStack(spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable().interpolation(.high)
                    .frame(width: 160, height: 160)
                    .shadow(color: Color(nsColor: Brand.accentNS).opacity(0.35), radius: 26)
                    .tip("PinTack", "Sticky notes backed by plain Markdown files")
            }
            VStack(spacing: 8) {
                Text("PinTack").font(.system(size: 34, weight: .bold))
                Text(Brand.slogan)
                    .font(Brand.sloganFont(size: 17))
                    .foregroundStyle(Color(nsColor: Brand.accentNS))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")"
                     + " (build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                Text("Sticky notes backed by plain Markdown files.").font(.system(size: 15))
                Text("Open source under the GPL-3.0-or-later license.").font(.system(size: 13))
            }
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.bottom, AboutPane.headingHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

// MARK: - Window controller

/// The Settings TAB of the one PinTack window (MainWindow.swift), behind the same calls as before.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    var window: NSWindow? { MainWindowController.shared.window }
    func show() { MainWindowController.shared.show(.settings) }
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


// MARK: - Vim mode's one-time notice

/// What the first-time vim banner says, apart from the view so the self-test can read it (SwiftUI
/// puts none of its views into the accessibility tree AppKit hands out). SPEC.md §4.6.
enum VimNotice {
    static let title = "Vim mode is on — a word before you start"
    static let points: [String] = [
        "Notes start in NORMAL mode: press i to type, Esc to stop. The mode shows in the action bar.",
        "Tables are folds, the way vim folds text. The gutter shows one like 3 [+3]: j stands on it, j again steps past it. zo, za or a click on [+] shows its Markdown; zc folds it back, zR and zM open or fold every table. dd or x while standing on a folded table edits its first row, so open it first to edit a cell.",
        "Pictures are drawn as blocks in Live Preview. The moment the cursor reaches one it opens up into its raw Markdown, so the note can jump in height as you pass, and x on a picture's first character turns it into a plain link. Resizing and cropping a picture still need the mouse. If anything feels off, switch the note to Source (⌥⌘M): everything is plain text there.",
        "Line numbers count the note's visible lines, starting after its hidden header. A hidden ``` fence keeps its number without showing it, so 12G always means the 12th line.",
        "There are no splits, tabs or :e — a note is one buffer. :w, :q, :wq, :x and ZZ work.",
        "Vim keys here are for moving around short notes. For full vim-style writing of longer documents, Obsidian or VS Code is the better fit.",
    ]
    static let dismiss = "Got it"
}

/// Shown under the switch the first time vim mode is turned on, and never again once dismissed.
/// A banner rather than an alert: it stays until it is read and acknowledged, instead of vanishing
/// with the first click.
private struct VimNoticeBanner: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(VimNotice.title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.chromeHighlight)
            ForEach(VimNotice.points, id: \.self) { point in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(point).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(VimNotice.dismiss, action: onDismiss).buttonStyle(ChromeProminentButtonStyle())
                    .tip("Got it", "Dismiss this notice for good")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.chromeHighlight.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.chromeHighlight.opacity(0.55), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
