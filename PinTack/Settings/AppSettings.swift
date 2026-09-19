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
    @Published var cornerStyle = "rounded"        // rounded | square
    @Published var defaultOpacity = 1.0
    @Published var fontFamily = ""                // "" = system font
    @Published var fontSize = 13.0

    // Notes
    @Published var outlineEnabled = true
    @Published var outlineColorHex = "#FF9F0A"    // also the accent for plugin UI. SPEC.md §9
    @Published var outlineWidth = 1.5
    @Published var pinnedGlow = true
    @Published var defaultNoteWidth = 280.0
    @Published var defaultNoteHeight = 210.0
    @Published var placement = "cascade"          // cursor | centered | cascade
    @Published var autosaveSeconds = 0.8

    // Editor
    @Published var defaultMode = "live"           // live | source
    @Published var spellcheck = false
    @Published var slashCommands = true
    @Published var imagePaste = "copy"            // copy | link

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

    var noteDefaults: NoteDefaults {
        NoteDefaults(colorHex: defaultColorHex, opacity: defaultOpacity,
                     size: NSSize(width: defaultNoteWidth, height: defaultNoteHeight))
    }

    // MARK: - Persistence

    func load(from metaDirectory: URL) {
        let url = metaDirectory.appendingPathComponent("settings.json")
        fileURL = url
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        loading = true
        defer { loading = false }

        func s(_ k: String) -> String? { dict[k] as? String }
        func d(_ k: String) -> Double? { (dict[k] as? NSNumber)?.doubleValue }
        func b(_ k: String) -> Bool? { dict[k] as? Bool }

        appTheme = s("appTheme") ?? appTheme
        defaultColorHex = s("defaultColor") ?? defaultColorHex
        cornerStyle = s("cornerStyle") ?? cornerStyle
        defaultOpacity = min(1, max(0.3, d("defaultOpacity") ?? defaultOpacity))
        fontFamily = s("fontFamily") ?? fontFamily
        fontSize = min(24, max(9, d("fontSize") ?? fontSize))
        outlineEnabled = b("outlineEnabled") ?? outlineEnabled
        outlineColorHex = s("outlineColor") ?? outlineColorHex
        outlineWidth = min(3, max(1, d("outlineWidth") ?? outlineWidth))
        pinnedGlow = b("pinnedGlow") ?? pinnedGlow
        defaultNoteWidth = max(190, d("defaultNoteWidth") ?? defaultNoteWidth)
        defaultNoteHeight = max(120, d("defaultNoteHeight") ?? defaultNoteHeight)
        placement = s("placement") ?? placement
        autosaveSeconds = min(5, max(0.2, d("autosaveSeconds") ?? autosaveSeconds))
        defaultMode = s("defaultMode") ?? defaultMode
        spellcheck = b("spellcheck") ?? spellcheck
        slashCommands = b("slashCommands") ?? slashCommands
        imagePaste = s("imagePaste") ?? imagePaste

        let known: Set<String> = ["appTheme", "defaultColor", "cornerStyle", "defaultOpacity", "fontFamily", "fontSize",
                                  "outlineEnabled", "outlineColor", "outlineWidth", "pinnedGlow", "defaultNoteWidth",
                                  "defaultNoteHeight", "placement", "autosaveSeconds", "defaultMode", "spellcheck",
                                  "slashCommands", "imagePaste"]
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

    func save() {
        guard let fileURL else { return }
        var dict = extra
        dict["appTheme"] = appTheme
        dict["defaultColor"] = defaultColorHex
        dict["cornerStyle"] = cornerStyle
        dict["defaultOpacity"] = defaultOpacity
        dict["fontFamily"] = fontFamily
        dict["fontSize"] = fontSize
        dict["outlineEnabled"] = outlineEnabled
        dict["outlineColor"] = outlineColorHex
        dict["outlineWidth"] = outlineWidth
        dict["pinnedGlow"] = pinnedGlow
        dict["defaultNoteWidth"] = defaultNoteWidth
        dict["defaultNoteHeight"] = defaultNoteHeight
        dict["placement"] = placement
        dict["autosaveSeconds"] = autosaveSeconds
        dict["defaultMode"] = defaultMode
        dict["spellcheck"] = spellcheck
        dict["slashCommands"] = slashCommands
        dict["imagePaste"] = imagePaste
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        do { try AtomicWriter.write(data, to: fileURL) }
        catch { NSLog("PinTack: settings save failed: \(error)") }
    }
}
