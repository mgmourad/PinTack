import AppKit
import Combine

extension Notification.Name {
    static let settingsDidChange = Notification.Name("PinTack.settingsDidChange")
}

/// App-wide preferences. SPEC.md §9. Persisted to `<vault>/.pintack/settings.json`
/// so they travel with the vault. Keys this build does not know (plugin settings,
/// stored under the plugin id) are kept and written back untouched.
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // Appearance
    @Published var appTheme = "system"            // system | light | dark
    @Published var defaultColorHex = "#FFE38A"
    @Published var newNoteColor = "default"       // default | random
    @Published var cornerStyle = "rounded"        // rounded | square
    @Published var defaultOpacity = 1.0
    @Published var fontFamily = "Comic Sans MS"   // "" = system font
    @Published var fontSize = 13.0

    // Notes
    @Published var outlineEnabled = true
    @Published var outlineColorHex = "#FF9F0A"    // also the accent for plugin UI. SPEC.md §9
    @Published var outlineWidth = 1.5
    @Published var pinnedGlow = true
    /// How strong the pinned glow is, 1 being the look it always had. SPEC.md §5.4.
    @Published var pinnedGlowStrength = 1.0
    /// Up to 200% (owner, 2026-09-22; it was 160%).
    static let maxGlowStrength = 2.0
    /// A faded note turns fully opaque while the pointer is over it, and fades back after. An
    /// option, off by default (owner, 2026-09-21): someone who faded a note may want it faded.
    @Published var hoverRevealsNote = false
    /// Tag colours the user picked, keyed by the tag in lower case. A tag with no entry keeps the
    /// automatic colour from its name. Global rather than per note, so a tag looks the same
    /// everywhere, which is the point of colouring it at all.
    @Published var tagColors: [String: String] = [:]
    @Published var defaultNoteWidth = 300.0
    @Published var defaultNoteHeight = 250.0
    @Published var placement = "cascade"          // cursor | centered | cascade
    @Published var autosaveSeconds = 0.8
    @Published var actionBarAutoCollapse = true   // re-collapse the note's bottom action bar
    @Published var actionBarCollapseSeconds = 6.0

    // Editor
    @Published var defaultMode = "live"           // live | source
    @Published var spellcheck = false
    @Published var slashCommands = true
    @Published var imagePaste = "copy"            // copy | link
    @Published var bulletEmoji = ""               // "" = the ordinary "- " bullet
    /// Fetch a title, summary and thumbnail for a URL pasted on its own line. OFF by default: it
    /// is the only thing in PinTack that contacts a website. See PinTack/Vault/LinkPreview.swift.
    @Published var linkPreviews = false
    /// Background behind `inline code`. "" means automatic: black on light paper, white on dark,
    /// which is what it always was. A chosen colour is used on every note whatever its paper.
    @Published var inlineCodeColorHex = ""
    @Published var inlineCodeOpacity = 0.15
    /// Fenced code blocks. Empty means automatic, which is a dark slate panel on EVERY note —
    /// a wash of the note's own colour was hard to read and looked washed out (owner, 2026-09-20).
    @Published var codeBlockColorHex = ""
    @Published var codeBlockOpacity = 0.92
    /// Convert pasted rich text (a web page, an email) into Markdown instead of flattening it.
    /// Shift-Cmd-V always pastes the plain text, whatever this says.
    @Published var pasteAsMarkdown = true
    /// Vim mode (owner-approved 2026-09-21): vi keys in every note, a line-number gutter, and the
    /// action bar as the ":" command bar. Off by default — it changes what every key does.
    @Published var vimMode = false
    /// A fenced code block numbers its own lines. Off by default; stands aside while vim mode
    /// numbers the whole note.
    @Published var codeLineNumbers = false
    /// Only a few notes keep a live editor; the rest are parked (SPEC.md §5.11). On by default,
    /// because twenty open notes cost about 695 MB without it and a quarter of that with it.
    @Published var parkIdleNotes = true { didSet { guard !loading else { return }; EditorPool.shared.settingsChanged() } }
    /// How many notes keep a live editor at once — the note you are in and the one before it.
    /// Two by default, with a warm spare page beside them: each page costs about 34 MB, and three
    /// pages in total is what keeps a deskful of twenty notes inside 300 MB (SPEC.md §5.11).
    @Published var editorPoolSize = 2 { didSet { guard !loading else { return }; EditorPool.shared.settingsChanged() } }

    /// Development overrides, so a measurement or a self-test run can set the pool without touching
    /// anybody's settings file: PINTACK_PARK=0 and PINTACK_POOL_SIZE=n.
    var parkIdleNotesEffective: Bool {
        if let raw = ProcessInfo.processInfo.environment["PINTACK_PARK"] { return raw != "0" }
        return parkIdleNotes
    }
    var editorPoolSizeEffective: Int {
        if let raw = ProcessInfo.processInfo.environment["PINTACK_POOL_SIZE"], let n = Int(raw) { return max(1, n) }
        return editorPoolSize
    }
    /// Whether the one-time notice about vim mode's rough edges has been shown. Kept in the vault's
    /// settings like everything else, so it is shown once per vault rather than once per Mac.
    @Published var vimNoticeShown = false

    // Plugins. Which are switched on; each plugin's own values live under its id in `extra`.
    @Published var enabledPlugins: [String: Bool] = [:]

    /// Keys the app owns in settings.json. A plugin id may not equal one, because a plugin's saved
    /// settings are stored under its id in the same file. SPEC.md §12.2.
    static let reservedKeys: Set<String> = [
        "appTheme", "defaultColor", "newNoteColor", "cornerStyle", "defaultOpacity", "fontFamily", "fontSize",
        "outlineEnabled", "outlineColor", "outlineWidth", "pinnedGlow", "defaultNoteWidth", "defaultNoteHeight",
        "placement", "autosaveSeconds", "actionBarAutoCollapse", "actionBarCollapseSeconds", "defaultMode",
        "spellcheck", "slashCommands", "imagePaste", "bulletEmoji", "enabledPlugins", "plugins", "linkPreviews",
        "inlineCodeColor", "inlineCodeOpacity", "codeBlockColor", "codeBlockOpacity", "pasteAsMarkdown",
        "settingsVersion", "hoverRevealsNote", "tagColors", "pinnedGlowStrength", "vimMode",
        "codeLineNumbers", "vimNoticeShown", "parkIdleNotes", "editorPoolSize",
    ]

    /// Bumped when the file's MEANING changes. Version 1 (no key at all) wrote every value, chosen or
    /// not; version 2 writes only what the user changed from the built-in defaults.
    static let fileVersion = 2

    /// Defaults that have since changed, as older builds wrote them. A version-1 file holding one of
    /// these did not record a choice — it recorded whatever the default happened to be that day —
    /// so it is read as "not chosen" and the current default applies. Without this, everyone who
    /// ran an earlier build kept 280 × 210 new notes for ever (found on the owner's Mac, 2026-09-21).
    private static let supersededDefaults: [String: Double] = [
        "defaultNoteWidth": 280,
        "defaultNoteHeight": 210,
    ]

    /// What every key is when nobody has touched it, taken from a fresh instance so it can never
    /// drift from the property initialisers above.
    private static let factoryValues: [String: Any] = AppSettings().values()

    private var fileURL: URL?
    private var extra: [String: Any] = [:]        // unknown keys, preserved. SPEC.md §12.2
    private var loading = false
    private var bag = Set<AnyCancellable>()

    init() {
        objectWillChange
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.didChange() }
            .store(in: &bag)
    }

    var outlineColor: NSColor { NSColor(hex: outlineColorHex) ?? .systemOrange }
    var cornerRadius: CGFloat { cornerStyle == "square" ? 2 : 12 }

    /// Evaluated per new note, so "random" really is a fresh color each time.
    var noteDefaults: NoteDefaults {
        NoteDefaults(colorHex: newNoteColor == "random" ? NotePalette.randomPastel : defaultColorHex,
                     opacity: defaultOpacity,
                     size: NSSize(width: defaultNoteWidth, height: defaultNoteHeight))
    }

    // MARK: - Persistence

    func load(from metaDirectory: URL) {
        let url = metaDirectory.appendingPathComponent("settings.json")
        fileURL = url
        guard let data = try? Data(contentsOf: url),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if dict["settingsVersion"] == nil {
            for (key, old) in AppSettings.supersededDefaults
            where (dict[key] as? NSNumber)?.doubleValue == old {
                dict[key] = nil
            }
        }
        loading = true
        defer { loading = false }

        func s(_ k: String) -> String? { dict[k] as? String }
        func d(_ k: String) -> Double? { (dict[k] as? NSNumber)?.doubleValue }
        func b(_ k: String) -> Bool? { dict[k] as? Bool }
        func i(_ k: String) -> Int? { (dict[k] as? NSNumber)?.intValue }

        appTheme = s("appTheme") ?? appTheme
        defaultColorHex = s("defaultColor") ?? defaultColorHex
        newNoteColor = s("newNoteColor") ?? newNoteColor
        cornerStyle = s("cornerStyle") ?? cornerStyle
        defaultOpacity = min(1, max(0.3, d("defaultOpacity") ?? defaultOpacity))
        fontFamily = s("fontFamily") ?? fontFamily
        fontSize = min(24, max(9, d("fontSize") ?? fontSize))
        outlineEnabled = b("outlineEnabled") ?? outlineEnabled
        outlineColorHex = s("outlineColor") ?? outlineColorHex
        outlineWidth = min(3, max(1, d("outlineWidth") ?? outlineWidth))
        pinnedGlow = b("pinnedGlow") ?? pinnedGlow
        pinnedGlowStrength = min(AppSettings.maxGlowStrength, max(0.25, d("pinnedGlowStrength") ?? pinnedGlowStrength))
        hoverRevealsNote = b("hoverRevealsNote") ?? hoverRevealsNote
        tagColors = (dict["tagColors"] as? [String: String]) ?? tagColors
        defaultNoteWidth = max(190, d("defaultNoteWidth") ?? defaultNoteWidth)
        defaultNoteHeight = max(120, d("defaultNoteHeight") ?? defaultNoteHeight)
        placement = s("placement") ?? placement
        autosaveSeconds = min(5, max(0.2, d("autosaveSeconds") ?? autosaveSeconds))
        actionBarAutoCollapse = b("actionBarAutoCollapse") ?? actionBarAutoCollapse
        actionBarCollapseSeconds = min(30, max(2, d("actionBarCollapseSeconds") ?? actionBarCollapseSeconds))
        defaultMode = s("defaultMode") ?? defaultMode
        spellcheck = b("spellcheck") ?? spellcheck
        slashCommands = b("slashCommands") ?? slashCommands
        imagePaste = s("imagePaste") ?? imagePaste
        bulletEmoji = s("bulletEmoji") ?? bulletEmoji
        linkPreviews = b("linkPreviews") ?? linkPreviews
        inlineCodeColorHex = s("inlineCodeColor") ?? inlineCodeColorHex
        inlineCodeOpacity = min(1, max(0, d("inlineCodeOpacity") ?? inlineCodeOpacity))
        codeBlockColorHex = s("codeBlockColor") ?? codeBlockColorHex
        codeBlockOpacity = min(1, max(0, d("codeBlockOpacity") ?? codeBlockOpacity))
        pasteAsMarkdown = b("pasteAsMarkdown") ?? pasteAsMarkdown
        vimMode = b("vimMode") ?? vimMode
        codeLineNumbers = b("codeLineNumbers") ?? codeLineNumbers
        parkIdleNotes = b("parkIdleNotes") ?? parkIdleNotes
        editorPoolSize = max(1, min(24, i("editorPoolSize") ?? editorPoolSize))
        vimNoticeShown = b("vimNoticeShown") ?? vimNoticeShown
        enabledPlugins = (dict["enabledPlugins"] as? [String: Bool]) ?? enabledPlugins

        let known: Set<String> = ["appTheme", "defaultColor", "cornerStyle", "defaultOpacity", "fontFamily", "fontSize",
                                  "outlineEnabled", "outlineColor", "outlineWidth", "pinnedGlow", "defaultNoteWidth",
                                  "defaultNoteHeight", "placement", "autosaveSeconds", "defaultMode", "spellcheck",
                                  "slashCommands", "imagePaste", "newNoteColor", "actionBarAutoCollapse",
                                  "actionBarCollapseSeconds", "bulletEmoji", "enabledPlugins", "linkPreviews",
                                  "inlineCodeColor", "inlineCodeOpacity", "codeBlockColor",
                                  "codeBlockOpacity", "pasteAsMarkdown", "settingsVersion",
                                  "hoverRevealsNote", "tagColors", "pinnedGlowStrength", "vimMode",
                                  "codeLineNumbers", "vimNoticeShown", "parkIdleNotes", "editorPoolSize"]
        extra = dict.filter { !known.contains($0.key) }
        applyRuntimeEffects()
    }

    private func didChange() {
        guard !loading else { return }
        applyRuntimeEffects()
        save()
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    func applyRuntimeEffects() {
        SaveCoordinator.shared.delay = autosaveSeconds
        switch appTheme {
        case "light": NSApp?.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp?.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp?.appearance = nil
        }
    }

    // MARK: - Plugin settings (kept under the plugin's id, untouched by everything else)

    func pluginSettings(_ id: String) -> [String: Any] { extra[id] as? [String: Any] ?? [:] }

    func setPluginSetting(_ id: String, key: String, value: Any) {
        guard !AppSettings.reservedKeys.contains(id) else { return }
        var values = pluginSettings(id)
        values[key] = value
        extra[id] = values
        save()
    }

    /// Every setting this build owns, as it would be written.
    private func values() -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["appTheme"] = appTheme
        dict["defaultColor"] = defaultColorHex
        dict["newNoteColor"] = newNoteColor
        dict["cornerStyle"] = cornerStyle
        dict["defaultOpacity"] = defaultOpacity
        dict["fontFamily"] = fontFamily
        dict["fontSize"] = fontSize
        dict["outlineEnabled"] = outlineEnabled
        dict["outlineColor"] = outlineColorHex
        dict["outlineWidth"] = outlineWidth
        dict["pinnedGlow"] = pinnedGlow
        dict["pinnedGlowStrength"] = pinnedGlowStrength
        dict["hoverRevealsNote"] = hoverRevealsNote
        dict["tagColors"] = tagColors
        dict["defaultNoteWidth"] = defaultNoteWidth
        dict["defaultNoteHeight"] = defaultNoteHeight
        dict["placement"] = placement
        dict["autosaveSeconds"] = autosaveSeconds
        dict["actionBarAutoCollapse"] = actionBarAutoCollapse
        dict["actionBarCollapseSeconds"] = actionBarCollapseSeconds
        dict["defaultMode"] = defaultMode
        dict["spellcheck"] = spellcheck
        dict["slashCommands"] = slashCommands
        dict["imagePaste"] = imagePaste
        dict["bulletEmoji"] = bulletEmoji
        dict["linkPreviews"] = linkPreviews
        dict["inlineCodeColor"] = inlineCodeColorHex
        dict["inlineCodeOpacity"] = inlineCodeOpacity
        dict["codeBlockColor"] = codeBlockColorHex
        dict["codeBlockOpacity"] = codeBlockOpacity
        dict["pasteAsMarkdown"] = pasteAsMarkdown
        dict["vimMode"] = vimMode
        dict["codeLineNumbers"] = codeLineNumbers
        dict["parkIdleNotes"] = parkIdleNotes
        dict["editorPoolSize"] = editorPoolSize
        dict["vimNoticeShown"] = vimNoticeShown
        dict["enabledPlugins"] = enabledPlugins
        return dict
    }

    /// Writes only what differs from the defaults. A value left at its default is not a choice, and
    /// writing it down anyway freezes it: the next build's better default would never arrive.
    func save() {
        guard let fileURL else { return }
        var dict = extra
        for (key, value) in values() {
            let factory = AppSettings.factoryValues[key] as AnyObject?
            if let factory, (value as AnyObject).isEqual(factory) { continue }
            dict[key] = value
        }
        dict["settingsVersion"] = AppSettings.fileVersion
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        do { try AtomicWriter.write(data, to: fileURL) }
        catch { NSLog("PinTack: settings save failed: \(error)") }
    }
}
