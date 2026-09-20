import Foundation
import AppKit

extension Notification.Name {
    /// A plugin saved one of its settings. userInfo: ["id": plugin id].
    static let pluginSettingsDidChange = Notification.Name("PinTack.pluginSettingsDidChange")
}

struct HostError: Error {
    var code: String
    var message: String
}

/// Everything a plugin can ask Swift to do, and what it must have declared to ask. SPEC.md §12.4.
enum HostMethod: String {
    case vaultRead = "vault.read", vaultModify = "vault.modify", vaultCreate = "vault.create"
    case vaultGetNotes = "vault.getNotes", vaultAttachmentPath = "vault.getAttachmentPath"
    case storageLoad = "storage.load", storageSave = "storage.save", settingsSet = "settings.set"
    case processExecute = "process.execute", processStop = "process.stop", processInfo = "process.info"
    case trustStatus = "trust.status", shortcutsRun = "shortcuts.run"
    case urlOpen = "url.open", pathReveal = "path.reveal"

    /// Any ONE of these permissions is enough. An empty list means every plugin may call it (it only
    /// touches the plugin's own private data).
    var requiredAny: [PluginPermission] {
        switch self {
        case .vaultRead, .vaultGetNotes, .vaultAttachmentPath: return [.vaultRead]
        case .vaultModify, .vaultCreate:                        return [.vaultWrite]
        case .storageLoad, .storageSave, .settingsSet:          return []
        case .processExecute, .processStop, .processInfo:      return [.processExecute]
        case .trustStatus:                                      return [.processExecute, .shortcutsRun]
        case .shortcutsRun:                                     return [.shortcutsRun]
        case .urlOpen:                                          return [.urlOpen]
        case .pathReveal:                                       return [.pathReveal]
        }
    }
}

/// The single door between plugin JavaScript and everything privileged. SPEC.md §12.4, §13.
///
/// Order of checks on EVERY call, none skippable:
///   1. the capability token maps to an enabled, valid plugin, issued for THIS web view;
///   2. the plugin declared the permission the method needs (and the user enabled the plugin);
///   3. for anything that runs a command: the exact command has been approved by a person, through a
///      native sheet that no plugin can answer.
final class PluginBridge {

    static let shared = PluginBridge(manager: .shared, trust: .shared)

    /// Where a message came from, and how to answer it.
    struct Sender {
        weak var owner: AnyObject?
        var noteID: String?
        var send: (_ type: String, _ payload: [String: Any]) -> Void
    }

    private struct Run {
        var handle: ProcessRunner.Handle
        var pluginID: String
        var owner: ObjectIdentifier?
    }

    let manager: PluginManager
    let trust: TrustStore
    /// Answers "may this run?". Replaced by a fake in tests; in the app it is always the native sheet.
    var presenter: ApprovalPresenter = NativeApprovalPresenter()
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var revealURL: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// Called after a plugin changed a note's text, so an open window can refresh.
    var noteBodyChanged: (Note) -> Void = { note in WindowManager.shared.noteChangedByPlugin(note) }

    private var runs: [String: Run] = [:]
    private let runner = ProcessRunner()
    private static let maxRunsPerPlugin = 8

    init(manager: PluginManager, trust: TrustStore) {
        self.manager = manager
        self.trust = trust
    }

    // MARK: - Entry point

    func handle(_ payload: [String: Any], from sender: Sender) {
        guard let callId = payload["callId"] as? String else { return }

        func fail(_ code: String, _ message: String) {
            sender.send("plugin.result", ["callId": callId, "ok": false, "error": ["code": code, "message": message]])
        }
        func succeed(_ value: Any) {
            sender.send("plugin.result", ["callId": callId, "ok": true, "value": value])
        }

        guard let owner = sender.owner, let token = payload["token"] as? String,
              let pluginID = manager.pluginID(forToken: token, owner: owner),
              let plugin = manager.plugin(id: pluginID), plugin.enabled, plugin.isValid else {
            return fail("bad_token", "This plugin is not active.")
        }
        guard let name = payload["method"] as? String, let method = HostMethod(rawValue: name) else {
            return fail("unknown_method", "Unknown host method.")
        }
        let needed = method.requiredAny
        if !needed.isEmpty && !needed.contains(where: { plugin.permissions.contains($0) }) {
            return fail("permission_denied", "The “\(plugin.name)” plugin did not declare the permission “\(needed[0].rawValue)”.")
        }

        let args = payload["args"] as? [String: Any] ?? [:]
        do {
            try dispatch(method, args, plugin: plugin, sender: sender, callId: callId, succeed: succeed)
        } catch let e as HostError {
            fail(e.code, e.message)
        } catch {
            fail("error", error.localizedDescription)
        }
    }

    // MARK: - Methods

