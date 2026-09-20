import Foundation
import CryptoKit

/// What a command approval is bound to. SPEC.md §13.4.
///
/// The spec binds trust to the exact command string. This ALSO binds it to the working folder: the
/// same `./run.sh` in a different folder is a different program, so approving one must not approve the
/// other. Anything that changes what would actually execute resets the approval.
struct TrustKey: Equatable {
    enum Kind: String { case command = "run", shortcut = "shortcut" }
    var kind: Kind
    var value: String       // the command line, or the Shortcut's name
    var cwd: String

    var hash: String {
        SHA256.hash(data: Data("\(kind.rawValue)\0\(cwd)\0\(value)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    enum Unsafe: LocalizedError {
        case tooLong, hiddenCharacters
        var errorDescription: String? {
            switch self {
            case .tooLong: return "That command is too long to review safely."
            case .hiddenCharacters: return "That text contains control or direction-changing characters that could hide part of it in the approval window."
            }
        }
    }

    /// The approval window must show EXACTLY what will run. Text that can render differently from how it
    /// executes (escape sequences, NUL, right-to-left overrides) is refused rather than shown.
    static func validate(_ text: String, limit: Int = 16_384) throws {
        if text.utf8.count > limit { throw Unsafe.tooLong }
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let isControl = v < 0x20 && v != 0x0A && v != 0x09 && v != 0x0D
            let isBidi = (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
            let isOther = v == 0x7F || (0x80...0x9F).contains(v) || v == 0x200B || v == 0x2028 || v == 0x2029 || v == 0xFEFF
            if isControl || isBidi || isOther { throw Unsafe.hiddenCharacters }
        }
    }
}

/// Remembered approvals: `<vault>/.pintack/trust.json`. Trust belongs to a person on a Mac, not to a
/// note, so importing or pasting a note never brings approvals with it.
///
/// Each entry carries an HMAC made with a secret that lives OUTSIDE the vault
/// (~/Library/Application Support/PinTack/trust.key). The vault is what people sync and share, so a
/// trust file arriving from elsewhere (a shared folder, a synced machine) must not be able to
/// pre-approve commands here. Entries without a valid HMAC are ignored.
final class TrustStore {

    struct Entry: Equatable {
        var hash: String
        var kind: String
        var value: String
        var cwd: String
        var approvedAt: Date
    }

    private let fileURL: URL
    private let keyURL: URL
    private var key: SymmetricKey?
    private var entries: [String: (entry: Entry, mac: String)] = [:]

    static let shared: TrustStore = TrustStore(
        fileURL: VaultStore.shared.metaURL.appendingPathComponent("trust.json"),
        keyURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PinTack/trust.key"))

    init(fileURL: URL, keyURL: URL) {
        self.fileURL = fileURL
        self.keyURL = keyURL
        reload()
    }

    // MARK: Queries

    func isTrusted(_ k: TrustKey) -> Bool { entries[k.hash] != nil }

    var all: [Entry] { entries.values.map(\.entry).sorted { $0.approvedAt > $1.approvedAt } }

    // MARK: Changes

    func approve(_ k: TrustKey, now: Date = Date()) {
        let entry = Entry(hash: k.hash, kind: k.kind.rawValue, value: k.value, cwd: k.cwd, approvedAt: now)
        entries[k.hash] = (entry, mac(for: k.hash))
        save()
    }

    func revoke(hash: String) {
        entries.removeValue(forKey: hash)
        save()
    }

    func revokeAll() {
        entries.removeAll()
        save()
    }

    // MARK: Persistence

    func reload() {
        entries = [:]
        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] else { return }
        let iso = ISO8601DateFormatter()
        for (hash, e) in raw {
            guard let kind = e["kind"] ?? Optional("run"), let value = e["command"], let cwd = e["cwd"], let mac = e["mac"],
                  let date = iso.date(from: e["approvedAt"] ?? ""),
                  mac == self.mac(for: hash),
                  TrustKey(kind: TrustKey.Kind(rawValue: kind) ?? .command, value: value, cwd: cwd).hash == hash else {
                NSLog("PinTack: ignoring a trust entry that is not verified for this Mac")
                continue
            }
            entries[hash] = (Entry(hash: hash, kind: kind, value: value, cwd: cwd, approvedAt: date), mac)
        }
    }

    private func save() {
        let iso = ISO8601DateFormatter()
        var raw: [String: [String: String]] = [:]
        for (hash, item) in entries {
            raw[hash] = ["kind": item.entry.kind, "command": item.entry.value, "cwd": item.entry.cwd,
                         "approvedAt": iso.string(from: item.entry.approvedAt), "mac": item.mac]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try AtomicWriter.write(data, to: fileURL) } catch { NSLog("PinTack: could not save trust.json: \(error)") }
    }

    // MARK: Per-Mac secret

    private func mac(for hash: String) -> String {
        let secret = secretKey()
        return HMAC<SHA256>.authenticationCode(for: Data(hash.utf8), using: secret).map { String(format: "%02x", $0) }.joined()
    }

    private func secretKey() -> SymmetricKey {
        if let key { return key }
        let fm = FileManager.default
        if let data = try? Data(contentsOf: keyURL), data.count == 32 {
            key = SymmetricKey(data: data)
            return key!
        }
        let fresh = SymmetricKey(size: .bits256)
        let bytes = fresh.withUnsafeBytes { Data($0) }
        try? fm.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: keyURL.path, contents: bytes, attributes: [.posixPermissions: 0o600])
        key = fresh
        return fresh
    }
}
