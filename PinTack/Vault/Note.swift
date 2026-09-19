import Foundation
import AppKit

/// A single note. Backed 1:1 by a Markdown file in the vault.
/// Frontmatter schema: SPEC.md §3.3.
///
/// This type is where vault data loss would happen, so the rules are strict:
///   * Unknown frontmatter keys are kept as raw text blocks and written back
///     verbatim, including nested maps and lists. Plugins own them. §3.3.
///   * The body is never altered by a load/save round trip.
///   * A file's CRLF line endings survive (the vault is edited from Windows too).
final class Note {

    var id: String
    var created: Date
    var modified: Date
    var tags: [String]
    var pinned: Bool
    var colorHex: String
    var theme: String          // auto | light | dark
    var opacity: Double        // 0.3 ... 1.0
    var collapsed: Bool
    var visible: Bool

    /// The EXPANDED card rect in screen coordinates. Never the window rect
    /// (SPEC.md §5.2), and never the collapsed height.
    var cardFrame: NSRect
    /// False when the file had no `frame:`; the window manager then auto-places it.
    var hasFrame: Bool

    var body: String
    var fileURL: URL

    /// Frontmatter blocks we do not recognize, verbatim (key line plus any
    /// indented continuation lines). SPEC.md §3.3.
    var unknownBlocks: [String] = []
    var usesCRLF = false

    /// Hash of the last text this process wrote, so the file watcher can tell
    /// its own writes from external edits. SPEC.md §3.7.
    var lastWrittenHash: Int = 0

    static let defaultCardSize = NSSize(width: 280, height: 210)

