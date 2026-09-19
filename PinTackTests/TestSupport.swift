import XCTest
@testable import PinTack

/// A throwaway vault in a unique temp folder, deleted after each test.
class VaultTestCase: XCTestCase {

    var root: URL!
    var store: VaultStore!

    override func setUpWithError() throws {
        // resolvingSymlinksInPath: /var is a symlink to /private/var, and the store
        // compares standardized paths.
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pintack-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
        store = VaultStore(root: root)
        store.bootstrap(watch: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a raw note file into the vault and returns its URL.
    @discardableResult
    func writeFile(_ name: String, _ text: String, in folder: String? = nil) throws -> URL {
        var dir = root!
        if let folder { dir.appendPathComponent(folder, isDirectory: true) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
}
