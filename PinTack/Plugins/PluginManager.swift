import Foundation
import AppKit

extension Notification.Name {
    /// The installed/enabled plugin set changed.
    static let pluginsDidChange = Notification.Name("PinTack.pluginsDidChange")
    /// A note was written to disk. `object` is the Note. Plugins see this as `note:save`.
    static let noteDidSave = Notification.Name("PinTack.noteDidSave")
}

struct InstalledPlugin: Identifiable {
    let id: String
    let folder: URL
    let manifest: PluginManifest?
    let error: String?
    var enabled: Bool

    var name: String { manifest?.name ?? id }
    var permissions: [PluginPermission] { manifest?.declaredPermissions ?? [] }
    var isValid: Bool { error == nil && manifest != nil }
}

/// A command a plugin registered (`registerCommand`), bindable to a key. SPEC.md §12.3.
struct PluginCommand: Identifiable, Equatable {
    var key: String              // "<plugin>:<command id>"
    var pluginID: String
    var id: String
    var name: String
    var defaultHotkey: String?
}

/// Finds, validates and serves plugins. SPEC.md §12.
///
/// v1 installation is "drop a folder into <vault>/plugins/ and rescan or restart". There is no
/// marketplace and no in-app browser. Plugins are DISABLED until the user enables them (which shows
/// the permissions they asked for); the bundled Runner ships enabled.
final class PluginManager: ObservableObject {