    var title: String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("#") {
                let h = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                return h.isEmpty ? "Untitled" : h
            }
            return String(t.prefix(60))
        }
        return "Untitled"
    }

    var color: NSColor { NSColor(hex: colorHex) ?? NSColor(hex: "#FFE38A")! }

    /// Text treatment. `auto` computes from background luminance so a chosen
    /// color can never produce unreadable text. SPEC.md §9.
    var isDarkText: Bool {
        switch theme {
        case "light": return true      // "light" note = light paper, dark text
        case "dark":  return false
        default:      return color.relativeLuminance > 0.45
        }
    }

    init(fileURL: URL,
         body: String = "",
         cardFrame: NSRect = NSRect(origin: NSPoint(x: 200, y: 200), size: Note.defaultCardSize)) {
        self.id = Note.newID()
        self.created = Date()
        self.modified = Date()
        self.tags = []
        self.pinned = false
        self.colorHex = "#FFE38A"
        self.theme = "auto"
        self.opacity = 1.0
        self.collapsed = false
        self.visible = true
        self.cardFrame = cardFrame
        self.hasFrame = false
        self.body = body
        self.fileURL = fileURL
    }

    // MARK: - Identity

    /// ULID-ish: sortable, timestamp-prefixed. Good enough without a dependency.
    static func newID() -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var time = ""
        var t = ms
        for _ in 0..<10 {
            time = String(alphabet[Int(t % 32)]) + time
            t /= 32
        }
        let rand = (0..<16).map { _ in String(alphabet[Int.random(in: 0..<32)]) }.joined()
        return time + rand
    }

    // MARK: - Parsing

    static func load(from url: URL) throws -> Note {
        let raw = try String(contentsOf: url, encoding: .utf8)
        return parse(raw, fileURL: url)
    }

    /// A file with no frontmatter is still a valid note; missing keys take
    /// defaults and are written on first save. SPEC.md §3.3.
    static func parse(_ rawInput: String, fileURL: URL) -> Note {
        let crlf = rawInput.contains("\r\n")
        let raw = crlf ? rawInput.replacingOccurrences(of: "\r\n", with: "\n") : rawInput
        let note = Note(fileURL: fileURL)
        note.usesCRLF = crlf

        let lines = raw.components(separatedBy: "\n")
        guard lines.first == "---",
              let end = lines.dropFirst().firstIndex(of: "---") else {
            note.body = raw
            return note
        }
        note.body = lines[(end + 1)...].joined(separator: "\n")
        note.apply(yamlLines: Array(lines[1..<end]))
        return note
    }

    private struct Block {
        var key: String
        var value: String
        var lines: [String]
    }

    /// Groups frontmatter into top-level blocks. A block is a `key: value` line
    /// plus everything indented (or a `- item` / blank / comment) beneath it.
    private static func blocks(from yaml: [String]) -> [Block] {
        var out: [Block] = []
        for line in yaml {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let continuation = line.hasPrefix(" ") || line.hasPrefix("\t")
                || line.hasPrefix("- ") || line == "-"
                || trimmed.isEmpty || trimmed.hasPrefix("#")
            if continuation, !out.isEmpty {
                out[out.count - 1].lines.append(line)
                continue
            }
            if let colon = line.firstIndex(of: ":"), !continuation {
                let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                out.append(Block(key: key, value: value, lines: [line]))
            } else {
                out.append(Block(key: "", value: "", lines: [line]))   // unparseable: keep verbatim
            }
        }
        return out
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, let l = s.last, f == l, f == "\"" || f == "'" else { return s }
        return String(s.dropFirst().dropLast())
    }

    private func apply(yamlLines: [String]) {
        var frame = (x: cardFrame.origin.x, y: cardFrame.origin.y,
                     w: cardFrame.size.width, h: cardFrame.size.height)

        for block in Note.blocks(from: yamlLines) {
            let value = Note.unquote(block.value)
            switch block.key {
            case "id":        if !value.isEmpty { id = value }
            case "created":   created = Note.iso.date(from: value) ?? created
            case "modified":  modified = Note.iso.date(from: value) ?? modified
            case "pinned":    pinned = (value == "true")
            case "collapsed": collapsed = (value == "true")
            case "visible":   visible = (value != "false")
            case "color":     if !value.isEmpty { colorHex = value }
            case "theme":     if !value.isEmpty { theme = value }
            case "opacity":   opacity = min(1.0, max(0.3, Double(value) ?? 1.0))
            case "tags":
                if block.value.hasPrefix("[") {
                    tags = block.value
                        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",")
                        .map { Note.unquote($0.trimmingCharacters(in: .whitespaces)) }
                        .filter { !$0.isEmpty }
                } else {
                    // Block list form:   tags:\n  - work\n  - urgent
                    tags = block.lines.dropFirst().compactMap { l in
                        let t = l.trimmingCharacters(in: .whitespaces)
                        guard t.hasPrefix("-") else { return nil }
                        let v = Note.unquote(t.dropFirst().trimmingCharacters(in: .whitespaces))
                        return v.isEmpty ? nil : v
                    }
                }
            case "frame":
                for l in block.lines.dropFirst() {
                    guard let colon = l.firstIndex(of: ":") else { continue }
                    let k = l[l.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                    let v = Double(l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                    switch k {
                    case "x": frame.x = v ?? frame.x
                    case "y": frame.y = v ?? frame.y
                    case "w": frame.w = v ?? frame.w
                    case "h": frame.h = v ?? frame.h
                    default: break
                    }
                }
                cardFrame = NSRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
                hasFrame = true
            default:
                // Unknown key: preserve the whole block verbatim. SPEC.md §3.3.
                unknownBlocks.append(block.lines.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Serialization

    func serialized() -> String {
        var out = "---\n"
        out += "id: \(id)\n"
        out += "created: \(Note.iso.string(from: created))\n"
        out += "modified: \(Note.iso.string(from: modified))\n"
        out += "tags: [\(tags.joined(separator: ", "))]\n"
        out += "pinned: \(pinned)\n"
        out += "color: \"\(colorHex)\"\n"
        out += "theme: \(theme)\n"
        out += "opacity: \(String(format: "%.2f", opacity))\n"
        out += "collapsed: \(collapsed)\n"
        out += "visible: \(visible)\n"
        out += "frame:\n"
        out += "  x: \(Int(cardFrame.origin.x.rounded()))\n"
        out += "  y: \(Int(cardFrame.origin.y.rounded()))\n"
        out += "  w: \(Int(cardFrame.size.width.rounded()))\n"
        out += "  h: \(Int(cardFrame.size.height.rounded()))\n"
        for block in unknownBlocks { out += block + "\n" }
        out += "---\n"
        out += body
        return usesCRLF ? out.replacingOccurrences(of: "\n", with: "\r\n") : out
    }

    /// Copy everything from a freshly parsed copy of the same file, keeping this
    /// object's identity (open windows hold references to it).
    func adopt(_ other: Note) {
        created = other.created; modified = other.modified; tags = other.tags
        pinned = other.pinned; colorHex = other.colorHex; theme = other.theme
        opacity = other.opacity; collapsed = other.collapsed; visible = other.visible
        cardFrame = other.cardFrame; hasFrame = other.hasFrame
        body = other.body; unknownBlocks = other.unknownBlocks; usesCRLF = other.usesCRLF
        if other.id != id { id = other.id }
    }

    // MARK: - Tags

    /// Inline `#tag` in the body is merged into the frontmatter array on save.
    /// Matching is case-insensitive, stored as typed. SPEC.md §3.5.
    func mergeInlineTags() {
        var inFence = false
        var found: [String] = []
        for line in body.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            let range = NSRange(line.startIndex..., in: line)
            for m in Note.inlineTag.matches(in: line, range: range) {
                if let r = Range(m.range(at: 2), in: line) { found.append(String(line[r])) }
            }
        }
        for tag in found where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
    }

    // NSRegularExpression is documented as safe for concurrent use.
    private static let inlineTag = try! NSRegularExpression(pattern: #"(^|[\s(])#([A-Za-z][\w/-]*)"#)

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
