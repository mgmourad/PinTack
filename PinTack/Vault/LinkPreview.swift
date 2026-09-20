import AppKit

/// Link previews: the title, description and thumbnail for a URL pasted on its own line.
///
/// THIS IS THE ONLY PART OF PINTACK THAT TOUCHES THE NETWORK, besides Sparkle update checks.
/// CLAUDE.md constraint 3 names it as the one exception, and it is hedged accordingly:
///
///   * It is OFF until the user turns it on (Settings → Editor → Link previews). Nothing is
///     requested while it is off.
///   * The fetch happens HERE, in Swift. The note's web view never reaches the network: its CSP
///     still says `connect-src 'none'` and `img-src pintack-app: data:`, so plugins gain nothing
///     from this feature. The thumbnail is written into the vault and loaded from disk.
///   * http and https only, no cookies or credentials, no redirect to another scheme, a short
///     timeout and hard size caps, so a hostile page cannot hold a connection open or fill a disk.
///
/// A fetched result is cached in `.pintack/linkpreviews.json`, so a note that is reopened shows
/// its cards without asking the site again. That file also records which previews the user
/// dismissed with the card's ✕, which is why it, and not the note, holds that state: a dismissal
/// is a display choice and the note stays plain Markdown.
final class LinkPreviewStore {

    static let shared = LinkPreviewStore()

    struct Preview: Codable {
        var url: String
        var title: String
        var summary: String
        var domain: String
        var imageFile: String?        // a file name in the vault's attachments folder
        var fetchedAt: Date
        var failed: Bool = false
    }

    private var cache: [String: Preview] = [:]
    private var dismissed: Set<String> = []       // "<noteID>\n<url>"
    private var inFlight: Set<String> = []
    private var fileURL: URL?