    static let shared = PluginManager(vault: .shared, settings: .shared,
                                      bundled: Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true))

    @Published private(set) var installed: [InstalledPlugin] = []
    @Published private(set) var commands: [PluginCommand] = []

    let vault: VaultStore
    let settings: AppSettings
    private let bundledURL: URL?

    /// token → the plugin it was issued to and the web view it was issued for.
    private var sessions: [String: (pluginID: String, owner: ObjectIdentifier)] = [:]

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0" }

    init(vault: VaultStore, settings: AppSettings, bundled: URL?) {
        self.vault = vault
        self.settings = settings
        self.bundledURL = bundled
    }

    // MARK: - Discovery

    /// Copies the plugins that ship with the app into the vault, if they are missing or the bundled
    /// copy is newer. A first install is enabled ("Runner ships enabled"); after that the user's
    /// on/off choice is never overridden.
    func installBundledPlugins() {
        guard let bundledURL, let dirs = try? FileManager.default.contentsOfDirectory(at: bundledURL, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: vault.pluginsURL, withIntermediateDirectories: true)
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let id = dir.lastPathComponent
            let dest = vault.pluginsURL.appendingPathComponent(id, isDirectory: true)
            let shipped = PluginManager.readManifest(in: dir)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.copyItem(at: dir, to: dest)
                if settings.enabledPlugins[id] == nil { settings.enabledPlugins[id] = true }
            } else if let shipped, let current = PluginManager.readManifest(in: dest),
                      PluginManifest.compare(shipped.version, current.version) == .orderedDescending {
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: dir, to: dest)
            }
        }
    }

    /// Rescans `<vault>/plugins/`.
    func reload() {
        let fm = FileManager.default
        var found: [InstalledPlugin] = []
        let dirs = (try? fm.contentsOfDirectory(at: vault.pluginsURL, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let folderName = dir.lastPathComponent
            let enabled = settings.enabledPlugins[folderName] ?? false
            guard let manifest = PluginManager.readManifest(in: dir) else {
                found.append(InstalledPlugin(id: folderName, folder: dir, manifest: nil,
                                             error: "manifest.json is missing or is not valid JSON.", enabled: false))
                continue
            }
            do {
                try manifest.validate(folderName: folderName, folder: dir, appVersion: PluginManager.appVersion,
                                      reserved: AppSettings.reservedKeys)
                found.append(InstalledPlugin(id: folderName, folder: dir, manifest: manifest, error: nil, enabled: enabled))
            } catch {
                found.append(InstalledPlugin(id: folderName, folder: dir, manifest: nil, error: error.localizedDescription, enabled: false))
            }
        }
        installed = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        NotificationCenter.default.post(name: .pluginsDidChange, object: nil)
    }

    static func readManifest(in folder: URL) -> PluginManifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(PluginManifest.self, from: data)
    }

    func plugin(id: String) -> InstalledPlugin? { installed.first { $0.id == id } }

    var enabledPlugins: [InstalledPlugin] { installed.filter { $0.enabled && $0.isValid } }

    func setEnabled(_ id: String, _ on: Bool) {
        settings.enabledPlugins[id] = on
        if let i = installed.firstIndex(where: { $0.id == id }) { installed[i].enabled = on }
        if !on { commands.removeAll { $0.pluginID == id } }
        NotificationCenter.default.post(name: .pluginsDidChange, object: nil)
    }

    // MARK: - Sessions (capability tokens)

    /// One entry per enabled plugin for a given web view, each with a fresh random token. The page hands
    /// the token to that plugin's own closure only, and Swift maps it back to the plugin on every call, so
    /// a plugin cannot act as another just by writing a different id into a message.
    func makeSession(for owner: AnyObject) -> [[String: Any]] {
        endSession(for: owner)
        return enabledPlugins.compactMap { p in
            guard let m = p.manifest else { return nil }
            let token = PluginManager.randomToken()
            sessions[token] = (p.id, ObjectIdentifier(owner))
            var entry: [String: Any] = ["id": p.id, "token": token, "main": m.main,
                                        "manifest": m.jsonObject, "settings": settingsValues(for: p)]
            if let s = m.styles { entry["styles"] = s }
            return entry
        }
    }

    func pluginID(forToken token: String, owner: AnyObject) -> String? {
        guard let s = sessions[token], s.owner == ObjectIdentifier(owner) else { return nil }
        return s.pluginID
    }

    func endSession(for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        sessions = sessions.filter { $0.value.owner != id }
    }

    static func randomToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(format: "%016llx", g.next() as UInt64) }.joined()
    }

    // MARK: - Settings values

    /// Manifest defaults overlaid with what the user saved (settings.json, under the plugin's id).
    func settingsValues(for p: InstalledPlugin) -> [String: Any] {
        guard let specs = p.manifest?.settings else { return [:] }
        let saved = settings.pluginSettings(p.id)
        var out: [String: Any] = [:]
        for s in specs { out[s.key] = PluginManager.coerce(saved[s.key], to: s) ?? s.defaultValue.any }
        return out
    }

    /// Accepts a value only if it has the type the manifest declared.
    static func coerce(_ value: Any?, to spec: PluginSettingSpec) -> Any? {
        guard let value else { return nil }
        switch spec.type {
        case "number":  return (value as? NSNumber).flatMap { $0 === kCFBooleanTrue || $0 === kCFBooleanFalse ? nil : $0.doubleValue }
        case "boolean": return value as? Bool
        case "string":  return value as? String
        default:        return nil
        }
    }

    // MARK: - Commands (registered from the page)

    func setCommands(pluginID: String, from raw: [[String: Any]]) {
        guard plugin(id: pluginID)?.enabled == true else { return }
        let mine: [PluginCommand] = raw.compactMap { c in
            guard let key = c["key"] as? String, let id = c["id"] as? String, key.hasPrefix(pluginID + ":") else { return nil }
            return PluginCommand(key: key, pluginID: pluginID, id: id, name: (c["name"] as? String) ?? id,
                                 defaultHotkey: c["defaultHotkey"] as? String)
        }
        var next = commands.filter { $0.pluginID != pluginID }
        next.append(contentsOf: mine)
        if next != commands { commands = next }
    }

    // MARK: - Serving plugin files

    struct ServedFile { var url: URL; var isMain: Bool }

    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp"]

    /// `plugins/<id>/<file>` for the scheme handler. Only an ENABLED, valid plugin's own main script,
    /// stylesheet and images are served: nothing else in the folder, and never anything outside it.
    func servedFile(forPath path: String) -> ServedFile? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "plugins",
              let p = enabledPlugins.first(where: { $0.id == parts[1] }), let m = p.manifest else { return nil }
        let name = parts[2]
        guard PluginManifest.isPlainFileName(name) else { return nil }
        let ext = (name as NSString).pathExtension.lowercased()
        guard name == m.main || name == m.styles || PluginManager.imageExts.contains(ext) else { return nil }
        // Resolve symlinks BEFORE the containment check: a file in the plugin folder that is really a link to
        // ~/.ssh/id_rsa must not be servable just because its name is inside the folder.
        let url = p.folder.appendingPathComponent(name).resolvingSymlinksInPath()
        guard url.path.hasPrefix(p.folder.resolvingSymlinksInPath().path + "/"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return ServedFile(url: url, isMain: name == m.main)
    }

    /// The plugin's main script, wrapped so it can only get its facade from a one-shot boot function.
    /// Keep in step with scripts/dev-server.mjs.
    static func wrap(_ code: String) -> String {
        "(function(){var PinTack=window.__pintackBoot&&window.__pintackBoot();if(!PinTack){return;}"
            + "var module={exports:{}};var exports=module.exports;try{\n" + code
            + "\n}catch(e){PinTack.__fail(e);return;}PinTack.__done(module.exports);})();"
    }

    // MARK: - Per-plugin private data

    var dataFolder: URL { vault.metaURL.appendingPathComponent("plugin-data", isDirectory: true) }

    func dataURL(for id: String) -> URL { dataFolder.appendingPathComponent("\(id).json") }
}
