import XCTest
@testable import PinTack

/// A stand-in for the native approval sheet. A plugin cannot reach this (or the real one).
final class FakePresenter: ApprovalPresenter {
    var answer = false
    private(set) var requests: [ApprovalRequest] = []
    func approve(_ request: ApprovalRequest) -> Bool { requests.append(request); return answer }
}

/// Builds a temp vault with plugins, a manager, a trust store and a bridge wired to fakes.
class PluginTestCase: VaultTestCase {

    var settings: AppSettings!
    var manager: PluginManager!
    var trust: TrustStore!
    var bridge: PluginBridge!
    var presenter: FakePresenter!
    let owner = NSObject()
    var sent: [(type: String, payload: [String: Any])] = []
    var opened: [URL] = [], revealed: [URL] = [], changedNotes: [String] = []
    var keyDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        keyDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pt-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)
        settings = AppSettings()
        settings.load(from: store.metaURL)
        manager = PluginManager(vault: store, settings: settings, bundled: nil)
        trust = TrustStore(fileURL: store.metaURL.appendingPathComponent("trust.json"), keyURL: keyDir.appendingPathComponent("trust.key"))
        presenter = FakePresenter()
        bridge = PluginBridge(manager: manager, trust: trust)
        bridge.presenter = presenter
        bridge.openURL = { [unowned self] in opened.append($0) }
        bridge.revealURL = { [unowned self] in revealed.append($0) }
        bridge.noteBodyChanged = { [unowned self] in changedNotes.append($0.id) }
    }

    override func tearDownWithError() throws {
        bridge.cancelRuns(owner: owner)
        try? FileManager.default.removeItem(at: keyDir)
        try super.tearDownWithError()
    }

    @discardableResult
    func install(_ id: String, permissions: [String], settingsSpec: String = "[]", enabled: Bool = true) throws -> InstalledPlugin {
        let dir = store.pluginsURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let perms = permissions.map { "\"\($0)\"" }.joined(separator: ",")
        try "{\"id\":\"\(id)\",\"name\":\"\(id.capitalized)\",\"version\":\"1.0.0\",\"main\":\"main.js\",\"permissions\":[\(perms)],\"settings\":\(settingsSpec)}"
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "module.exports = class {}".write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        settings.enabledPlugins[id] = enabled
        manager.reload()
        return try XCTUnwrap(manager.plugin(id: id))
    }

    func token(for id: String) throws -> String {
        let session = manager.makeSession(for: owner)
        return try XCTUnwrap(session.first { ($0["id"] as? String) == id }?["token"] as? String)
    }

    /// All tokens from ONE session. (Each new session invalidates the previous session's tokens, by design.)
    func allTokens() -> [String: String] {
        Dictionary(uniqueKeysWithValues: manager.makeSession(for: owner).compactMap { e -> (String, String)? in
            guard let id = e["id"] as? String, let t = e["token"] as? String else { return nil }
            return (id, t)
        })
    }

    var sender: PluginBridge.Sender {
        PluginBridge.Sender(owner: owner, noteID: nil, send: { [unowned self] t, p in sent.append((t, p)) })
    }

    /// Synchronous call for methods that answer immediately. Returns the plugin.result payload.
    @discardableResult
    func call(_ method: String, _ args: [String: Any] = [:], token: String, id: String = "c1") -> [String: Any] {
        sent.removeAll()
        bridge.handle(["callId": id, "token": token, "method": method, "args": args], from: sender)
        return sent.last(where: { $0.type == "plugin.result" })?.payload ?? [:]
    }

    func ok(_ r: [String: Any]) -> Bool { r["ok"] as? Bool == true }
    func code(_ r: [String: Any]) -> String? { (r["error"] as? [String: Any])?["code"] as? String }

    /// For process calls: waits for the plugin.result.
    func callAndWait(_ method: String, _ args: [String: Any], token: String, id: String = "run1", timeout: TimeInterval = 20) -> [String: Any] {
        sent.removeAll()
        bridge.handle(["callId": id, "token": token, "method": method, "args": args], from: sender)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = sent.last(where: { $0.type == "plugin.result" }) { return r.payload }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return [:]
    }

    func progressText(id: String = "run1") -> String {
        sent.filter { $0.type == "plugin.progress" && $0.payload["callId"] as? String == id }
            .compactMap { ($0.payload["data"] as? [String: Any])?["text"] as? String }.joined()
    }
}