    private func dispatch(_ method: HostMethod, _ args: [String: Any], plugin: InstalledPlugin, sender: Sender,
                          callId: String, succeed: @escaping (Any) -> Void) throws {
        let vault = manager.vault
        func string(_ k: String) throws -> String {
            guard let s = args[k] as? String else { throw HostError(code: "bad_args", message: "Missing “\(k)”.") }
            return s
        }

        switch method {

        // ---- vault
        case .vaultRead:
            succeed(try note(try string("noteId"), vault).body)

        case .vaultModify:
            let n = try note(try string("noteId"), vault)
            let content = try string("content")
            guard content.utf8.count <= 5_000_000 else { throw HostError(code: "too_large", message: "That note text is too large.") }
            n.body = content
            vault.save(n)
            noteBodyChanged(n)
            succeed(true)

        case .vaultCreate:
            let raw = try string("path")
            let parts = raw.split(separator: "/").map { VaultStore.sanitizeFolderName(String($0)) }.filter { !$0.isEmpty }
            let folder = parts.dropLast().joined(separator: "/")
            if let first = parts.first, ["attachments", "plugins"].contains(first.lowercased()), parts.count > 1 {
                throw HostError(code: "reserved", message: "That folder is reserved.")
            }
            let n = vault.createNote(body: (args["content"] as? String) ?? "", folder: folder.isEmpty ? nil : folder)
            n.visible = false                      // a plugin must not throw new windows onto the desktop
            vault.save(n)
            succeed(["id": n.id, "path": relativePath(of: n, vault)])

        case .vaultGetNotes:
            let folder = args["folder"] as? String
            let tags = (args["tags"] as? [String]) ?? []
            let iso = ISO8601DateFormatter()
            let list = vault.notes
                .filter { folder == nil || vault.folder(of: $0) == folder }
                .filter { n in tags.allSatisfy { vault.matches(tag: $0, note: n) } }
                .map { n -> [String: Any] in
                    ["id": n.id, "title": n.title, "path": relativePath(of: n, vault), "folder": vault.folder(of: n),
                     "tags": n.tags, "visible": n.visible, "modified": iso.string(from: n.modified)]
                }
            succeed(list)

        case .vaultAttachmentPath:
            let name = ((try string("filename")) as NSString).lastPathComponent
            guard PluginManifest.isPlainFileName(name) else { throw HostError(code: "bad_args", message: "That is not a plain file name.") }
            succeed("attachments/\(name)")

        // ---- a plugin's own data and settings
        case .storageLoad:
            guard let data = try? Data(contentsOf: manager.dataURL(for: plugin.id)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return succeed(NSNull()) }
            succeed(obj["data"] ?? NSNull())

        case .storageSave:
            let value = args["data"] ?? NSNull()
            guard JSONSerialization.isValidJSONObject(["data": value]),
                  let bytes = try? JSONSerialization.data(withJSONObject: ["data": value]), bytes.count <= 1_000_000 else {
                throw HostError(code: "bad_args", message: "That data cannot be stored (it must be JSON, under 1 MB).")
            }
            try? FileManager.default.createDirectory(at: manager.dataFolder, withIntermediateDirectories: true)
            try AtomicWriter.write(bytes, to: manager.dataURL(for: plugin.id))
            succeed(true)

        case .settingsSet:
            let key = try string("key")
            guard let spec = plugin.manifest?.settings?.first(where: { $0.key == key }),
                  let value = PluginManager.coerce(args["value"], to: spec) else {
                throw HostError(code: "bad_args", message: "“\(key)” is not one of this plugin's settings, or the value has the wrong type.")
            }
            manager.settings.setPluginSetting(plugin.id, key: key, value: value)
            NotificationCenter.default.post(name: .pluginSettingsDidChange, object: nil, userInfo: ["id": plugin.id])
            succeed(true)

        // ---- running things
        case .processInfo:
            succeed(["shell": ProcessRunner.resolveShell(override: nil) ?? "/bin/zsh", "home": NSHomeDirectory()])

        case .trustStatus:
            if let shortcut = args["shortcut"] as? String {
                try TrustKey.validate(shortcut)
                succeed(["trusted": trust.isTrusted(TrustKey(kind: .shortcut, value: shortcut, cwd: ""))])
            } else {
                let command = try string("command")
                try TrustKey.validate(command)
                let cwd = ProcessRunner.resolveDirectory((args["cwd"] as? String) ?? "")?.path ?? ((args["cwd"] as? String) ?? "")
                succeed(["trusted": trust.isTrusted(TrustKey(kind: .command, value: command, cwd: cwd))])
            }

        case .processExecute:
            let command = try string("command")
            try TrustKey.validate(command)
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HostError(code: "bad_args", message: "There is no command to run.") }
            guard let cwd = ProcessRunner.resolveDirectory((args["cwd"] as? String) ?? "") else {
                throw HostError(code: "bad_cwd", message: "The working folder does not exist.")
            }
            guard let shell = ProcessRunner.resolveShell(override: args["shell"] as? String) else {
                throw HostError(code: "bad_shell", message: "The shell override is not an executable file.")
            }
            let key = TrustKey(kind: .command, value: command, cwd: cwd.path)
            try authorise(key, plugin: plugin, sender: sender, shell: shell)
            try launch(executable: shell, arguments: ["-lc", command], cwd: cwd, args: args, plugin: plugin,
                       sender: sender, callId: callId, succeed: succeed)

        case .shortcutsRun:
            let name = try string("shortcut")
            try TrustKey.validate(name, limit: 512)
            guard !name.isEmpty, FileManager.default.isExecutableFile(atPath: "/usr/bin/shortcuts") else {
                throw HostError(code: "unavailable", message: "The Shortcuts command is not available.")
            }
            let key = TrustKey(kind: .shortcut, value: name, cwd: "")
            try authorise(key, plugin: plugin, sender: sender, shell: "/usr/bin/shortcuts")
            try launch(executable: "/usr/bin/shortcuts", arguments: ["run", name],
                       cwd: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), args: args, plugin: plugin,
                       sender: sender, callId: callId, succeed: succeed)

