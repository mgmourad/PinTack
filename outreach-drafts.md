# Outreach drafts — recruiting a maintainer

**Not for the repository.** This is working material for you. *(It is currently tracked in git, so it
will be public the moment the repo is. Remove it from the repo before publishing if you want it
private.)*

*Updated 2026-09-21.* The pitch has changed since these were first drafted: they used to say "the spec
is done, I don't have the code." There is now a working app in beta (0.1.0, build 8), which is a much
stronger thing to hand a developer. The drafts below say so.

Post these once the repo is public with README, CONTRIBUTING, SPEC, CHANGELOG and a tester DMG link
live. Posting before the repo exists wastes the one shot you get in each venue.

---

## Before you post: the evidence package

Two things, both worth an hour.

**Demand.** Collect the incumbent's one- and two-star reviews that ask for features on your list, plus
similar requests on other sticky-notes apps. Screenshot them into `docs/demand/`. This converts the
pitch from *"I have an idea"* into *"here is documented unmet demand in a category with an inattentive
incumbent."*

**Proof it works.** A 60–90 second screen recording: a note dropping onto the desktop, Live Preview
rendering as you type, a checklist whose tracker fills in, pin and freeze, the All Notes window. Nobody
reads a feature list; everybody watches a short video. The self-test screenshots in the repo are good
stills for the README, but the video is what gets clicks.

Link both in every post below.

---

## 1. r/macapps

Audience: Mac power users, plus a meaningful number of indie Mac developers who lurk there. This is
your best single venue.

> **I built an open-source sticky notes app for macOS — Live Preview markdown, todos with reminders, plugins. It works. Looking for a Mac developer to own it.**
>
> I paid for a sticky notes app on the App Store, liked it, and left a review asking for about ten things: a hotkey to start a note, pin-on-top, an opacity slider, a central window listing all notes, folders, tags, widgets, and a way to export everything. No response, and looking at the architecture I don't think most of it was possible on their stack. The app is 377 MB, which tells you what it's built on.
>
> So I built the native version. PinTack is 14 MB. Notes float on the desktop as real windows, each one a plain `.md` file with YAML frontmatter in a folder you own — export is "zip the folder," sync is "put it in iCloud Drive," and if the project dies your notes still open in TextEdit. Editing is Obsidian-style Live Preview. Todo notes get a progress tracker, due dates and reminders. You can pin a note on top, fade it, freeze it so clicks pass through, and find anything with full-text search. There's a JavaScript plugin system with one plugin in the box: inline buttons in your notes that run a script, and every command needs your approval first.
>
> Here's the honest part: **I'm not a Swift developer.** I do Windows endpoint automation for a living. I directed the design, wrote the specification, and built it with an AI coding agent, verified by a test suite and a self-test that drives the real app and fails the build if anything's wrong. It's in beta with testers now. What it needs is a macOS developer who wants to own the codebase — signing, notarization, Sparkle updates, the widget, and whatever comes after.
>
> GPL-3.0, so nobody can close it later.
>
> Video: [link] · Repo: [link] · Tester build: [link]
>
> Happy to be told what's wrong with it. That's more useful to me than polite interest.

**Be upfront about the AI part.** Developers will find out from the commit trailers anyway, and being
the one who says it first is what keeps it from becoming the whole conversation. The strong version of
the claim is the true one: every change is tested, the tests were mutation-checked, and the history
explains itself.

---

## 2. Swift Forums (Related Projects) and Mastodon

Shorter. This audience does not need the category explained and will judge you on technical specifics.

> **PinTack — open-source macOS sticky notes, working beta, seeking a maintainer**
>
> AppKit shell, one non-activating `NSPanel` per note, `WKWebView` hosting CodeMirror 6 (vendored as ES modules with an import map, no bundler) for Obsidian-style Live Preview, SwiftUI for the central window. Storage is a plain Markdown vault with an FTS5 index that is disposable by design. JS plugin API with per-page capability tokens, declared permissions, and a native approval sheet no plugin can answer.
>
> The things that bite later are already worked through and written down: the 24pt transparent-margin window so a pushpin can overhang the card (with the hit testing and manual shadow that forces), the observer/key-equivalent double dispatch that made a toggle cancel itself, AppKit's window animator not running at all in an inactive app, the Team-ID-prefixed App Group that silently kills widgets, and login-shell execution because GUI apps don't inherit `PATH`.
>
> 230 unit tests plus a self-test that launches the app and asserts on its own windows and web views. I don't write Swift; I'm looking for someone to own it. GPL-3.0.
>
> [repo link] · [SPEC link] · [CHANGELOG link]

For Mastodon, hashtag `#macOS #Swift #AppKit #OpenSource` and post in the morning Eastern, when the
Apple dev community there is most active.

---

## 3. Hacker News (Show HN)

The old advice was "hold this until there is a working build." There is one now, so HN is open — but
**wait for notarization if you can.** A Show HN where every reader's first experience is Gatekeeper
refusing to open the app gets a rough reception, and you only get one first impression. If you post
before notarization, say so in the first line and give the right-click → Open instruction there.

Lead with the video, not the feature list. Title something like: *Show HN: PinTack – native sticky notes
for macOS, plain Markdown files, 14 MB.*

---

## 4. Direct outreach

More effective than any broadcast post, and almost nobody does it.

Find Mac developers who have shipped small, well-crafted utilities: menu bar apps, window managers,
note tools. Look at who maintains popular Homebrew casks in the productivity category. Look at
contributors to open-source Mac apps that recently went quiet.

Personalize each message, one paragraph, and link the repo and the video. Say plainly what you want
and what you are bringing: a working app, a spec that matches it, a changelog that explains every
decision, and a test suite that tells them the moment they break something. A developer who has
shipped a Mac utility knows exactly how much that is worth.

Do not send more than a handful at a time, and do not send a second message to anyone who does not
reply.

---

## 5. If nobody bites

The fallback has changed shape. It used to be "contract someone to build v1," which was a five-figure
number. The app exists now, so the realistic ask is much smaller: a contracted **Phase 5** — Developer
ID signing, notarization, Sparkle and a Homebrew cask. That is days of work for someone who has done it
before, not months, and it turns a tester build into something you can hand to anyone.

A signed, auto-updating app with real users attracts contributors in a way no pitch does. Communities
refine working software; they rarely build it from documents.