    /// Ephemeral: no cookie jar, no disk cache, nothing about the user is carried to the site.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: RedirectGuard.shared, delegateQueue: nil)
    }()

    private static let maxHTMLBytes = 512 * 1024
    private static let maxImageBytes = 3 * 1024 * 1024

    // MARK: Persistence

    private struct Disk: Codable {
        var previews: [String: Preview]
        var dismissed: [String]
    }

    func load(from metaDirectory: URL) {
        let url = metaDirectory.appendingPathComponent("linkpreviews.json")
        fileURL = url
        guard let data = try? Data(contentsOf: url), let disk = try? JSONDecoder().decode(Disk.self, from: data) else { return }
        cache = disk.previews
        dismissed = Set(disk.dismissed)
    }

    private func save() {
        guard let fileURL else { return }
        let disk = Disk(previews: cache, dismissed: Array(dismissed))
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? AtomicWriter.write(data, to: fileURL)
    }

    // MARK: Dismissal

    private func key(_ noteID: String, _ url: String) -> String { noteID + "\n" + url }

    func isDismissed(noteID: String, url: String) -> Bool { dismissed.contains(key(noteID, url)) }

    func dismiss(noteID: String, url: String) {
        dismissed.insert(key(noteID, url))
        save()
    }

    func restore(noteID: String, url: String) {
        dismissed.remove(key(noteID, url))
        save()
    }

    // MARK: Lookup

    /// The payload the editor draws, or nil when nothing is known yet.
    func cached(_ url: String) -> [String: Any]? {
        guard let p = cache[url], !p.failed else { return nil }
        var out: [String: Any] = ["url": p.url, "title": p.title, "summary": p.summary, "domain": p.domain]
        if let file = p.imageFile { out["image"] = "attachments/" + file }
        return out
    }

    func hasFailed(_ url: String) -> Bool { cache[url]?.failed == true }

    /// Fetches a preview unless one is cached, previews are switched off, or the URL is not
    /// something we are willing to request. `completion` runs on the main queue when new data
    /// arrived, so the note can redraw.
    func fetch(_ raw: String, completion: @escaping (String) -> Void) {
        guard AppSettings.shared.linkPreviews else { return }
        guard cache[raw] == nil, !inFlight.contains(raw), let url = Self.sanitize(raw) else { return }
        inFlight.insert(raw)

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) PinTack link preview", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            let host = url.host ?? raw
            guard let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return self.finish(raw, Preview(url: raw, title: "", summary: "", domain: host, fetchedAt: Date(), failed: true), completion)
            }
            let html = String(decoding: data.prefix(Self.maxHTMLBytes), as: UTF8.self)
            let meta = MetaTags(html: html)
            let title = meta.first("og:title", "twitter:title") ?? meta.htmlTitle ?? host
            let summary = meta.first("og:description", "twitter:description", "description") ?? ""
            var preview = Preview(url: raw, title: title, summary: summary, domain: host, fetchedAt: Date())

            // The thumbnail is saved into the vault so the web view loads it from disk, not the net.
            guard let imageURL = meta.first("og:image", "twitter:image").flatMap({ URL(string: $0, relativeTo: url)?.absoluteURL }),
                  let safeImage = Self.sanitize(imageURL.absoluteString) else {
                return self.finish(raw, preview, completion)
            }
            self.session.dataTask(with: URLRequest(url: safeImage)) { imageData, imageResponse, _ in
                if let imageData, imageData.count <= Self.maxImageBytes,
                   let http = imageResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let file = Self.storeThumbnail(imageData) {
                    preview.imageFile = file
                }
                self.finish(raw, preview, completion)
            }.resume()
        }.resume()
    }

    private func finish(_ raw: String, _ preview: Preview, _ completion: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            self.inFlight.remove(raw)
            self.cache[raw] = preview
            self.save()
            completion(raw)
        }
    }

    /// Re-fetch a URL the next time it is seen (used by "Clear link preview cache").
    func clearCache() {
        cache.removeAll()
        save()
    }

    // MARK: Safety

    /// http/https only, no embedded credentials, and nothing that is not a real remote host.
    static func sanitize(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        // A URL carrying a password would send it to the site on our own initiative.
        components.user = nil
        components.password = nil
        components.fragment = nil
        return components.url
    }

    /// Downscales the thumbnail and writes it into the vault's attachments folder as a PNG.
    private static func storeThumbnail(_ data: Data) -> String? {
        guard let image = NSImage(data: data), image.size.width > 1, image.size.height > 1 else { return nil }
        let maxSide: CGFloat = 640
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        // writeAttachment returns "attachments/<name>"; the cache stores the bare file name.
        guard let path = VaultStore.shared.writeAttachment(png, ext: "png") else { return nil }
        return (path as NSString).lastPathComponent
    }
}

/// Refuses a redirect that would leave http/https (a `file:` or custom-scheme redirect).
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    static let shared = RedirectGuard()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, LinkPreviewStore.sanitize(url.absoluteString) != nil else {
            return completionHandler(nil)
        }
        completionHandler(request)
    }
}

/// The few `<meta>` tags a preview needs, without pulling in an HTML parser.
/// Internal rather than private so the tests can feed it real-world HTML.
struct MetaTags {

    private var values: [String: String] = [:]
    var htmlTitle: String?

    init(html: String) {
        let head = String(html.prefix(200_000))
        let pattern = #"<meta\s+[^>]*>"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let ns = head as NSString
            for match in regex.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
                let tag = ns.substring(with: match.range)
                guard let name = MetaTags.attribute("property", in: tag) ?? MetaTags.attribute("name", in: tag),
                      let content = MetaTags.attribute("content", in: tag), !content.isEmpty else { continue }
                let key = name.lowercased()
                if values[key] == nil { values[key] = MetaTags.decode(content) }
            }
        }
        if let range = head.range(of: #"<title[^>]*>([\s\S]{0,400}?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            let inner = head[range].replacingOccurrences(of: #"</?title[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            htmlTitle = MetaTags.decode(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func first(_ keys: String...) -> String? {
        for key in keys {
            if let value = values[key], !value.isEmpty { return value }
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length))
        else { return nil }
        let ns = tag as NSString
        for group in 2...4 where match.range(at: group).location != NSNotFound {
            return ns.substring(with: match.range(at: group))
        }
        return nil
    }

    /// Just the entities a title or description realistically contains.
    private static func decode(_ s: String) -> String {
        var out = s
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                               ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
