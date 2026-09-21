# PinTack — Technical Specification

**Version:** 0.1.0
**Status:** Built and running. Phases 1–4 complete; Phase 5 (signing, notarization, Sparkle) and the
WidgetKit widget are not built — see §11 and §15.
**Target platform:** macOS 14 (Sonoma) and later
**License:** GPL-3.0-or-later
**Bundle identifier:** `io.cymentix.pintack`

---

## 0. How to read this document

This describes PinTack **as it actually is**, not as it was once planned. Where behaviour was
chosen deliberately over an obvious alternative, the reason is attached, because the reason is the
part that stops someone "fixing" it later.

Section numbers are load-bearing: source comments cite them (`SPEC.md §5.2` and so on). Renumbering
a section orphans those citations, so add subsections rather than shuffling.

Anything **not built** is marked so explicitly. A specification that describes unbuilt behaviour in
the present tense is worse than no specification at all — that is the state this document was
rescued from.

The project owner is not a Swift developer; he is a Windows endpoint automation engineer and owns
product direction. `CLAUDE.md` records how to work with him and the decisions he has made.

---

## 1. What PinTack is

A macOS sticky-notes application where notes are floating desktop windows and the storage is a
folder of plain Markdown files.

The one-line pitch: **Obsidian's editing model, applied to sticky notes.**

### 1.1 What it is not

An owner decision (2026-09-20), and the sharpest line in the project. PinTack keeps the important
things concentrated, in little space, reachable fast. It is **not** a knowledge base. Turned down
by name:

- **`[[wikilinks]]` and backlinks.** Notes referencing each other makes it Obsidian.
- **Note version history.** Defeats the point of a sticky note.
- **Sync conflict resolution.** Personal, not collaborative.

Do not propose these again without new reasoning.

### 1.2 Hard constraints

1. **No cloud sync in v1.** The vault is plain Markdown; syncing it is the user's job.
2. **No dependencies without asking.** CodeMirror 6 and Sparkle are pre-approved. Devicon (MIT) was
   approved for language logos.
3. **No network access from the app**, except Sparkle update checks and **link previews** (§7.3),
   which are off by default and fetched in Swift, never in the page.
4. **Unknown frontmatter keys must survive a write** (§3.3). Plugins own them.
5. **Vault writes must be atomic**, and a failed write must be visible (§4.5).
6. **No autorun in Runner** (§13.4). No flag changes this.
7. **Target macOS 14.0.** Newer APIs need a runtime availability check.
8. **GPL-3.0.** Do not vendor incompatible code.

---

## 2. Architecture overview

A single native macOS app. One process. No helper, no daemon, no server.

| Layer | Where | What |
|---|---|---|
| Shell | `PinTack/App/` | App delegate, menus, status item, key monitor, quick capture |
| Vault | `PinTack/Vault/` | Note parsing/writing, search index, file watcher, link previews, import/export |
| Windows | `PinTack/Windows/` | Note panels, card chrome, editor host, popovers, freeze mode, image editing |
| Central | `PinTack/Central/` | All Notes window, todo/template tabs, progress views |
| Settings | `PinTack/Settings/` | Seven-pane settings, shortcut recorder, shortcut overlay |
| Plugins | `PinTack/Plugins/` | Manifest, manager, bridge, trust store, process runner |
| Editor | `Editor/` | The Live Preview editor: HTML, CSS, JS, vendored CodeMirror |

### 2.1 The editor is a web view, vendored not bundled

Each note hosts a `WKWebView` running CodeMirror 6. `Editor/` is a plain folder copied into the
app; CodeMirror sits in `Editor/vendor/` as unmodified ES modules resolved by an **import map**, so
there is **no bundler** — esbuild or rollup would be a new dependency. Regenerate with
`scripts/vendor-codemirror.sh`.

The page is served over a custom `pintack-app:` scheme by `EditorSchemeHandler`, which refuses any
path resolving outside the editor bundle, the vault's `attachments/`, or a whitelisted absolute
image. The CSP forbids remote loading outright:

```
default-src 'none'; script-src pintack-app: '<hash>'; style-src pintack-app: 'unsafe-inline';
img-src pintack-app: data:; font-src pintack-app:; connect-src 'none'; base-uri 'none'; form-action 'none'
```

**One web view per open note.** Fine at ten; unmeasured at thirty. A known scaling question.

---

## 3. The vault

A folder of Markdown files, by default `~/Documents/PinTack/`. Subfolders are folders. Two names
are reserved: `attachments/` and `plugins/`. App state lives in `.pintack/`.

```
~/Documents/PinTack/
├── 2026-09-20-sprint-blockers.md
├── Work/2026/…
├── attachments/          (images; reserved)
├── plugins/              (JavaScript plugins; reserved)
└── .pintack/
    ├── settings.json     hotkeys.json   index.sqlite
    ├── trust.json        approved commands, HMAC-signed
    └── linkpreviews.json cached previews and dismissals
```

### 3.1 A note is a file

One note, one `.md` file, YAML frontmatter then body. The body is never altered by a load/save
round trip. CRLF line endings survive (the vault may be edited from Windows).

### 3.2 Folders

Directories. Nesting allowed. `VaultStore.folders()` skips the reserved names.

### 3.3 Frontmatter

```yaml
---
id: 01JB2K3MNP4QRS5TUV6WXY        # ULID-ish, sortable, assigned once
created: 2026-09-20T09:14:02Z
modified: 2026-09-20T11:02:44Z
title: "Q4 rollout"               # only when renamed; see §4.4
tags: [work, urgent]
pinned: false
color: "#FFE38A"
theme: auto                       # auto | light | dark — palette mode, never a text colour
opacity: 1.00
collapsed: false
visible: true
frozen: false                     # §5.6
source: "Safari"                  # quick capture only, §8.3
template: change-record           # templates only, §6.2
due: 2026-09-25T09:00:00Z         # todo notes only, §6.3
remindOnTime: true
remindAhead: 30m
---
```

**Unknown keys are preserved verbatim**, including nested maps and block lists. Plugins own them;
dropping one is user data loss. This is the single most heavily tested behaviour in the codebase.

### 3.4 File names

`YYYY-MM-DD-slug.md`, the slug from the note's first line at creation: lowercase ASCII
alphanumerics and hyphens, max 60. **Generated once and never auto-renamed** — renaming a note does
not rename its file, so external links and sync histories stay intact.

### 3.5 Tags

`tags:` in the frontmatter, plus inline `#tags` in the body, merged on save. Autocompleted from the
vault's existing tags. In a note's action bar they are coloured pills (§5.3).

### 3.6 Search

SQLite FTS5, `.pintack/index.sqlite`, rebuilt on load and kept current on save. Backs the All Notes
search field. `/find` (§6.4) does its own fuzzy matching over titles in the page.

### 3.7 External edits

A file watcher reloads notes changed on disk. Each note records a hash of the last text this
process wrote, so the app can tell its own writes from someone else's. Sync conflicts are **not**
resolved (§1.1).

---

## 4. Editor: Live Preview

### 4.1 The model

Formatting renders as you type; raw syntax is revealed only on the line holding the cursor. One
`StateField` turns the markdown syntax tree into decorations — hide the markers, style the content,
swap a few constructs for widgets. A `StateField` rather than a `ViewPlugin` because block-level
replacements (tables) are only legal from a field.

⌥⌘M toggles Live Preview and Source.

The scrollbar is invisible until it is useful: while scrolling, or while the pointer is near the
right edge. The gutter keeps its width so text never reflows.

### 4.2 Markdown supported

Headings, bold, italic, strikethrough, `inline code`, highlight (`==text==`), links, images,
blockquotes, bullet/numbered/task lists, tables, horizontal rules, fenced code.

**Fenced code blocks** are syntax highlighted. Every language CodeMirror ships is vendored
(~3.5 MB), but **none of it is imported up front**: `Editor/languages.js` gives each language a
loader, and the markdown parser calls it the first time a note actually contains that language.
A block naming a language also gets a badge with the language's logo and name — Devicon SVGs (MIT)
in `Editor/icons`, vendored by `scripts/vendor-language-icons.sh`. There is deliberately **no pill**
behind the badge; on dark paper a dark mark gets a faint light halo instead.