// MARK: - Identity and permissions

final class PluginBridgeSecurityTests: PluginTestCase {

    func testACallWithoutAValidTokenIsRefused() throws {
        try install("demo", permissions: ["url.open"])
        _ = try token(for: "demo")
        XCTAssertEqual(code(call("url.open", ["url": "https://example.com"], token: "made-up")), "bad_token")
        XCTAssertTrue(opened.isEmpty)
    }

    func testATokenOnlyWorksForTheWebViewItWasIssuedTo() throws {
        try install("demo", permissions: ["url.open"])
        let t = try token(for: "demo")
        let other = NSObject()
        let stranger = PluginBridge.Sender(owner: other, noteID: nil, send: { [unowned self] t, p in sent.append((t, p)) })
        sent.removeAll()
        bridge.handle(["callId": "x", "token": t, "method": "url.open", "args": ["url": "https://example.com"]], from: stranger)
        XCTAssertEqual(code(sent.last?.payload ?? [:]), "bad_token", "a token stolen into another page must not work")
        XCTAssertTrue(opened.isEmpty)
    }

    func testTokensDieWhenTheSessionEndsOrThePluginIsSwitchedOff() throws {
        try install("demo", permissions: ["url.open"])
        let t = try token(for: "demo")
        XCTAssertTrue(ok(call("url.open", ["url": "https://a.example"], token: t)))
        manager.setEnabled("demo", false)
        XCTAssertEqual(code(call("url.open", ["url": "https://b.example"], token: t)), "bad_token")
        manager.setEnabled("demo", true)
        manager.endSession(for: owner)
        XCTAssertEqual(code(call("url.open", ["url": "https://c.example"], token: t)), "bad_token")
        XCTAssertEqual(opened.count, 1)
    }

    func testAPluginCannotBorrowAnotherPluginsPermissionsByClaimingItsId() throws {
        try install("harmless", permissions: ["url.open"])
        try install("powerful", permissions: ["process.execute"])
        let t = try token(for: "harmless")
        // The message says it is "powerful". Identity comes from the token, never from the message.
        let r = call("process.execute", ["command": "echo pwned", "pluginId": "powerful", "plugin": "powerful"], token: t)
        XCTAssertEqual(code(r), "permission_denied")
        XCTAssertTrue(presenter.requests.isEmpty, "the sheet must not even be shown for an undeclared permission")
    }

    func testUndeclaredPermissionsAreRefusedForEveryPrivilegedMethod() throws {
        try install("demo", permissions: ["url.open"])
        let t = try token(for: "demo")
        for (method, args) in [("vault.read", ["noteId": "x"]), ("vault.modify", ["noteId": "x", "content": ""]), ("vault.create", ["path": "a", "content": ""]),
                               ("vault.getNotes", [:]), ("vault.getAttachmentPath", ["filename": "a.png"]),
                               ("process.execute", ["command": "true"]), ("process.info", [:]), ("process.stop", ["callId": "x"]),
                               ("trust.status", ["command": "true"]), ("shortcuts.run", ["shortcut": "x"]), ("path.reveal", ["path": "/tmp"])] as [(String, [String: Any])] {
            XCTAssertEqual(code(call(method, args, token: t)), "permission_denied", method)
        }
        XCTAssertEqual(code(call("no.such.method", token: t)), "unknown_method")
    }

    func testAnInvalidOrDisabledPluginGetsNoToken() throws {
        try install("off", permissions: ["url.open"], enabled: false)
        XCTAssertNil(manager.makeSession(for: owner).first { ($0["id"] as? String) == "off" })
        let dir = store.pluginsURL.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{ not json".write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        settings.enabledPlugins["broken"] = true
        manager.reload()
        XCTAssertNotNil(manager.plugin(id: "broken")?.error)
        XCTAssertNil(manager.makeSession(for: owner).first { ($0["id"] as? String) == "broken" })
    }

    func testTokensAreLongUniqueAndRandom() throws {
        try install("a1", permissions: []); try install("b2", permissions: [])
        let tokens = manager.makeSession(for: owner).compactMap { $0["token"] as? String }
        XCTAssertEqual(Set(tokens).count, 2)
        XCTAssertTrue(tokens.allSatisfy { $0.count == 64 })
        XCTAssertNotEqual(manager.makeSession(for: owner).compactMap { $0["token"] as? String }, tokens, "a new session must issue new tokens")
    }
}

// MARK: - Command approval (the heart of Runner's trust model)

final class PluginBridgeExecutionTests: PluginTestCase {

