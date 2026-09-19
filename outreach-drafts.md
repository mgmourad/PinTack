# Outreach drafts — recruiting a maintainer

**Not for the repository.** This is working material for you.

Post these once the repo is public with README, CONTRIBUTING, SPEC, and the prototype link live. Posting before the repo exists wastes the one shot you get in each venue.

---

## Before you post: the evidence package

The single highest-leverage hour you can spend is collecting the incumbent's one- and two-star reviews that ask for features on your list, plus any similar requests on other sticky-notes apps. Screenshot them into `docs/demand/`.

This matters because it converts your pitch from *"I have an idea"* into *"here is documented unmet demand in a category with an inattentive incumbent."* Developers are pitched ideas constantly. Evidence is rare.

Link to that folder in every post below.

---

## 1. r/macapps

Audience: Mac power users, plus a meaningful number of indie Mac developers who lurk there. This is your best single venue.

> **Building an open-source sticky notes app for macOS with Live Preview markdown and a real widget. Spec is done, looking for a maintainer.**
>
> I paid for a sticky notes app on the App Store, liked it, and left a review asking for about ten things: a hotkey to start a note, pin-on-top, an opacity slider, a central window listing all notes, folders, tags, widgets, and a way to export everything. No response, and looking at the architecture I don't think most of it was possible on their stack. The app is 377 MB, which tells you what it's built on, and WidgetKit is basically out of reach from there.
>
> So I specced out the native version instead. Plain markdown files in a folder, Obsidian-style Live Preview rendering, floating note panels, an interactive WidgetKit widget where you can check off tasks without opening the app, and a JavaScript plugin system that ships with one plugin (inline buttons in your notes that run a script or open a URL).
>
> Notes are just `.md` files with YAML frontmatter, so export is "zip the folder" and sync is "put it in iCloud Drive." If the project dies, your notes still open in TextEdit.
>
> Here's the honest part: **I'm not a Swift developer.** I do Windows endpoint automation for a living. I've written a full technical specification, built a working interaction prototype, and I'm covering the Apple Developer membership. What I don't have is the code, and I'm not going to be the one maintaining it.
>
> I'm looking for a macOS developer who wants to own this. GPL-3.0, so nobody can close it later.
>
> Spec: [link]
> Prototype: [link]
> Repo: [link]
>
> Happy to be told the architecture is wrong. That's more useful to me than polite interest.

---

## 2. Swift Forums (Related Projects) and Mastodon

Shorter. This audience does not need the category explained and will judge you on technical specifics.

> **PinTack — open-source macOS sticky notes, spec complete, seeking a maintainer**
>
> AppKit shell, one `NSPanel` per note, `WKWebView` hosting CodeMirror 6 for Obsidian-style Live Preview, WidgetKit + AppIntents for an interactive widget, and a JS plugin API. Storage is a plain Markdown vault, no database.
>
> The spec already works through the parts that bite you later: the transparent-margin window architecture needed to draw a pushpin overhanging the card edge (with the custom hit testing and manual shadow that forces), the Team-ID-prefixed App Group requirement that silently kills widgets, and login-shell invocation for the script-runner plugin because GUI apps don't inherit `PATH`.
>
> I wrote the spec and the prototype. I don't write Swift. Looking for someone to own the implementation. GPL-3.0.
>
> [spec link] · [repo link]

For Mastodon, hashtag `#macOS #Swift #AppKit #OpenSource` and post in the morning Eastern, when the Apple dev community there is most active.

---

## 3. Hacker News (Show HN) — hold this one

**Do not post to HN until there is a working build.** Show HN for a specification gets a rough reception, and you only get one first impression. Save it for the Phase 2 milestone when Live Preview actually works, and lead with a video of the editor rather than the feature list.

---

## 4. Direct outreach

More effective than any broadcast post, and almost nobody does it.

Find Mac developers who have shipped small, well-crafted utilities: menu bar apps, window managers, note tools. Look at who maintains popular Homebrew casks in the productivity category. Look at contributors to open-source Mac apps that recently went quiet.

Personalize each message, one paragraph, and link the spec. Say plainly what you want and what you are bringing. A developer who has shipped a Mac utility knows exactly how much work a finished spec saves them.

Do not send more than a handful at a time, and do not send a second message to anyone who does not reply.

---

## 5. If nobody bites

The honest fallback, worth knowing now rather than after a year of silence: contracting a competent Mac developer to build a v1 of this scope is a real five-figure number.

A middle path is to contract Phase 1 and Phase 2 only, which produces a running app with working Live Preview. A project that visibly works attracts contributors in a way a specification never will. Communities refine working software; they do not build it from documents.