Token colours are two palettes chosen by whether the note's paper is light or dark.

### 4.3 Beyond Markdown

- Coloured text as `<span style="color:…">`, tags always hidden in the editor; Tab leaves the span.
  Slash commands are the colour names (`/red`), no prefix.
- Emoji bullets: with one chosen, typing `- ` produces it.
- `@Todo` on line 1 marks a todo note (§6.3).

### 4.4 The bridge, and the title

Swift ↔ page messages over `WKScriptMessageHandler`. Swift decides everything privileged: what may
open, what may be written, what may touch the network.

**Title and first line are separate once renamed.** A note with no `title:` key simply *is* its
first line and follows every edit to it. Renaming the header writes `title:` into the frontmatter
and **never rewrites the body**; from then on the two are independent in both directions. Renaming
back to what the first line says clears the override.

**Pasting rich text** converts the pasteboard's HTML flavour to Markdown (`Editor/html-to-markdown.js`)
rather than flattening it: headings, emphasis, links, nested and task lists, tables, quotes, fenced
code with the source's language. ⇧⌘V pastes plain. The HTML is parsed into a **detached** document
that never enters the page, so nothing in it runs. A remote `<img>` becomes a link, not a Markdown
image, because the CSP would refuse to load it.

### 4.5 Saving

Debounced autosave, immediate flush on blur. Writes are **atomic**: temp file in the same
directory, then `replaceItem`, so a partial write cannot corrupt a note.

Atomic writes cannot prevent a full disk or a locked folder. A failed write is **reported to the
user** (throttled) and the note's id recorded in `VaultStore.saveFailures` — a silent failure is
the one remaining way this app could lose work.

---

## 5. Note windows

### 5.1 The panel

Borderless, resizable, **non-activating** `NSPanel`. Typing in a note does not pull the app forward.
`canBecomeKey` is true or a borderless panel could take no text input at all.
`collectionBehavior` includes `.canJoinAllSpaces`, so notes follow you between Spaces.

### 5.2 The transparent margin — read before touching geometry

**The `NSWindow` is 24pt larger than the visible card on every side.** macOS clips content to
window bounds, so the overhanging pushpin and the pinned glow have nowhere to be drawn otherwise.

Three consequences, all mandatory:

1. `NoteCardView.hitTest` returns `nil` outside the card's rounded rect. Without it every note
   carries an invisible 24pt halo that swallows clicks meant for the desktop.
2. `hasShadow = false`. The system would draw the shadow on the transparent box; the card shadow
   and pinned glow are drawn by hand.
3. **All persisted geometry is the CARD rect, never the window rect.** Getting this wrong makes
   every note drift 24pt per relaunch.

### 5.3 Chrome

**Header:** title (drag to move, double-click to rename), pin, mode, collapse, close.

**Footer — the "action bar":** a palette button, a `>` that opens the formatting tools, and then
either the tools (bullet, bold, italic, code, opacity) or the tag side (tag icon, reminder bell,
task progress, tag pills). The two sides **cross-fade**; only a real open or close animates.

The bar is **30 pt tall plus a row for every extra row of task-tracker squares**, and it grows
**downward**: the window's bottom edge moves and the text area above it never shrinks as a checklist
is typed. The stored card frame is always the plain-bar card, so nothing drifts across relaunches.
A note low on the screen is nudged up rather than grown off it.

Tag pills are coloured from a **djb2 hash of the tag text** — never `hashValue`, which is seeded per
process and would repaint every tag on each launch. They **wrap onto as many lines as the bar is
thick**, but never make it thicker themselves; the ones that still do not fit collapse into a `+N`
pill that opens a popover listing them all. `TagPillsView` is transparent to the mouse so the empty
action bar still drags the note — **except** over that `+N` pill.

### 5.4 Pin

⌥⌘P. A pinned note floats above other windows and draws the owner's pushpin PNG, anchored by the
crack in the paper, with a glow in the note's own colour.

### 5.5 Placement

New notes are placed by the configured rule (cursor, centred, cascade) and clamped on screen.
They spring in; closing fades out (§5.7).