    private var marker: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pt-marker-\(name.hashValue).txt") }
    private var t: String = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        try install("runner", permissions: ["process.execute", "shortcuts.run"])
        t = try token(for: "runner")
        try? FileManager.default.removeItem(at: marker)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: marker); try super.tearDownWithError() }

    func testAnUnapprovedCommandShowsTheExactTextAndDoesNothingIfDenied() throws {
        presenter.answer = false
        let cmd = "touch '\(marker.path)'"
        let r = call("process.execute", ["command": cmd], token: t)
        XCTAssertEqual(code(r), "denied")
        XCTAssertEqual(presenter.requests.count, 1)
        XCTAssertEqual(presenter.requests.first?.text, cmd, "the sheet shows the exact string, not a summary")
        XCTAssertEqual(presenter.requests.first?.pluginName, "Runner")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "denied means it must not have run")
        XCTAssertFalse(trust.isTrusted(TrustKey(kind: .command, value: cmd, cwd: NSHomeDirectory())), "denial must not be remembered as approval")
    }

    func testApprovingRunsItStreamsOutputAndIsRemembered() throws {
        presenter.answer = true
        let r = callAndWait("process.execute", ["command": "echo out; echo err 1>&2; exit 2"], token: t)
        XCTAssertTrue(ok(r))
        XCTAssertEqual((r["value"] as? [String: Any])?["exitCode"] as? Int, 2)
        XCTAssertEqual(progressText().split(separator: "\n").sorted(), ["err", "out"])
        XCTAssertEqual(presenter.requests.count, 1)

        presenter.answer = false                         // even if the person would now say no, it is already approved
        let again = callAndWait("process.execute", ["command": "echo out; echo err 1>&2; exit 2"], token: t, id: "run2")
        XCTAssertTrue(ok(again))
        XCTAssertEqual(presenter.requests.count, 1, "an approved command must not ask again")
    }

    func testChangingTheCommandOrTheFolderAsksAgain() throws {
        presenter.answer = true
        _ = callAndWait("process.execute", ["command": "echo one"], token: t)
        XCTAssertEqual(presenter.requests.count, 1)
        _ = callAndWait("process.execute", ["command": "echo one "], token: t, id: "r2")              // one extra space
        XCTAssertEqual(presenter.requests.count, 2, "editing a command resets its approval")
        _ = callAndWait("process.execute", ["command": "echo one", "cwd": "/tmp"], token: t, id: "r3")   // same text, other folder
        XCTAssertEqual(presenter.requests.count, 3, "the same command in another folder is a different program")
        _ = callAndWait("process.execute", ["command": "echo one", "cwd": "/tmp"], token: t, id: "r4")
        XCTAssertEqual(presenter.requests.count, 3)
    }

    func testNoArgumentCanSkipTheApproval() throws {
        presenter.answer = false
        for bypass: [String: Any] in [["trusted": true], ["approved": true], ["autorun": true], ["force": true], ["skipApproval": true],
                                      ["approve": true], ["yes": true], ["trust": ["ok": true]], ["shell": "/bin/sh", "trusted": 1]] {
            var args = bypass; args["command"] = "touch '\(marker.path)'"
            XCTAssertEqual(code(call("process.execute", args, token: t)), "denied", "\(bypass)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(presenter.requests.count, 9, "every attempt reached the person")
    }

    func testTrust_StatusReportsTheTruthAndCannotBeSetThroughIt() throws {
        XCTAssertEqual((call("trust.status", ["command": "echo hi"], token: t)["value"] as? [String: Any])?["trusted"] as? Bool, false)
        presenter.answer = true
        _ = callAndWait("process.execute", ["command": "echo hi"], token: t)
        XCTAssertEqual((call("trust.status", ["command": "echo hi"], token: t)["value"] as? [String: Any])?["trusted"] as? Bool, true)
        XCTAssertEqual((call("trust.status", ["command": "echo hi", "cwd": "/tmp"], token: t)["value"] as? [String: Any])?["trusted"] as? Bool, false)
        XCTAssertEqual((call("trust.status", ["command": "echo hi", "trusted": true, "approve": true], token: t)["value"] as? [String: Any])?["trusted"] as? Bool, true)
    }

    func testCommandsThatCouldHideTheirRealContentNeverReachTheSheet() throws {
        presenter.answer = true
        for bad in ["echo safe\u{1B}[2K; rm -rf ~", "echo a\0b", "echo \u{202E}gnp.sh", "echo a\u{200B}b"] {
            XCTAssertEqual(code(call("process.execute", ["command": bad], token: t)), "error", bad.debugDescription)
        }
        XCTAssertTrue(presenter.requests.isEmpty)
    }

    func testBadInputsAreErrorsNotCrashes() throws {
        presenter.answer = true
        XCTAssertEqual(code(call("process.execute", [:], token: t)), "bad_args")
        XCTAssertEqual(code(call("process.execute", ["command": "   "], token: t)), "bad_args")
        XCTAssertEqual(code(call("process.execute", ["command": 42], token: t)), "bad_args")
        XCTAssertEqual(code(call("process.execute", ["command": "true", "cwd": "/no/such/dir"], token: t)), "bad_cwd")
        XCTAssertEqual(code(call("process.execute", ["command": "true", "shell": "/no/such/shell"], token: t)), "bad_shell")
        XCTAssertTrue(presenter.requests.isEmpty, "nothing invalid may reach the sheet")
    }

    func testAShortcutNeedsItsOwnApprovalAndItsOwnPermission() throws {
        presenter.answer = false
        XCTAssertEqual(code(call("shortcuts.run", ["shortcut": "Backup"], token: t)), "denied")
        XCTAssertEqual(presenter.requests.first?.kind, .shortcut)
        XCTAssertEqual(presenter.requests.first?.text, "Backup")

        try install("cmdonly", permissions: ["process.execute"])
        let t2 = try token(for: "cmdonly")
        XCTAssertEqual(code(call("shortcuts.run", ["shortcut": "Backup"], token: t2)), "permission_denied")
    }

    func testStopEndsARunningCommandAndOnlyItsOwnerMayStopIt() throws {
        presenter.answer = true
        sent.removeAll()
        bridge.handle(["callId": "long", "token": t, "method": "process.execute", "args": ["command": "sleep 30", "timeout": 60]], from: sender)
        XCTAssertEqual(bridge.activeRunCount, 1)

        try install("other", permissions: ["process.execute"])
        let both = allTokens()                 // a new session: the old token is gone, so use this one
        let other = try XCTUnwrap(both["other"]); let t = try XCTUnwrap(both["runner"])
        bridge.cancelRuns(pluginID: "never-matches")
        XCTAssertEqual(code(call("process.stop", ["callId": "long"], token: other, id: "s1")), "not_found", "another plugin must not stop it")
        XCTAssertEqual(bridge.activeRunCount, 1)

        XCTAssertTrue(ok(call("process.stop", ["callId": "long"], token: t, id: "s2")))
        let deadline = Date().addingTimeInterval(6)
        while bridge.activeRunCount > 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(bridge.activeRunCount, 0)
        let result = sent.last { $0.type == "plugin.result" && $0.payload["callId"] as? String == "long" }?.payload["value"] as? [String: Any]
        XCTAssertEqual(result?["stopped"] as? Bool, true)
    }

    func testClosingANoteStopsItsCommands() throws {
        presenter.answer = true
        bridge.handle(["callId": "bg", "token": t, "method": "process.execute", "args": ["command": "sleep 30", "timeout": 60]], from: sender)
        XCTAssertEqual(bridge.activeRunCount, 1)
        bridge.cancelRuns(owner: owner)
        let deadline = Date().addingTimeInterval(6)
        while bridge.activeRunCount > 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(bridge.activeRunCount, 0, "a closed note must not leave processes behind")
    }

    func testTheTimeoutIsEnforcedAndClamped() throws {
        presenter.answer = true
        let r = callAndWait("process.execute", ["command": "sleep 30", "timeout": 1], token: t)
        XCTAssertEqual((r["value"] as? [String: Any])?["timedOut"] as? Bool, true)
    }
}

// MARK: - Everything else a plugin can ask for

final class PluginBridgeAPITests: PluginTestCase {

    func testVaultReadWriteCreateAndList() throws {
        try install("notes", permissions: ["vault.read", "vault.write"])
        let t = try token(for: "notes")
        let n = store.createNote(body: "# Original", folder: "Work"); n.tags = ["a"]; store.save(n)

        XCTAssertEqual(call("vault.read", ["noteId": n.id], token: t)["value"] as? String, "# Original")
        XCTAssertEqual(code(call("vault.read", ["noteId": "nope"], token: t)), "not_found")

        XCTAssertTrue(ok(call("vault.modify", ["noteId": n.id, "content": "# Changed"], token: t)))
        XCTAssertEqual(n.body, "# Changed")
        XCTAssertTrue(try String(contentsOf: n.fileURL, encoding: .utf8).contains("# Changed"), "written to disk, atomically")
        XCTAssertEqual(changedNotes, [n.id], "an open window is told to refresh")

        let created = call("vault.create", ["path": "Reports/Made/Report", "content": "hello"], token: t)["value"] as? [String: Any]
        let id = try XCTUnwrap(created?["id"] as? String)
        XCTAssertEqual(store.note(id: id)?.visible, false, "a plugin must not throw new windows onto the desktop")
        XCTAssertEqual(store.folder(of: try XCTUnwrap(store.note(id: id))), "Reports/Made")

        let listed = try XCTUnwrap(call("vault.getNotes", ["folder": "Work"], token: t)["value"] as? [[String: Any]])
        XCTAssertEqual(listed.map { $0["id"] as? String }, [n.id])
        let byTag = try XCTUnwrap(call("vault.getNotes", ["tags": ["a"]], token: t)["value"] as? [[String: Any]])
        XCTAssertEqual(byTag.count, 1)
    }

    func testAPluginCannotWriteOutsideTheVaultOrIntoReservedFolders() throws {
        try install("notes", permissions: ["vault.write", "vault.read"])
        let t = try token(for: "notes")
        _ = call("vault.create", ["path": "../../escape/evil", "content": "x"], token: t)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("escape").path))
        XCTAssertEqual(code(call("vault.create", ["path": "plugins/hack/x", "content": "x"], token: t)), "reserved")
        XCTAssertEqual(code(call("vault.create", ["path": "attachments/x", "content": "x"], token: t)), "reserved")
        XCTAssertEqual(call("vault.getAttachmentPath", ["filename": "../../etc/passwd"], token: t)["value"] as? String, "attachments/passwd")
        XCTAssertEqual(code(call("vault.getAttachmentPath", ["filename": ".."], token: t)), "bad_args")
    }

    func testStorageIsPrivatePerPluginAndBounded() throws {
        try install("one", permissions: []); try install("two", permissions: [])
        let tk = allTokens()
        let (a, b) = (try XCTUnwrap(tk["one"]), try XCTUnwrap(tk["two"]))
        XCTAssertTrue(call("storage.load", token: a)["value"] is NSNull)
        XCTAssertTrue(ok(call("storage.save", ["data": ["heights": ["n1": 200], "list": [1, 2, 3]]], token: a)))
        let loaded = try XCTUnwrap(call("storage.load", token: a)["value"] as? [String: Any])
        XCTAssertEqual((loaded["list"] as? [Int]), [1, 2, 3])
        XCTAssertTrue(call("storage.load", token: b)["value"] is NSNull, "one plugin must never see another's data")
        XCTAssertEqual(code(call("storage.save", ["data": String(repeating: "x", count: 1_100_000)], token: a)), "bad_args")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.dataURL(for: "one").path))
    }

    func testPluginSettingsAreTypeCheckedAndKeepTheirOwnNamespace() throws {
        try install("cfg", permissions: [], settingsSpec: "[{\"key\":\"timeout\",\"type\":\"number\",\"default\":30,\"label\":\"T\"},{\"key\":\"shell\",\"type\":\"string\",\"default\":\"\",\"label\":\"S\"},{\"key\":\"on\",\"type\":\"boolean\",\"default\":true,\"label\":\"O\"}]")
        let t = try token(for: "cfg")
        let plugin = try XCTUnwrap(manager.plugin(id: "cfg"))
        XCTAssertEqual(manager.settingsValues(for: plugin)["timeout"] as? Double, 30)

        XCTAssertTrue(ok(call("settings.set", ["key": "timeout", "value": 45], token: t)))
        XCTAssertEqual(manager.settingsValues(for: plugin)["timeout"] as? Double, 45)
        XCTAssertEqual(code(call("settings.set", ["key": "timeout", "value": "soon"], token: t)), "bad_args", "wrong type")
        XCTAssertEqual(code(call("settings.set", ["key": "nope", "value": 1], token: t)), "bad_args", "not in the manifest")
        XCTAssertEqual(code(call("settings.set", ["key": "on", "value": 1], token: t)), "bad_args", "a number is not a boolean")

        // Stored under the plugin's id, beside (not over) the app's own settings.
        settings.save()
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.metaURL.appendingPathComponent("settings.json"))) as? [String: Any])
        XCTAssertEqual((saved["cfg"] as? [String: Any])?["timeout"] as? Double, 45)
        XCTAssertNotNil(saved["fontFamily"]); XCTAssertNotNil(saved["enabledPlugins"])
    }

    func testOnlyWebAndMailLinksOpenAndPathsMustExist() throws {
        try install("open", permissions: ["url.open", "path.reveal"])
        let t = try token(for: "open")
        XCTAssertTrue(ok(call("url.open", ["url": "https://example.com/a"], token: t)))
        XCTAssertTrue(ok(call("url.open", ["url": "mailto:a@b.co"], token: t)))
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "ssh://host", "x-apple.systempreferences:", "/etc/hosts", "data:text/html,hi"] {
            XCTAssertEqual(code(call("url.open", ["url": bad], token: t)), "bad_args", bad)
        }
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/a", "mailto:a@b.co"])

        XCTAssertTrue(ok(call("path.reveal", ["path": "/etc/hosts"], token: t)))
        XCTAssertEqual(revealed.last?.path, "/etc/hosts")
        XCTAssertEqual(code(call("path.reveal", ["path": "/no/such/thing"], token: t)), "not_found")
        XCTAssertTrue(ok(call("path.reveal", ["path": "~"], token: t)))
    }

    func testProcessInfoReportsTheLoginShell() throws {
        try install("run", permissions: ["process.execute"])
        let info = try XCTUnwrap(call("process.info", token: try token(for: "run"))["value"] as? [String: Any])
        XCTAssertTrue((info["shell"] as? String)?.hasPrefix("/") == true)
        XCTAssertEqual(info["home"] as? String, NSHomeDirectory())
    }
}

