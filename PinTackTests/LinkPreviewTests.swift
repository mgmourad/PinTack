import XCTest
@testable import PinTack

/// Link previews are the one feature that contacts a website (CLAUDE.md constraint 3), so what it
/// will and will not request matters more than what it renders.
final class LinkPreviewSafetyTests: XCTestCase {

    // MARK: What we are willing to fetch

    func testOnlyHTTPAndHTTPSAreEverFetched() {
        XCTAssertNotNil(LinkPreviewStore.sanitize("https://example.com/page"))
        XCTAssertNotNil(LinkPreviewStore.sanitize("http://example.com"))
        for refused in ["file:///etc/passwd", "ftp://example.com", "pintack-app://editor/index.html",
                        "javascript:alert(1)", "data:text/html,<b>x</b>", "mailto:someone@example.com",
                        "about:blank", "", "not a url", "https://", "http:///nohost"] {
            XCTAssertNil(LinkPreviewStore.sanitize(refused), "\(refused) must never be requested")
        }
    }

    func testCredentialsInAURLAreStrippedBeforeAnyRequest() throws {
        let url = try XCTUnwrap(LinkPreviewStore.sanitize("https://user:hunter2@example.com/x"))
        XCTAssertFalse(url.absoluteString.contains("hunter2"), "a password must not be sent to the site")
        XCTAssertFalse(url.absoluteString.contains("user"))
        XCTAssertEqual(url.host, "example.com")
    }

    func testFragmentIsNotSentToTheSite() throws {
        let url = try XCTUnwrap(LinkPreviewStore.sanitize("https://example.com/doc#my-private-anchor"))
        XCTAssertFalse(url.absoluteString.contains("my-private-anchor"))
    }

    // MARK: Reading a page's metadata

    func testOpenGraphTagsWin() {
        let meta = MetaTags(html: """
        <html><head><title>Fallback title</title>
        <meta property="og:title" content="The real title">
        <meta property="og:description" content="A short summary.">
        <meta property="og:image" content="https://cdn.example.com/card.png">
        </head><body>x</body></html>
        """)
        XCTAssertEqual(meta.first("og:title", "twitter:title"), "The real title")
        XCTAssertEqual(meta.first("og:description", "description"), "A short summary.")
        XCTAssertEqual(meta.first("og:image"), "https://cdn.example.com/card.png")
        XCTAssertEqual(meta.htmlTitle, "Fallback title")
    }

    func testFallsBackToTheDocumentTitleAndPlainDescription() {
        let meta = MetaTags(html: "<html><head><title>  Just a page  </title>"
                          + "<meta name='description' content='Plain description'></head></html>")
        XCTAssertNil(meta.first("og:title"))
        XCTAssertEqual(meta.htmlTitle, "Just a page")
        XCTAssertEqual(meta.first("og:description", "description"), "Plain description")
    }

    func testEntitiesAndWhitespaceAreTidied() {
        let meta = MetaTags(html: #"<meta property="og:title" content="Ben &amp; Jerry&#39;s  &quot;best&quot;">"#)
        XCTAssertEqual(meta.first("og:title"), "Ben & Jerry's \"best\"")
    }

    func testSingleQuotedAndUnquotedAttributesParse() {
        XCTAssertEqual(MetaTags(html: "<meta property='og:title' content='Single'>").first("og:title"), "Single")
        XCTAssertEqual(MetaTags(html: "<meta property=og:title content=Unquoted>").first("og:title"), "Unquoted")
    }

    func testPageWithNoUsableTagsYieldsNothingRatherThanGarbage() {
        let meta = MetaTags(html: "<html><body><h1>No head at all</h1></body></html>")
        XCTAssertNil(meta.first("og:title", "twitter:title", "description"))
        XCTAssertNil(meta.htmlTitle)
    }

    /// A title is shown to the user, so markup inside it must arrive as text, not as a tag.
    func testTitleContainingMarkupIsNotTreatedAsHTML() {
        let meta = MetaTags(html: #"<meta property="og:title" content="&lt;script&gt;alert(1)&lt;/script&gt;">"#)
        XCTAssertEqual(meta.first("og:title"), "<script>alert(1)</script>")
    }

    // MARK: Dismissals

    func testDismissingIsPerNoteAndReversible() {
        let store = LinkPreviewStore.shared
        let url = "https://example.com/dismiss-test"
        store.restore(noteID: "NOTE-A", url: url)
        store.restore(noteID: "NOTE-B", url: url)

        XCTAssertFalse(store.isDismissed(noteID: "NOTE-A", url: url))
        store.dismiss(noteID: "NOTE-A", url: url)
        XCTAssertTrue(store.isDismissed(noteID: "NOTE-A", url: url))
        XCTAssertFalse(store.isDismissed(noteID: "NOTE-B", url: url), "another note keeps its card")

        store.restore(noteID: "NOTE-A", url: url)
        XCTAssertFalse(store.isDismissed(noteID: "NOTE-A", url: url))
    }

    /// The ✕ hides the card for the link sitting in the note, not for that address for ever.
    /// Deleting the URL and pasting it again must preview it again.
    func testDismissalIsForgottenOnceTheLinkLeavesTheNote() {
        let store = LinkPreviewStore.shared
        let url = "https://example.com/prune-test"
        let note = "NOTE-PRUNE"
        store.restore(noteID: note, url: url)

        store.dismiss(noteID: note, url: url)
        XCTAssertTrue(store.isDismissed(noteID: note, url: url))

        // Still there while the link is still written in the note.
        store.pruneDismissals(noteID: note, body: "# Notes\n\n\(url)\n")
        XCTAssertTrue(store.isDismissed(noteID: note, url: url), "the ✕ holds while the link is still there")

        // The user deletes the line; the dismissal goes with it.
        store.pruneDismissals(noteID: note, body: "# Notes\n\nnothing here now\n")
        XCTAssertFalse(store.isDismissed(noteID: note, url: url), "pasting the link again must preview it again")
    }

    func testPruningOneNoteLeavesAnotherNotesDismissalAlone() {
        let store = LinkPreviewStore.shared
        let url = "https://example.com/prune-isolation"
        store.restore(noteID: "NOTE-X", url: url)
        store.restore(noteID: "NOTE-Y", url: url)
        store.dismiss(noteID: "NOTE-X", url: url)
        store.dismiss(noteID: "NOTE-Y", url: url)

        store.pruneDismissals(noteID: "NOTE-X", body: "the link is gone from this note")
        XCTAssertFalse(store.isDismissed(noteID: "NOTE-X", url: url))
        XCTAssertTrue(store.isDismissed(noteID: "NOTE-Y", url: url), "another note's ✕ must not be undone")
        store.restore(noteID: "NOTE-Y", url: url)
    }
}