### 5.6 Freeze mode

⌥⌘F, `/freeze`, the snowflake in the action bar, or the right-click menu. A frozen note ignores the
mouse entirely and sits on the desktop as a reference card.

**The way out matters more than the way in.** A window that ignores the mouse cannot be clicked to
un-ignore itself, cannot be right-clicked, and can never become key — so no shortcut reaches it.
`FreezeMode` therefore keeps the **snowflake corner live**: it polls `NSEvent.mouseLocation` and
hands the mouse back while the pointer is over that 46×34pt corner. Polling rather than a global
mouse monitor, because that API family asks for Accessibility permission and a sticky-note app has
no business doing so. All Notes also offers a thaw, for a note that ends up off-screen.

### 5.7 Movement

`Motion` (windows) and the movement block in `editor.css` (page). Windows use real
`CASpringAnimation` physics. Restoring a deskful at launch animates nothing. Only things that
appear **once** are animated — an image or code block is rebuilt whenever the caret moves on or off
its line. Window **frame** animations overshoot less than layer springs, because a frame is clamped
by `minSize` and a collapse targets exactly that.

The system's Reduce Motion setting switches all of it off, on both sides.

---

## 6. Slash commands, templates, todos, quick open

### 6.1 Slash commands

`/` opens a menu: headings, emphasis, quote, lists, `/checklist`, divider, highlight, link, table,
code (plain and per-language), date, time, tag, colours, `/freeze`, `/find`, `/template`, image,
emoji.

### 6.2 Templates

A template is an **ordinary note carrying a name**: `template: <name>` in the frontmatter. It stays
a note — it lives in folders and appears in lists.

- `/template` names the current note. One word: letters, digits, hyphen, dot, underscore. Anything
  else is stripped, because the name has to be parsed back out of `@name` in a note's text.
- `@name` anywhere recalls it; the completion inserts the whole body.
- All Notes has a templates tab (§8.2) with multi-select, move-to-folder and delete.

### 6.3 Todo notes and reminders

A todo note is one tagged `todo` or written starting `@Todo`. New todos start `@Todo ` with a greyed
"todo title" hint; Enter after the title creates the first checkbox.

**`@todo` typed anywhere converts** an existing note: `@Todo` goes to line 1 with the hint, the
typed text is removed, the view scrolls to the title, and Swift adds the `todo` tag.

`@` therefore means two things, and the collision is resolved explicitly: **line 1's own `@Todo`
marker is never a template recall**, and `todo` is a **reserved template name**.

**Reminders.** A todo's action bar carries a bell; its popover holds three controls and nothing
else — when it is due, whether to announce at the time, and whether to announce earlier by a count
of minutes/hours/days, and **Done closes it**. The date field is AppKit's `NSDatePicker`, not
SwiftUI's `DatePicker`, and the chosen date is held in a reference outside SwiftUI's state: writing
state on each keystroke re-rendered the panel, which threw away a half-typed entry (`37` became `7`)
and took the keyboard out of the field. Dates live in the frontmatter so a reminder travels with the note.
Notifications go through `UNUserNotificationCenter`, are re-armed at launch, and are **cancelled
when the note is deleted**. Permission is asked the first time a reminder is *set*, never at launch.
A moment already past is dropped rather than scheduled.

**Progress.** A todo's action bar shows one square per task — bright and glowing for done, dark for
not — then `3/7`. The squares **wrap at six to a row** and take as many rows as the tasks need,
thickening the bar; there is no cap. The tracker appears the moment the first checkbox is typed,
without reopening the note. On a note too narrow for six squares, the count goes first and then
squares come off the row, in that order; the tracker itself is never hidden and neither are the
tags. A note counts as *done* only when it **has** tasks and all are ticked.

### 6.4 `/find` — quick open

A search box over the middle of the note, focused immediately, fuzzy-matching every note as you
type. Arrows walk, Return opens, Escape closes. A title match always outranks a body match.

**Opening a note does not take you there.** The other note appears and pulses, but the key window
stays the one you were typing in and the caret returns to the character it was on.

---

## 7. Images and links

### 7.1 Pasting