// MARK: - Plugin manager

final class PluginManagerTests: PluginTestCase {

    private func bundled(version: String, marker: String = "v") throws -> URL {
        let b = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pt-bundled-\(UUID().uuidString)", isDirectory: true)
        let dir = b.appendingPathComponent("runner", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{\"id\":\"runner\",\"name\":\"Runner\",\"version\":\"\(version)\",\"main\":\"main.js\",\"permissions\":[]}".write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "// \(marker)".write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        return b
    }

    func testTheBundledPluginInstallsEnabledOnceAndNeverOverridesTheUsersChoice() throws {
        let src = try bundled(version: "1.0.0")
        defer { try? FileManager.default.removeItem(at: src) }
        let m = PluginManager(vault: store, settings: settings, bundled: src)
        m.installBundledPlugins(); m.reload()
        XCTAssertEqual(m.plugin(id: "runner")?.enabled, true, "Runner ships enabled")

        m.setEnabled("runner", false)
        let again = PluginManager(vault: store, settings: settings, bundled: src)
        again.installBundledPlugins(); again.reload()
        XCTAssertEqual(again.plugin(id: "runner")?.enabled, false, "a plugin the user switched off stays off")
    }

    func testANewerBundledVersionReplacesTheInstalledOneButAnOlderOneDoesNot() throws {
        let v1 = try bundled(version: "1.0.0", marker: "one"), v2 = try bundled(version: "1.1.0", marker: "two"), v0 = try bundled(version: "0.9.0", marker: "zero")
        defer { [v1, v2, v0].forEach { try? FileManager.default.removeItem(at: $0) } }
        let main = store.pluginsURL.appendingPathComponent("runner/main.js")
        PluginManager(vault: store, settings: settings, bundled: v1).installBundledPlugins()
        XCTAssertEqual(try String(contentsOf: main), "// one")
        PluginManager(vault: store, settings: settings, bundled: v0).installBundledPlugins()
        XCTAssertEqual(try String(contentsOf: main), "// one", "never downgrade")
        PluginManager(vault: store, settings: settings, bundled: v2).installBundledPlugins()
        XCTAssertEqual(try String(contentsOf: main), "// two")
    }

    func testInvalidPluginsAreListedWithAReasonAndStayOff() throws {
        let dir = store.pluginsURL.appendingPathComponent("evil", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{\"id\":\"evil\",\"name\":\"Evil\",\"version\":\"1\",\"main\":\"../../../etc/passwd\"}".write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        settings.enabledPlugins["evil"] = true
        manager.reload()
        let p = try XCTUnwrap(manager.plugin(id: "evil"))
        XCTAssertFalse(p.isValid); XCTAssertNotNil(p.error); XCTAssertFalse(p.enabled)
        XCTAssertTrue(manager.enabledPlugins.isEmpty)
    }

    func testOnlyAnEnabledPluginsOwnAllowedFilesAreServed() throws {
        try install("srv", permissions: [])
        let dir = store.pluginsURL.appendingPathComponent("srv", isDirectory: true)
        try "{\"secret\":1}".write(to: dir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
        try Data([1]).write(to: dir.appendingPathComponent("logo.png"))
        XCTAssertEqual(manager.servedFile(forPath: "plugins/srv/main.js")?.isMain, true)
        XCTAssertNotNil(manager.servedFile(forPath: "plugins/srv/logo.png"))
        XCTAssertNil(manager.servedFile(forPath: "plugins/srv/manifest.json"), "not a served file type")
        XCTAssertNil(manager.servedFile(forPath: "plugins/srv/data.json"))
        XCTAssertNil(manager.servedFile(forPath: "plugins/srv/../../.pintack/trust.json"))
        XCTAssertNil(manager.servedFile(forPath: "plugins/srv/sub/main.js"))
        XCTAssertNil(manager.servedFile(forPath: "plugins/nosuch/main.js"))
        manager.setEnabled("srv", false)
        XCTAssertNil(manager.servedFile(forPath: "plugins/srv/main.js"), "a disabled plugin's code must not load")
    }

    func testASymlinkInsideAPluginCannotLeakAFileFromOutside() throws {
        try install("lnk", permissions: [])
        let secret = root.appendingPathComponent("secret.png")
        try Data([9, 9, 9]).write(to: secret)
        let link = store.pluginsURL.appendingPathComponent("lnk/logo.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        XCTAssertNil(manager.servedFile(forPath: "plugins/lnk/logo.png"), "a link out of the plugin folder must not be served")
    }

    func testTheWrapperGivesThePluginOnlyAOneShotBootFunction() {
        let w = PluginManager.wrap("module.exports = 1;")
        XCTAssertTrue(w.contains("window.__pintackBoot&&window.__pintackBoot()"))
        XCTAssertTrue(w.contains("module.exports = 1;"))
        XCTAssertTrue(w.contains("PinTack.__done(module.exports)"))
        XCTAssertTrue(w.contains("PinTack.__fail(e)"), "a plugin that throws must not break the page")
    }

    func testCommandsAreAcceptedOnlyFromEnabledPluginsUnderTheirOwnPrefix() throws {
        try install("cmd", permissions: [])
        manager.setCommands(pluginID: "cmd", from: [["key": "cmd:go", "id": "go", "name": "Go"], ["key": "other:steal", "id": "steal", "name": "Steal"]])
        XCTAssertEqual(manager.commands.map(\.key), ["cmd:go"])
        manager.setEnabled("cmd", false)
        XCTAssertTrue(manager.commands.isEmpty)
        manager.setCommands(pluginID: "cmd", from: [["key": "cmd:go", "id": "go"]])
        XCTAssertTrue(manager.commands.isEmpty, "a disabled plugin registers nothing")
    }
}