        case .processStop:
            let id = try string("callId")
            guard let run = runs[id], run.pluginID == plugin.id else { throw HostError(code: "not_found", message: "That run is not active.") }
            run.handle.stop()
            succeed(true)

        // ---- opening things
        case .urlOpen:
            guard let url = URL(string: try string("url")), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else {
                throw HostError(code: "bad_args", message: "Only http, https and mailto links can be opened.")
            }
            openURL(url)
            succeed(true)

        case .pathReveal:
            let raw = try string("path")
            var path = (raw as NSString).expandingTildeInPath
            if !path.hasPrefix("/") {
                let base = ProcessRunner.resolveDirectory((args["cwd"] as? String) ?? "") ?? URL(fileURLWithPath: NSHomeDirectory())
                path = base.appendingPathComponent(path).path
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { throw HostError(code: "not_found", message: "That path does not exist.") }
            revealURL(url)
            succeed(true)
        }
    }

    // MARK: - Approval and launch

    /// Trusted already, or a PERSON says yes right now. There is no other way through.
    private func authorise(_ key: TrustKey, plugin: InstalledPlugin, sender: Sender, shell: String) throws {
        if trust.isTrusted(key) { return }
        let title = sender.noteID.flatMap { manager.vault.note(id: $0)?.title }
        let request = ApprovalRequest(pluginName: plugin.name, noteTitle: title, kind: key.kind, text: key.value,
                                      cwd: key.cwd, shell: shell)
        guard presenter.approve(request) else { throw HostError(code: "denied", message: "The command was not approved.") }
        trust.approve(key)
    }

    private func launch(executable: String, arguments: [String], cwd: URL, args: [String: Any], plugin: InstalledPlugin,
                        sender: Sender, callId: String, succeed: @escaping (Any) -> Void) throws {
        guard runs.values.filter({ $0.pluginID == plugin.id }).count < PluginBridge.maxRunsPerPlugin else {
            throw HostError(code: "busy", message: "Too many commands are running at once.")
        }
        let timeout = min(3600, max(1, (args["timeout"] as? NSNumber)?.doubleValue ?? 30))
        let handle = runner.start(
            executable: executable, arguments: arguments, cwd: cwd, timeout: timeout,
            onOutput: { kind, text in
                sender.send("plugin.progress", ["callId": callId, "data": ["stream": kind.rawValue, "text": text]])
            },
            completion: { [weak self] result in
                self?.runs.removeValue(forKey: callId)
                succeed(["exitCode": Int(result.exitCode), "elapsedMs": Int(result.elapsed * 1000),
                         "timedOut": result.timedOut, "stopped": result.stopped, "truncated": result.truncated])
            })
        runs[callId] = Run(handle: handle, pluginID: plugin.id, owner: sender.owner.map { ObjectIdentifier($0) })
    }

    // MARK: - Cleanup

    /// A note's window closed: its commands must not outlive it.
    func cancelRuns(owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        for (_, run) in runs where run.owner == id { run.handle.stop() }
    }

    /// A plugin was switched off.
    func cancelRuns(pluginID: String) {
        for (_, run) in runs where run.pluginID == pluginID { run.handle.stop() }
    }

    var activeRunCount: Int { runs.count }

    // MARK: - Helpers

    private func note(_ id: String, _ vault: VaultStore) throws -> Note {
        guard let n = vault.note(id: id) else { throw HostError(code: "not_found", message: "There is no such note.") }
        return n
    }

    private func relativePath(of note: Note, _ vault: VaultStore) -> String {
        let root = vault.vaultURL.standardizedFileURL.path
        return String(note.fileURL.standardizedFileURL.path.dropFirst(root.count + 1))
    }
}