Pasted, dropped and picked images are written into `attachments/` and linked. "Link in place"
(Settings → Editor) points at the original instead and is never rewritten.

### 7.2 Editing in place

There is **no dialog**. Click an image and it grows four corner handles, plus a crop tool and a bin
that sit **outside** the picture, above its top-right corner (below it when the image is at the very
top of a note). Drag a corner to resize — nothing to type. The display width is written into the
link as `![alt|320](path)`, the Obsidian convention, so the file stays ordinary Markdown.

Cropping frames a rectangle on the picture itself; Return applies, Escape cancels. Swift does the
pixels and writes a **new** attachment, repointing the link, so the original is never overwritten
(and can be reclaimed with §9's unused-attachment sweep).

**`ImageEditing.png` takes crop rects in image PIXELS with a bottom-left origin, but
`draw(in:from:)` reads `from` in the image's POINT space.** The conversion is not optional: without
it a crop of any Retina image came out black. Test the *content* of a 2× crop, never just its size.

### 7.3 Link previews

**Off by default. The only feature that contacts a website.**

A URL alone on a line becomes a card with the page's title, description, thumbnail and domain.
The fetch happens in **Swift**, never in the page — the CSP still says `connect-src 'none'`, so
plugins gain nothing. http/https only; credentials and fragments stripped; redirects to any other
scheme refused; ephemeral session, no cookies; 8s timeout and hard size caps. The thumbnail is
downscaled into the vault and loaded from disk.

Hovering shows a ✕ that restores the plain URL. That dismissal is remembered in
`.pintack/linkpreviews.json`, not in the note, and is **forgotten once the link leaves the note** —
the ✕ hides the card that is there, not that address forever.

---

## 8. Central window ("All Notes")

### 8.1 Layout

A sidebar with four **glyph** tabs — folder, `#`, `@` (todos), cube (templates) — a search field, a
list, and a footer. The Settings gear sits at the sidebar's bottom-left corner.

### 8.2 Tabs

- **Folders / Tags** — the note list, with check-boxes, reveal, rename and delete per row, and
  bulk move/delete/export/import.
- **Todos** — every todo note with a checkbox that finishes the whole note, its title (with the
  `@Todo` marker stripped), a one-line preview, progress squares and `3/7`, and its due date.
  Sorted by date created, most done, least done, or due date. Under the due-date sort, notes with
  **no** date sort last: no date is not the same as overdue. "Show done todos" strikes them through
  rather than hiding them.
- **Templates** — every template, with multi-select, Add to Folder and Delete selected.

### 8.3 Quick capture

"New PinTack Note" appears in **any** app's Services menu when text is selected; ⌥⌘C captures the
clipboard. Neither needs Accessibility permission — the Services entry receives the selection
because the user chose the menu item. **Never** implement this by synthesising ⌘C into another app;
that needs Accessibility, and this app must not ask for it.

The capture records which app it came from. `NSServices` is why the app uses a real
`PinTack/Info.plist` rather than a generated one: `INFOPLIST_KEY_*` cannot express an array of
dictionaries.

---

## 9. Settings

Seven panes in a sidebar (a `TabView` overflowed into a "»" menu and looked unfinished):
Appearance, Notes, Shortcuts, Editor, Vault, Plugins, About.

App chrome uses the fixed `Brand.accentNS`, **never** the user's outline colour — a dark outline
once made Settings unreadable.

Editor pane covers default mode, spellcheck, slash commands, image handling, bullet, inline-code
background colour and opacity, rich-text paste, and link previews.

Vault pane holds the location, move, export/import, and **Find unused attachments**. That sweep
reads the `.md` files **on disk** rather than the notes held in memory — a note that failed to load
would otherwise have its pictures offered for deletion — and refuses to act at all when it read
zero notes, because with nothing to compare against every attachment looks unused.

---

## 10. Global hotkeys

### 10.1 Mechanism

Carbon `RegisterEventHotKey`, the only way to get a true system-wide hotkey without Accessibility
permission. Every registration's `OSStatus` is logged; the first draft failed silently.

In-app shortcuts use a local key monitor, because notes are non-activating and the menu bar is not
shown while typing in one.

**One press arrives twice.** AppKit gives the event to the local monitor as an *observer* (which
cannot consume it), then the same `sendEvent:` carries it to the main menu's key equivalent.
`ActionRouter` de-dupes on the **identity of the originating `NSEvent`**, not on elapsed time: a
slow action (an animated collapse) used to outlast a time window and the note toggled straight back.

### 10.2 Bindings

Global (work from any app): New note ⌥⌘N, New todo ⌥⌘L, New note from clipboard ⌥⌘C, All Notes ⌥⌘H,
All Notes by tag ⌥⌘T, Todos ⌥⇧T, Templates ⌥⇧2, Auto-arrange ⌥⌘A, Show all on desktop ⌥⇧=.

App-scoped (a PinTack window must be key): Pin ⌥⌘P, Collapse ⌥⌘K, Close ⌥⌘W, Mode ⌥⌘M, Freeze ⌥⌘F,
Delete ⌥⌘D, Emoji ⌥⌘E, colours ⌥⌘1–6, corners ⌥⌘R, opacity ⌥⌘, / ⌥⌘., export ⌥⌘X, import ⌥⌘I,
shortcut list ⌥⌘/.

Everything acting on **one note** stays app-scoped. A system-wide key that bins whatever note
happens to be focused is not a thing to hand out. Rebindable in Settings, stored in
`.pintack/hotkeys.json`, conflicts detected.

Note: `⌥⇧` combinations normally type dead keys, so registering them globally takes those
characters away from every app.

---

## 11. Widget — NOT BUILT

A WidgetKit widget with tickable checkboxes is designed but **not implemented**. It is shelved
pending a signing-team decision, because an app group is required to share the vault and:

### 11.2 App group Team ID prefix

On macOS an app group identifier **must** carry the Team ID:

```
TEAMID.group.io.cymentix.pintack     ✅
group.io.cymentix.pintack            ❌ silently kills the widget
```

An unprefixed identifier is rejected by `containermanagerd`, the widget process exits immediately,
and the widget never appears in the gallery with no useful error. **Resolve the app group at
runtime from the app's own entitlements**; the Team ID changes when moving from a free personal
signing team to the paid programme.

---

## 12. Plugin API

JavaScript plugins in `<vault>/plugins/<id>/`: `manifest.json`, `main.js`, optional `styles.css`.
No build step, no marketplace. `docs/PLUGINS.md` is the author's guide.

### 12.1 Security model

Every privileged call goes through `PluginBridge.handle`: **capability token** (per plugin, per web
view) → **declared permission** → for commands, the native approval sheet (§13.4). Never add a path
that skips a step.

Plugins share one JavaScript realm inside a note, so they are **not** isolated from each other. The
boundary is on the Swift side. Do not claim more than that.

### 12.2 Settings

A plugin's manifest declares settings; PinTack draws the form. Values are stored in `settings.json`
under the plugin's id, so a plugin id may not collide with an app setting name.

### 12.3 Events

`note:open`, `note:save`, `note:close`, `note:rename`, `vault:change`. Vault changes are debounced
so a burst of file events arrives as one.

### 12.4 Commands

Plugins register commands that appear in Settings → Shortcuts and can be bound to a key, stored
under `plugin:<key>` in `hotkeys.json`.

---

## 13. Runner (reference plugin)

Bundled. Renders ```` ```runner ```` blocks as buttons that run a command, open a URL, reveal a
path, or run a Shortcut. It uses **only** the public API — the core has no private hooks for it,
and it must stay that way.

### 13.4 Trust — there is no autorun

1. **No autorun, ever.** A command runs only after a physical click.
2. **A native approval window** shows the exact text, folder and shell. It is drawn by PinTack, not
   the page, so no plugin can answer it. **There is no setting, flag or environment variable that
   skips it.** Tests inject a fake presenter; the self-test seeds approvals through `TrustStore`.
3. Approval is bound to the exact command text **and** its working folder.
4. Approvals are HMAC-signed with a per-Mac secret kept **outside** the vault, so a `trust.json`
   arriving through sync can never pre-approve anything.
5. Text that could render differently from how it executes (escapes, NUL, RTL overrides) is refused
   before reaching the window.

### 13.5 GUI apps do not inherit shell PATH

Launched from the Dock, `python3` will not resolve even though it works in Terminal. Runner
executes through the user's **login shell**:

```swift
let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
process.arguments = ["-lc", command]
```

---

## 14. Import and export

Export all notes as a JSON archive; import one back. Import is defensive about paths — an archive
is untrusted input and must not be able to write outside the vault.

---

## 15. Build, verify and distribution

```bash
xcodebuild -scheme PinTack -configuration Debug SYMROOT="$PWD/build" build
scripts/verify.sh          # unit tests AND the self-test; both must pass
open build/Debug/PinTack.app
```

**Always build into `build/`.** A second copy in DerivedData makes LaunchServices list PinTack
twice in Spotlight and can serve a stale icon.

### 15.1 Verification

Two layers:

- **Unit tests** (`PinTackTests/`) — frontmatter round-tripping, unknown-key preservation, atomic
  writes, import safety, search, image maths, reminders, templates, plugin security. The plugin
  security tests were mutation-checked: skipping approval, ignoring the token's page, and accepting
  unsigned trust all fail them.
- **The self-test** (`Support/SelfTest.swift`, Debug only) — the app launches, drives its own
  windows and web views with real events, and **asserts**. It exits non-zero on any failed check.
  It renders PNGs of everything as evidence. If you add behaviour, add a check: a fact that is only
  logged is a fact nobody will notice going wrong.

### 15.2 App icon

An **Icon Composer** document, `PinTack/AppIcon.icon`. Do not go back to an `AppIcon.appiconset`:
modern macOS shrinks a legacy icon into a dark system plate. The plate cannot be made transparent
(an alpha-0 fill still renders opaque), and in the Dark icon style the system forces it dark for
every app. The art is full-bleed so no plate shows in the Default style.

Never set `NSApp.applicationIconImage`: it made the Dock show one icon and swap to another.

### 15.3 Distribution — PARTLY BUILT

`scripts/make-dmg.sh` builds a universal (arm64 + x86_64) Release app and packages a DMG with a
custom background and layout.

**Not built:** Developer ID signing, notarization, Sparkle updates, the Homebrew cask, App Sandbox.
Until notarization exists, Gatekeeper blocks the first launch on another Mac; the DMG carries a
note explaining the three ways past it.

---

## 16. Build plan — where things stand

| Phase | Scope | State |
|---|---|---|
| 1 | Shell, vault, note panels, hotkeys | **Done** |
| 2 | WKWebView + CodeMirror, Live Preview, slash commands, image paste | **Done** |
| 3 | All Notes, FTS5 search, folders/tags, settings, import/export | **Done** |
| 4 | Widget, plugin API, Runner | Plugins and Runner **done**; widget **shelved** (§11) |
| 5 | Signing, notarization, Sparkle, DMG, Homebrew | DMG only |

---

## 17. Open decisions

- **Signing team** — free personal vs paid Developer Program. Blocks the widget (§11.2),
  notarization and Sparkle.
- **App Sandbox** — needs a security-scoped bookmark flow for the vault; deferred.
- **Memory at scale** — one web view per open note (§2.1) is unmeasured beyond ~10 notes.
- **JavaScript tests** — roughly 2,000 lines of editor JS have no automated coverage. A test runner
  would be a new dependency; assertions could instead run inside the self-test's web view.

---

## 18. Assets

- `PinTack/AppIcon.icon` — app icon (Icon Composer document)
- `Assets.xcassets/Pushpin` — the pinned-note pushpin PNG
- `Editor/icons/` — language logos, Devicon (MIT), vendored
- `Editor/vendor/` — CodeMirror 6 and Lezer, all MIT, vendored
- `docs/assets/` — icon sources and the original HTML prototype

## 19. Contributing

Conventional commits (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`), one logical change each,
small — the owner's practical undo is `git revert`. Comment the **why**, never the **what**; any
workaround for a platform constraint must name the constraint and cite its section here.

Tests are required for anything that parses or writes vault files. Frontmatter round-tripping,
unknown-key preservation and atomic writes are the three places a bug means data loss.
