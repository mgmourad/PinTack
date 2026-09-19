import Foundation
import AppKit

/// A single note. Backed 1:1 by a Markdown file in the vault.
/// See SPEC.md §3.3 for the frontmatter schema.
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
    var cardFrame: NSRect      // CARD rect, not window rect. SPEC.md §5.2.

    var body: String
    var fileURL: URL

    /// Frontmatter keys we do not recognize. Preserved verbatim on write:
    /// plugins own these and dropping them is data loss. SPEC.md §3.3.
    var unknownKeys: [(String, String)] = []

    var title: String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("#") {
                return t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            }
            return String(t.prefix(60))
        }
        return "Untitled"
    }

    var color: NSColor { NSColor(hex: colorHex) ?? NSColor(hex: "#FFE38A")! }

    /// Resolved light/dark text treatment. `auto` computes from background
    /// luminance so a user-chosen color can never be unreadable. SPEC.md §9.
    var isDarkText: Bool {
        switch theme {
        case "light": return true
        case "dark":  return false
        default:      return color.relativeLuminance > 0.45
        }
    }

    init(fileURL: URL,
         body: String = "",
         cardFrame: NSRect = NSRect(x: 200, y: 200, width: 280, height: 210)) {
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

    /// Parses a note file. A file with no frontmatter is still a valid note;
    /// missing keys take defaults and are written on first save.
    static func load(from url: URL) throws -> Note {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let note = Note(fileURL: url)

        guard raw.hasPrefix("---\n") else {
            note.body = raw
            return note
        }

        let afterOpen = raw.index(raw.startIndex, offsetBy: 4)
        guard let closeRange = raw.range(of: "\n---\n", range: afterOpen..<raw.endIndex) else {
            note.body = raw
            return note
        }

        let yaml = String(raw[afterOpen..<closeRange.lowerBound])
        note.body = String(raw[closeRange.upperBound...])
        note.apply(yaml: yaml)
        return note
    }

    /// Minimal YAML subset: flat `key: value` plus one level of nesting for `frame:`.
    /// Deliberately not a general YAML parser; the schema is fixed and small.
    private func apply(yaml: String) {
        var inFrame = false
        var frame = (x: cardFrame.origin.x, y: cardFrame.origin.y,
                     w: cardFrame.size.width, h: cardFrame.size.height)

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            let indented = line.hasPrefix("  ") || line.hasPrefix("\t")
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            if inFrame && indented {
                switch key {
                case "x": frame.x = Double(value) ?? frame.x
                case "y": frame.y = Double(value) ?? frame.y
                case "w": frame.w = Double(value) ?? frame.w
                case "h": frame.h = Double(value) ?? frame.h
                default: break
                }
                continue
            }
            inFrame = false

            switch key {
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
                tags = value
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "frame":
                inFrame = true
            default:
                // Unknown key: preserve it. SPEC.md §3.3.
                unknownKeys.append((key, value))
            }
        }

        cardFrame = NSRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
    }

    // MARK: - Serialization

    func serialized() -> String {
        var out = "---\n"
        out += "id: \(id)\n"
        out += "created: \(Note.iso.string(from: created))\n"
        out += "modified: \(Note.iso.string(from: Date()))\n"
        out += "tags: [\(tags.joined(separator: ", "))]\n"
        out += "pinned: \(pinned)\n"
        out += "color: \"\(colorHex)\"\n"
        out += "theme: \(theme)\n"
        out += "opacity: \(String(format: "%.2f", opacity))\n"
        out += "collapsed: \(collapsed)\n"
        out += "visible: \(visible)\n"
        out += "frame:\n"
        out += "  x: \(Int(cardFrame.origin.x))\n"
        out += "  y: \(Int(cardFrame.origin.y))\n"
        out += "  w: \(Int(cardFrame.size.width))\n"
        out += "  h: \(Int(cardFrame.size.height))\n"
        for (k, v) in unknownKeys { out += "\(k): \(v)\n" }
        out += "---\n"
        out += body
        return out
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Color helpers

extension NSColor {

    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
                  green:   CGFloat((v >> 8) & 0xFF) / 255.0,
                  blue:    CGFloat(v & 0xFF) / 255.0,
                  alpha:   1.0)
    }

    /// WCAG relative luminance, used to decide light vs dark text.
    var relativeLuminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 1 }
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent)
             + 0.7152 * lin(c.greenComponent)
             + 0.0722 * lin(c.blueComponent)
    }
}
