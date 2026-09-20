import Foundation

/// What a plugin may ask the host to do. Declared in its manifest, shown to the user when they
/// enable the plugin, and enforced by Swift on every call. SPEC.md §12.2.
enum PluginPermission: String, CaseIterable, Codable {
    case processExecute = "process.execute"
    case shortcutsRun   = "shortcuts.run"
    case urlOpen        = "url.open"
    case pathReveal     = "path.reveal"
    case vaultRead      = "vault.read"
    case vaultWrite     = "vault.write"

    /// Plain-language description, shown in the enable prompt and the Plugins pane.
    var summary: String {
        switch self {
        case .processExecute: return "Run commands on your Mac (each new command asks you first)"
        case .shortcutsRun:   return "Run macOS Shortcuts (each new one asks you first)"
        case .urlOpen:        return "Open web links in your browser"
        case .pathReveal:     return "Reveal files in Finder"
        case .vaultRead:      return "Read your notes"
        case .vaultWrite:     return "Change and create notes"
        }
    }
}

/// A scalar setting value: the manifest schema allows numbers, strings and booleans.
enum JSONScalar: Codable, Equatable {
    case string(String), number(Double), bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b):   try c.encode(b)
        }
    }

    var any: Any {
        switch self { case .string(let s): return s; case .number(let n): return n; case .bool(let b): return b }
    }
}

struct PluginSettingSpec: Codable, Equatable {
    var key: String
    var type: String            // number | string | boolean
    var label: String
    var defaultValue: JSONScalar

    enum CodingKeys: String, CodingKey { case key, type, label, defaultValue = "default" }
}

/// `<vault>/plugins/<id>/manifest.json`. SPEC.md §12.2.
struct PluginManifest: Codable, Equatable {
    var id: String
    var name: String
    var version: String
    var description: String?
    var author: String?
    var minAppVersion: String?
    var main: String
    var styles: String?
    var permissions: [String]?
    var settings: [PluginSettingSpec]?

    enum ValidationError: LocalizedError, Equatable {
        case badID(String), folderMismatch(id: String, folder: String), reservedID(String)
        case badFileName(String), missingFile(String)
        case unknownPermission(String)
        case needsNewerApp(String)
        case badSetting(String)

        var errorDescription: String? {
            switch self {
            case .badID(let id): return "“\(id)” is not a valid plugin id (lowercase letters, digits and hyphens, 2–40 characters)."
            case .folderMismatch(let id, let f): return "The manifest id “\(id)” does not match its folder name “\(f)”."
            case .reservedID(let id): return "“\(id)” is reserved and cannot be a plugin id."
            case .badFileName(let f): return "“\(f)” must be a plain file name inside the plugin folder."
            case .missingFile(let f): return "The plugin folder has no “\(f)”."
            case .unknownPermission(let p): return "It asks for an unknown permission, “\(p)”."
            case .needsNewerApp(let v): return "It needs PinTack \(v) or newer."
            case .badSetting(let k): return "Its setting “\(k)” is not valid."
            }
        }
    }

    var declaredPermissions: [PluginPermission] { (permissions ?? []).compactMap(PluginPermission.init(rawValue:)) }

    /// Everything that could let a plugin reach outside its own folder or another plugin's data is
    /// checked here, because a manifest is untrusted input (anyone can hand you a plugin folder).
    func validate(folderName: String, folder: URL, appVersion: String, reserved: Set<String>) throws {
        guard id.range(of: #"^[a-z0-9][a-z0-9-]{1,39}$"#, options: .regularExpression) != nil else { throw ValidationError.badID(id) }
        guard id == folderName else { throw ValidationError.folderMismatch(id: id, folder: folderName) }
        // A plugin's saved settings live in settings.json under its id, so its id must never collide
        // with one of the app's own keys.
        guard !reserved.contains(id) else { throw ValidationError.reservedID(id) }

        for file in [main] + (styles.map { [$0] } ?? []) {
            guard PluginManifest.isPlainFileName(file) else { throw ValidationError.badFileName(file) }
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) else { throw ValidationError.missingFile(file) }
        }
        guard main.hasSuffix(".js") else { throw ValidationError.badFileName(main) }
        if let styles, !styles.hasSuffix(".css") { throw ValidationError.badFileName(styles) }

        for p in permissions ?? [] where PluginPermission(rawValue: p) == nil { throw ValidationError.unknownPermission(p) }

        if let min = minAppVersion, PluginManifest.compare(appVersion, min) == .orderedAscending { throw ValidationError.needsNewerApp(min) }

        for s in settings ?? [] {
            guard s.key.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,40}$"#, options: .regularExpression) != nil,
                  ["number", "string", "boolean"].contains(s.type) else { throw ValidationError.badSetting(s.key) }
        }
    }

    static func isPlainFileName(_ s: String) -> Bool {
        !s.isEmpty && !s.contains("/") && !s.contains("\\") && !s.hasPrefix(".") && !s.contains("\0")
    }

    /// Dotted-number comparison: "0.10.0" > "0.9.0".
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// The manifest as a JSON dictionary for the page.
    var jsonObject: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}
