# PinTack — Technical Specification

**Version:** 0.1 (pre-implementation draft)
**Status:** Design complete, no code written
**Target platform:** macOS 14 (Sonoma) and later
**License:** GPL-3.0-or-later
**Bundle identifier:** `io.cymentix.pintack`

---

## 0. How to read this document

This document is written so that a macOS developer who has never spoken to the project owner can pick it up and start building. Every decision that has already been made is stated as a decision, with the reasoning attached. Every decision that is still open is collected in Section 17.

The project owner is not a Swift developer. He is a Windows endpoint automation engineer who paid for a commercial sticky-notes app, documented a list of missing features, received no response from its developer, and decided to build the open-source replacement instead. He is funding the Apple Developer membership and owns product direction. He is explicitly looking for a technical maintainer to own the codebase.

---

## 1. What PinTack is

A macOS sticky-notes application where notes are floating desktop windows and the underlying storage is a folder of plain Markdown files.

The one-line pitch: **Obsidian's editing model, applied to sticky notes.**

Three things define it against everything else in the category:

1. **Live Preview markdown.** Formatting renders as you type, with raw syntax revealed only on the line holding the cursor. This is the primary quality bar for v1. If Live Preview feels janky, the product has failed regardless of what else ships.
2. **An interactive desktop widget.** Tick a checkbox on a WidgetKit widget without opening the app. No competitor in this category has one.
3. **A real plugin system.** JavaScript plugins with a documented API, shipping with one reference plugin (Runner) that proves the API is load-bearing rather than decorative.

### 1.1 Why it exists

The incumbent (`Stickies — Sticky notes app`, App Store id 1572061218) is a well-executed, actively maintained, 4.2-star app sitting around #58 in Productivity. It is also roughly 377 MB, which strongly indicates an Electron or similarly heavy runtime. That single fact explains why its most-requested features have never shipped:

- WidgetKit widgets are effectively impossible from Electron without a separate native target
- CloudKit sync is native-only
- True `NSWindow` level manipulation, non-activating panels, and window-level opacity are awkward through Electron's window abstraction

PinTack going native is therefore not a stylistic preference. It is the thing that makes the requested feature set possible at all. Expected bundle size is 10–25 MB.

### 1.2 Non-goals for v1

Explicitly out of scope, listed so nobody builds them by accident:

- Cloud sync of any kind (the vault format makes third-party sync work without code)
- Any platform other than macOS
- Note linking, backlinks, or a graph view
- A plugin marketplace or in-app plugin browser
- Collaboration or multi-user features
- Encryption
- Mac App Store distribution (impossible while Runner exists — see §15.1)

---

## 2. Architecture overview

```
┌─────────────────────────────────────────────────────────────┐
│  Swift / AppKit shell                                        │
│                                                              │
│  ┌────────────────┐  ┌──────────────┐  ┌─────────────────┐  │
│  │ NotePanel      │  │ MenuBarExtra │  │ Central window  │  │
│  │ (NSPanel × n)  │  │              │  │ (folders/tags)  │  │
│  └───────┬────────┘  └──────────────┘  └─────────────────┘  │
│          │                                                   │
│  ┌───────▼─────────────────────────────┐  ┌──────────────┐  │
│  │ WKWebView  →  CodeMirror 6          │  │ Settings     │  │
│  │ (Live Preview editor + plugin host) │  │              │  │
│  └───────┬─────────────────────────────┘  └──────────────┘  │
│          │  JS bridge (WKScriptMessageHandler)               │
│  ┌───────▼──────────────────────────────────────────────┐   │
│  │ VaultStore — file I/O, FSEvents watcher, search index │   │
│  └───────┬───────────────────────────────────────────────┘  │
└──────────┼──────────────────────────────────────────────────┘
           │  App Group container (read-only for widget)
┌──────────▼──────────────────────────────────────────────────┐
│  WidgetKit extension + AppIntents                            │
└──────────────────────────────────────────────────────────────┘
           │
┌──────────▼──────────────────────────────────────────────────┐
│  ~/Documents/PinTack/  — the vault (plain files on disk)     │
└──────────────────────────────────────────────────────────────┘
```

### 2.1 The WKWebView decision

**This is not Electron.** Electron bundles an entire Chromium build, which is why the incumbent is 377 MB. `WKWebView` uses the WebKit already present in macOS. Nothing is bundled.

The editor runs inside a `WKWebView` because CodeMirror 6 is the only realistic path to Obsidian-grade Live Preview. CM6's decoration and view-plugin API is precisely the mechanism Obsidian uses for the same effect. Reimplementing that in TextKit 2 is possible but represents many months of specialist work.

The webview additionally provides the plugin execution context for free, which resolves three problems at once:

- JS plugins sandbox cleanly; Swift plugins would mean loading arbitrary dylibs, breaking App Sandbox and complicating notarization
- Custom CSS themes (a stated plugin goal) require a CSS-rendered surface to exist
- The contributor pool for JavaScript is orders of magnitude larger than for macOS-specific Swift

**One webview per note, or one shared?** Recommendation: one `WKWebView` per open note, sharing a single `WKProcessPool` and `WKUserContentController` so plugin scripts load once. Measure memory with 30+ notes open early in Phase 2; if it is unacceptable, fall back to a pooled-webview model where only focused and recently-focused notes hold a live editor and the rest render a static snapshot.

---

## 3. The vault

### 3.1 Principle

**The folder is the database.** There is no proprietary store. Every note is a real `.md` file the user can open in any editor. This single decision resolves several requirements at once:

| Requirement | How the vault resolves it |
|---|---|
| Export | The files *are* the export. Zip the folder. |
| Sync | Put the vault in iCloud Drive / Dropbox / Syncthing. No sync engine needed. |
| Image paste | Write a file to `attachments/`, insert a standard Markdown image reference. |
| Plugin data access | Plugins read and write files; no API round-trip required. |
| Data longevity | If the project dies, every user still opens their notes in any text editor. |

That last point is not sentimental. For a project whose origin story is "the incumbent abandoned my feature requests," shipping a format that traps users would be incoherent.

**Cost:** no SQL. Search requires an in-memory index built at launch and maintained by an FSEvents watcher. This is bounded, well-understood work. See §3.6.

### 3.2 Layout

```
~/Documents/PinTack/
├── .pintack/
│   ├── index.sqlite            # derived; safe to delete, rebuilt on launch
│   ├── settings.json           # app settings
│   ├── trust.json              # Runner command approvals (see §13.4)
│   └── hotkeys.json            # user keybindings
├── attachments/
│   ├── 2026-09-19-142233.png
│   └── 2026-09-19-150114.png
├── plugins/
│   └── runner/
│       ├── manifest.json
│       ├── main.js
│       └── styles.css
├── Work/                       # a folder is a directory
│   ├── 2026-09-19-sprint-blockers.md
│   └── 2026-09-20-oncall-handoff.md
├── Personal/
│   └── 2026-09-18-groceries.md
└── 2026-09-19-quick-note.md    # root-level note, no folder
```

Design notes:

- **Folders are directories.** One note lives in exactly one folder. Nesting is permitted; the central window renders the tree.
- **`.pintack/` is derived or app-local state only.** Deleting it must lose no user content. Anything in there that cannot be regenerated is a bug.
- **`attachments/` is flat** with timestamp-based names. A per-note subfolder scheme was considered and rejected: it breaks when notes are renamed or moved, and it makes orphan detection harder.

### 3.3 Note file format

```markdown
---
id: 01J9X2K3M4N5P6Q7R8S9T0V1W2
created: 2026-09-19T10:22:38Z
modified: 2026-09-19T11:04:12Z
tags: [work, urgent]
pinned: true
color: "#FFE38A"
theme: auto
opacity: 0.92
collapsed: false
visible: true
frame:
  x: 320
  y: 180
  w: 280
  h: 210
---

# Sprint blockers

- [x] Cert renewal on the build agent
- [ ] Graph throttling on bulk device query
- [ ] Autopilot profile drift

![](attachments/2026-09-19-142233.png)
```

**Frontmatter schema:**

| Key | Type | Default | Notes |
|---|---|---|---|
| `id` | ULID string | generated | Canonical stable identity. ULID rather than UUID: lexicographically sortable and carries a creation timestamp. |
| `created` | ISO-8601 UTC | file ctime | |
| `modified` | ISO-8601 UTC | file mtime | Written on save; used for conflict detection against external edits. |
| `tags` | array of strings | `[]` | Canonical tag store. See §3.5. |
| `pinned` | bool | `false` | Drives `NSWindow.level`. |
| `color` | hex string | app default | Any hex. Presets are a UI convenience, not a constraint. |
| `theme` | `auto`/`light`/`dark` | `auto` | Per-note **palette mode**: which set of preset swatches the Appearance popover offers (standard, deeper, or paler). Text color is never a user choice: it always flips light/dark from the color's luminance. *(Changed from "text treatment override" by the owner, 2026-09-19.)* |
| `opacity` | float 0.3–1.0 | `1.0` | Maps to `NSWindow.alphaValue`. Floor of 0.3 prevents an invisible, unrecoverable note. |
| `collapsed` | bool | `false` | |
| `visible` | bool | `true` | `false` means the note exists but has no open window. |
| `frame` | object | auto-placed | **Card rect, not window rect.** See §5.2. |

**Unknown frontmatter keys must be preserved verbatim on write.** Plugins will add their own keys. Dropping them is data loss.

**Parser requirement:** YAML frontmatter is delimited by `---` on the first line and the next `---` on its own line. A file with no frontmatter is still a valid note; missing keys take defaults and are written on first save.

### 3.4 Filenames

Format: `YYYY-MM-DD-slugified-title.md`

- Generated **once at creation** from the first heading or first line of body text, or `untitled` if empty
- **Never auto-renamed afterward.** Retitling a note does not move the file. This avoids breaking anything referencing the path and avoids surprising the user's sync client with churn.
- Slug rules: lowercase, ASCII alphanumerics and hyphens, all other characters collapsed to hyphens, repeated hyphens collapsed, trimmed, truncated to 60 characters
- Collisions get a `-2`, `-3` suffix
- Rationale: Obsidian-style title-as-filename makes a vault browsable in Finder but breaks on duplicate titles and on `/` and `:`. Pure UUID filenames are stable but render the vault unreadable, which undercuts the entire plaintext premise. The date prefix plus a frozen slug gets both.

The `id` in frontmatter, not the filename, is the canonical identity. Everything internal references `id`.

### 3.5 Tags

Tags are stored in **two** places and this is deliberate:

- **Frontmatter `tags:` array** — canonical, authoritative
- **Inline `#tag` in body text** — indexed, and on save any inline tag not already present is merged into the frontmatter array

This matches how people actually write. Someone typing `#urgent` mid-sentence expects it to become a tag; someone managing tags in a properties panel expects the array. Both work.

Tag rules: case-insensitive for matching, stored as typed. Nested tags via `/` (e.g. `work/northwind`) are indexed as both the full path and each ancestor.

### 3.6 Search index

- SQLite FTS5 at `.pintack/index.sqlite`
- Built on first launch by walking the vault; progress shown if it takes more than ~500 ms
- Maintained incrementally by an `FSEvents` stream on the vault root
- Schema: `notes(id, path, title, body, tags, folder, modified)` plus an FTS5 virtual table over `title` and `body`
- **The index is disposable.** If it is missing, corrupt, or from an older schema version, delete and rebuild. Never block startup on it and never treat it as a source of truth.

### 3.7 External edits

The vault is user-visible, so files will change underneath the app. Required behavior:

- FSEvents watcher detects the change
- If the note has no unsaved in-app edits, reload it silently and re-render
- If it does, compare `modified` in frontmatter against the on-disk value and present a non-destructive conflict resolution (keep mine / keep theirs / open both). **Never silently overwrite.**
- Debounce watcher events by ~200 ms; sync clients write in bursts

---

## 4. Editor: Live Preview

The highest-risk and highest-value component. Budget accordingly.

### 4.1 Behavior

Three modes, but only two are user-facing:

| Mode | Behavior | Toggle |
|---|---|---|
| **Live Preview** (default) | Formatting renders inline. Raw syntax is revealed only on the line containing the cursor. | Title bar pencil/book |
| **Source** | Raw markdown everywhere. Escape hatch for fighting the renderer. | Title bar pencil/book |
| Reading | Fully rendered, non-editable. | Not exposed in v1. |

The title bar glyph is a pencil in Source mode and a book in Live Preview mode, indicating *what you will switch to*.

### 4.2 Implementation

CodeMirror 6 with:

- `@codemirror/lang-markdown` for parsing
- A custom `ViewPlugin` producing `Decoration` sets that replace or hide syntax tokens outside the cursor's line
- `atomicRanges` so arrow-key navigation steps over hidden syntax cleanly rather than into invisible characters
- Widget decorations for block-level elements: images, code blocks, tables, and plugin-contributed blocks such as Runner

Elements that must render in Live Preview for v1:

headings, bold, italic, strikethrough, inline code, fenced code with syntax highlighting, blockquote, bullet and numbered lists, task checkboxes (clickable), horizontal rule, links, images, tables, `==highlight==`, and inline HTML `<span style="color:…">` for text color.

### 4.3 Text color caveat

Markdown has no syntax for colored text. Highlight uses `==text==`, which Obsidian supports and which degrades to visible marks elsewhere. Arbitrary color requires inline HTML:

```html
<span style="color:#e07b39">text</span>
```

This is valid Markdown and renders in most viewers, but it is the one place where notes stop being pure portable plaintext. Accepted trade.

### 4.4 The Swift ↔ JS bridge

JS to Swift, via `WKScriptMessageHandler` on a single handler named `pintack`:

```js
window.webkit.messageHandlers.pintack.postMessage({
  type: "content.changed",
  noteId: "01J9X…",
  payload: { body: "…" }
})
```

Message types (v1):

| Type | Direction | Purpose |
|---|---|---|
| `content.changed` | JS → Swift | Debounced body update; triggers save |
| `title.changed` | JS → Swift | First heading changed |
| `image.paste` | JS → Swift | Pasted image data; Swift writes the file and returns the path |
| `image.pick` | JS → Swift | Slash command requested Finder picker |
| `link.open` | JS → Swift | External URL clicked |
| `command.invoke` | JS → Swift | Plugin command dispatch (e.g. Runner execute) |
| `plugin.host` | both | Namespaced plugin messaging (see §12.4) |
| `note.load` | Swift → JS | Initial or reloaded content |
| `settings.changed` | Swift → JS | Theme, font, accent color updates |
| `command.result` | Swift → JS | Async result of a `command.invoke` |

Swift to JS via `evaluateJavaScript` calling into a `window.__pintack.receive(msg)` entry point.

**Security:** the webview loads only local content. `WKWebViewConfiguration` must disallow navigation to remote URLs; all external links route through `link.open` and open in the default browser. No remote script may ever be loaded, including by plugins.

### 4.5 Saving

- Debounce 800 ms after the last keystroke, plus an immediate save on window blur, note close, and app termination
- Atomic write: write to a temp file in the same directory, then `FileManager.replaceItem`. A partial write must never be able to corrupt a note.
- Update `modified` in frontmatter on every save

---

## 5. Note windows

### 5.1 Panel configuration

Each visible note is one `NSPanel` subclass:

```swift
styleMask: [.borderless, .resizable, .nonactivatingPanel]
isFloatingPanel = true
level = pinned ? .floating : .normal
collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
hidesOnDeactivate = false
isMovableByWindowBackground = true
backgroundColor = .clear
isOpaque = false
hasShadow = false        // see §5.2
```

`canBecomeKey` must be overridden to return `true`, otherwise a borderless non-activating panel cannot accept text input.

`.nonactivatingPanel` is deliberate: clicking into a note to type should not pull the whole app forward and displace whatever the user was doing. This is a large part of what makes it feel like a sticky note rather than a document window.

### 5.2 The transparent margin

**This is the least obvious structural decision in the project and it must be understood before any window code is written.**

macOS windows clip content to their bounds. The design calls for a skeuomorphic pushpin overhanging the top-left corner and an outer glow bleeding past the card edge. Neither can be drawn at the edge of the window.

Therefore: **the `NSWindow` is larger than the visible card.** A transparent margin of **24 pt on all sides** surrounds the card. The card is drawn inset within it; the pin and glow occupy the transparent zone.

Four consequences, all mandatory:

1. **Custom hit testing.** A transparent region still receives clicks. Without intervention, every note carries an invisible 24 pt halo that swallows clicks meant for the desktop or the app beneath. The content view must override `hitTest(_:)` to return `nil` for points outside the card's rounded rect, with the pin's own bounds carved back in as clickable.

2. **`hasShadow = false`.** The system draws its shadow on the window rect, which is the transparent box. The card's drop shadow and the pinned glow are both drawn manually in the content view.

3. **Frame math uses the card rect.** The `frame` stored in frontmatter is the card, not the window. Window frame = card frame inset by −24 on all sides. Auto-arrange, cascade placement, and screen-bounds clamping all operate on the card rect. Getting this wrong makes every note drift 24 pt on each relaunch.

4. **Title text inset.** ~34 pt of left padding so the pin never overlaps the title.

### 5.3 Card chrome

```
        ┌─────────────────────────────────────────┐
   📌   │                                          │
   ╱    │  Sprint blockers        ✏️   ▾    ✕      │  ← title bar
  ┌─────┴──────────────────────────────────────────┤
  │                                                │
  │  # Sprint blockers                             │
  │  - [x] Cert renewal on the build agent         │  ← CodeMirror
  │  - [ ] Graph throttling                        │
  │                                                │
  ├────────────────────────────────────────────────┤
  │  🎨        🏷 work, urgent                  ◢  │  ← footer
  └────────────────────────────────────────────────┘
```

**Title bar:** overhanging pin at top-left (pinned notes only), title text (editable in place), then pencil/book mode toggle, collapse chevron, close.

**Right-click anywhere on the title bar** opens a context menu: Pin/Unpin, Collapse/Expand, Minimize to All Notes, Duplicate, Move to folder…, Close, Delete.

**Footer — three controls, plus the action bar.** *(The action bar was added by the owner on 2026-09-19.)* A `>` next to 🎨 opens the action bar: bullet list (right-click to choose an emoji bullet, or clear it), bold, italic, code, and an opacity slider. It can collapse itself again after a delay (Settings → Notes). An earlier design put six color swatches, an opacity slider, an emoji button and a todo button in the footer; at a 280 pt default width they overlapped and were unusable. The insight that fixes it: **color and opacity are set-and-forget properties, not per-session controls.** They do not deserve permanent real estate.

| Control | Behavior |
|---|---|
| 🎨 Appearance | Opens a popover: an Auto / Dark / Light mode switch, 6 preset swatches for that mode (Dark shows deeper versions, Light paler ones; a preset carries across the switch), a "Custom…" well opening `NSColorPanel`, and the opacity slider with live percentage |
| 🏷 Tags | Shows current tags; click to edit with autocomplete against existing vault tags |
| ◢ Resize grip | Standard |

Everything formerly in the footer moves to slash commands (§6), which is where it belonged.

### 5.4 Pinned state

Communicated **redundantly**, because "this window will cover other applications" is consequential enough to warrant more than one signal:

- **Skeuomorphic pin**, ~28 pt, overhanging the top-left corner, rotated so the shaft drives down-right into the card. Clicking it unpins, with a short lift-and-fade animation.
- **Outer glow** in the outline color: 10 pt blur, 22% alpha, no spread. Subtle enough that ten pinned notes do not turn the desktop into a carnival.

The outline itself does **not** indicate pinned state, because the user controls outline color and width globally (§9) and it must be free to be purely decorative.

**Pin asset requirements:** PNG at @1x/@2x/@3x (28/56/84 px), transparent background, **contact shadow on a separate layer** so the app can render it responsive to note opacity, plus a light variant for use on dark note colors. Redistribution license must permit commercial use and modification (GPL binary redistribution).

### 5.5 Placement and arrangement

- New notes: at cursor / centered / cascade, per setting. Default cascade with a 24 pt step, reset when it would leave the visible screen.
- Notes are clamped to visible screen bounds on load. A note restored from a frontmatter frame pointing at a disconnected display must be brought back on-screen.
- Auto-arrange: grid layout across the active screen, card rects, 18 pt gutters, preserving z-order.

---

## 6. Slash commands

Typing `/` at the start of a line or after whitespace opens a filtering command menu. This is both the beginner on-ramp (someone who has never written Markdown can build a formatted note entirely by typing `/`) and the most visible proof that the plugin system is real.

### 6.1 Implementation

CodeMirror 6's `autocompletion` with a custom `CompletionSource`. This is configuration of an existing, battle-tested subsystem rather than a bespoke menu.

### 6.2 Core registry

| Command | Inserts |
|---|---|
| `/h1` `/h2` `/h3` | Heading |
| `/bold` `/italic` `/strike` | Inline emphasis around selection |
| `/quote` | Blockquote |
| `/list` `/numbered` `/todo` | Lists |
| `/divider` | `---` |
| `/color` | Color submenu → `<span style="color:…">` |
| `/highlight` | `==text==` |
| `/image` | Opens Finder picker, copies into `attachments/`, inserts reference |
| `/link` | Link with URL prompt |
| `/table` | Table skeleton |
| `/code` | Fenced block with language picker |
| `/date` `/time` | Formatted stamps |
| `/tag` | Tag autocomplete against vault tags |
| `/emoji` | Emoji picker grid |

`/runner` is **not** in this list. It is contributed by the Runner plugin, deliberately, to prove the extension point works.

---

## 7. Image handling

Non-negotiable for v1.

- **Paste** (`⌘V` with image data on the pasteboard): write PNG to `attachments/YYYY-MM-DD-HHMMSS.png`, insert `![](attachments/…)`, render inline immediately
- **Drag and drop** onto a note: same path
- **`/image`**: `NSOpenPanel`, copy into `attachments/`, insert reference
- **Setting:** copy into vault (default) or link in place by absolute path
- Rendered images scale to note width, capped at their natural size
- **Orphan cleanup** in Settings → Vault: scan all notes for attachment references, list unreferenced files, let the user delete them. Never delete automatically.

---

## 8. Central window ("All Notes")

Borrowed from Windows Sticky Notes, then refined twice.

```
┌──────────────────────────────────────────────────────┐
│  All Notes                                      ✕    │
├──────────────┬───────────────────────────────────────┤
│ ○ Folders    │  🔍 Search                            │
│ ○ Tags       │  ┌─────────────────────────────────┐  │
│              │  │ ● Sprint blockers          👁   │  │
│ 🗒 All   24  │  │   Cert renewal on the build…    │  │
│ 💼 Work   8  │  ├─────────────────────────────────┤  │
│ 🏠 Personal 6│  │ ● Groceries                🚫   │  │
│ ✏️ Scratch 10│  │   apples, oat milk, sourdough   │  │
│              │  └─────────────────────────────────┘  │
│              │  [New note]        [Export] [Import]  │
└──────────────┴───────────────────────────────────────┘
```

- **Two view modes, toggled at the top of the sidebar: Folders and Tags.** Folders render the directory tree. Tags render a flat (or nested, for `parent/child`) tag list. The same note appears once under Folders and once per tag under Tags. This is the refinement that makes the window worth opening: "show me everything tagged `urgent` regardless of folder" is the query Windows Sticky Notes cannot answer.
- Live search across title and body via the FTS index
- Per-row eye toggle controls `visible`: hiding closes the note's window without deleting the note
- Clicking a hidden note shows it; clicking a visible note raises and briefly pulses its window
- Drag a note onto a folder to move it (moves the file on disk)

---

## 9. Settings

Seven panes. This is the complete v1 inventory.

### Appearance
- App theme: System / Light / Dark
- Default note color
- Custom color picker (`NSColorPanel`) with **automatic contrast**: text color flips light or dark based on computed background luminance, so no user-chosen color can produce unreadable text
- Corner style: rounded / square
- Default opacity
- Note body font family and size

### Notes
- Outline: on/off
- Outline color (universal, all notes)
- Outline width: 1–3 pt (universal)
- Pinned glow: on/off
- Default note size
- New note placement: at cursor / centered / cascade
- Auto-save interval

**Note:** the outline color is also the accent color for plugin-contributed UI, including Runner's button border and divider. Setting the outline to teal turns Runner buttons teal. This coherence is cheap and makes the app feel like one product rather than a core plus bolt-ons.

### Shortcuts
Every action listed with its default binding and a recorder control. Populated dynamically: plugins registering commands get their own section automatically.

### Editor
- Default mode: Live Preview / Source
- Spellcheck
- Smart quotes and dashes
- Tab inserts spaces / tab
- Slash commands enabled
- Attachment folder name
- Image paste behavior: copy into vault / link in place

### Vault
- Vault location, with "Move vault…" (moves files, reindexes, updates settings atomically)
- Open in Finder
- Export all as JSON
- Import archive
- Attachment orphan cleanup

### Plugins
- Installed plugins with enable/disable toggles
- Open plugins folder
- Per-plugin settings, rendered from each plugin's declared schema
- Runner's pane includes its trust list with per-command revoke

### About
Version, license, GitHub link, contributors, support link.

### 9.1 App theme vs note theme

These are different and must not be conflated. A user may legitimately want dark app chrome with yellow paper notes. The app theme governs windows, panels, the central window and settings. Each note's color and its light/dark text treatment are per-note. The graphite swatch is a note color that happens to be dark; it is not "dark mode."

---

## 10. Global hotkeys

### 10.1 Mechanism

Carbon `RegisterEventHotKey`. This is still the only way to get a true system-wide hotkey on macOS **without** requiring Accessibility permission, and it is fully dynamic: unregister the old combo, register the new one.

`CGEventTap` (which does require Accessibility) is only needed for modifier-free single-key hotkeys. v1 does not support those, and therefore v1 shows no permission prompt.

Either hand-roll a wrapper (~60 lines, fully auditable, no dependency) or use `KeyboardShortcuts` by Sindre Sorhus, which wraps the same API and ships a recorder UI. **Recommendation: use the package.** It is well maintained, solves the recorder UI, and the project has bigger problems to spend effort on.

### 10.2 Defaults

Shipped defaults, all user-rebindable. Chosen to avoid collisions with common system and application shortcuts.

| Action | Default |
|---|---|
| New note | `⌥⌘N` |
| New todo note | `⌥⌘L` |
| Show/hide All Notes | `⌥⌘H` |
| Pin/unpin focused note | `⌥⌘P` |
| Collapse/expand focused | `⌥⌘K` |
| Close focused note | `⌥⌘W` |
| Auto-arrange | `⌥⌘A` |
| Toggle Live Preview/Source | `⌥⌘M` |
| Emoji picker | `⌥⌘E` |
| Note color 1–6 | `⌥⌘1`…`⌥⌘6` |
| Toggle corners | `⌥⌘R` |
| Export all | `⌥⌘X` |

Bindings persist to `.pintack/hotkeys.json`. Conflicts are detected at bind time and surfaced in the recorder.

---

## 11. Widget

The market differentiator. Apple's own Notes widget is read-only; no competitor in this category ships one at all.

### 11.1 Scope

- **Small:** one pinned note's content, or a count of open tasks
- **Medium:** up to 5 open tasks aggregated across notes, each with an interactive checkbox
- **Large:** up to 10 tasks plus one pinned note excerpt

Checking a task via AppIntents (macOS 14+) writes back to the source note file and reloads the timeline.

### 11.2 The App Group trap

**This will silently break the widget if done wrong, and it is the single most likely thing to go wrong in the whole project.**

On macOS, app group identifiers **must be prefixed with the Team ID**. An unprefixed identifier is rejected by `containermanagerd` with "Group containers identifiers should be prefixed by requestor's team ID," and the widget process exits immediately without ever appearing in the widget gallery. This has been observed on Sonoma and again on macOS 26.

Correct form:

```
TEAMID.group.io.cymentix.pintack
```

**Additional hazard:** a free personal signing team has a different Team ID than a paid Developer Program team. Since the Apple Developer membership is deferred until first release (§15), the app group string will change at enrollment, orphaning any container written before then.

**Required mitigation:** resolve the app group identifier **at runtime by reading it out of the app's own entitlements**, with a fallback to any legacy identifier, rather than hardcoding the string. Approximately fifteen lines, and it must be in place from the first commit that touches the group container.

### 11.3 Data path

The widget reads the vault through the App Group container. Two options:

- **A:** vault lives inside the App Group container, symlinked or bookmarked from `~/Documents/PinTack/`
- **B:** the app maintains a small denormalized snapshot (`widget.json`: open tasks, pinned note excerpt) inside the App Group container, refreshed on save

**Recommendation: B.** The widget does not need the whole vault, security-scoped bookmarks across an extension boundary are fragile, and a snapshot keeps widget refresh cheap. Write-back from the widget goes through an AppIntent that targets the main app, which owns all vault writes.

---

## 12. Plugin API

### 12.1 Principles

- Plugins are JavaScript, loaded into the note webview's context
- Plugins are folders in `<vault>/plugins/<id>/`
- v1 installation is "drop a folder in and restart." No marketplace, no in-app browser.
- **The core must not contain private hooks for the bundled plugin.** If Runner needs something the public API lacks, the API gains it publicly. This is the only way the reference plugin proves anything.

### 12.2 Manifest

```json
{
  "id": "runner",
  "name": "Runner",
  "version": "1.0.0",
  "description": "Inline buttons that run scripts or open URLs.",
  "author": "PinTack",
  "minAppVersion": "1.0.0",
  "main": "main.js",
  "styles": "styles.css",
  "permissions": ["process.execute"],
  "settings": [
    { "key": "timeout", "type": "number", "default": 30, "label": "Timeout (seconds)" },
    { "key": "shell", "type": "string", "default": "", "label": "Shell override (blank = login shell)" }
  ]
}
```

`permissions` is declared, surfaced to the user at enable time, and enforced by the Swift side. *(Built set: `process.execute`, `shortcuts.run`, `url.open`, `path.reveal`, `vault.read`, `vault.write`. See docs/PLUGINS.md.)* A plugin without `process.execute` cannot invoke the execution bridge, regardless of what its JS attempts.

`settings` drives an auto-generated settings pane. Values are stored in `.pintack/settings.json` under the plugin id and delivered to the plugin at load.

### 12.3 Lifecycle and surface

```js
module.exports = class RunnerPlugin extends PinTack.Plugin {
  async onload() {
    this.registerMarkdownCodeBlockProcessor("runner", this.render.bind(this))
    this.registerSlashCommand({
      id: "runner",
      name: "Runner button",
      icon: "play",
      insert: "```runner\nlabel: New action\nrun: \n```\n"
    })
    this.registerCommand({
      id: "runner:run-all",
      name: "Run all buttons in note",
      defaultHotkey: null
    })
    this.registerSettingsTab(new RunnerSettingsTab(this))
    this.registerEvent("note:save", this.onNoteSave.bind(this))
  }

  async onunload() { /* teardown; must be complete */ }
}
```

Registration methods for v1:

| Method | Purpose |
|---|---|
| `registerMarkdownCodeBlockProcessor(lang, fn)` | Render a fenced block as a widget decoration |
| `registerMarkdownPostProcessor(fn)` | General render-time transform |
| `registerSlashCommand(spec)` | Appears in the `/` menu |
| `registerCommand(spec)` | Appears in Settings → Shortcuts, bindable |
| `registerSettingsTab(tab)` | Custom settings pane beyond the manifest schema |
| `registerEvent(name, fn)` | `note:open`, `note:save`, `note:close`, `note:rename`, `vault:change` |

Vault access:

```js
this.app.vault.read(noteId)
this.app.vault.modify(noteId, content)
this.app.vault.create(path, content)
this.app.vault.getNotes({ folder, tags })
this.app.vault.getAttachmentPath(filename)
```

Everything routes through the Swift side. **Plugins get no direct filesystem access and no network access.** The webview CSP forbids remote resource loading.

### 12.4 Host bridge

Privileged operations (`process.execute`, file dialogs, opening URLs) are proxied:

```js
const result = await this.app.host.invoke("process.execute", {
  command: "…", cwd: "…", timeout: 30
})
```

Swift verifies the calling plugin's declared permissions before dispatch. A plugin id is bound to its loaded script at registration and cannot be spoofed from JS.

---

## 13. Runner (reference plugin)

Ships enabled with v1. Proves the plugin API is load-bearing and gives the app a genuinely differentiated capability.

### 13.1 Syntax

A fenced block with a `runner` info string. This stays valid Markdown and degrades to a visible, harmless code block in any other editor, which preserves the data-longevity promise.

````markdown
```runner
label: Rebuild search index
run: ~/bin/reindex.py
cwd: ~/projects/thing
```
````

Four action types:

| Key | Behavior | Trust required |
|---|---|---|
| `run:` | Execute a command | Yes |
| `open:` | Open a URL in the default browser | No (equivalent to a plain Markdown link) |
| `reveal:` | Reveal a path in Finder | No |
| `shortcut:` | Run a named macOS Shortcut | Yes |

`shortcut:` is high value for low cost: it hands users AppleScript, HomeKit and the whole Shortcuts automation library without the project implementing any of it.

### 13.2 Button anatomy

```
┌────────────────────────────────────────┐
│  ▶  Rebuild search index    │   <✏️>   │
└────────────────────────────────────────┘
```

- Border and divider use the **universal outline color** from Settings → Notes
- The entire left region (play glyph + label) is the run target
- The label is editable in place; renaming does not require opening the inspector
- The play glyph is required. Without it the control reads as ambiguous and the inspect glyph looks like the primary action.
- The right cell is the inspect target, using the custom `<✏️>` glyph: a pencil between angle brackets, drawn as a single monochrome template asset so it tints with the accent color. **Not a literal emoji** — emoji will not tint, goes mushy at 16 pt, and changes shape across OS releases.

In Source mode the raw YAML is shown; in Live Preview the button is rendered.

### 13.3 Inspector

Opened by `<✏️>`. Shows the exact command, working directory, the shell it will run under, and current trust status. Editable in place; saving writes back to the `runner` block.

**Editing a command resets its trust.** This is what makes the inspector safe rather than a loophole, and it is why the two features fit together.

### 13.4 Trust model

Notes are a transport format. Someone can send a `.md` file or paste content from a website. The moment a note carries an executable button, that is a code execution vector.

- **No autorun, ever.** Execution requires a physical click. There is no flag that changes this.
- **Trust is bound to the exact command string AND its working folder, not the note.** *(Tightened 2026-09-19: the same `./run.sh` in another folder is a different program. Each entry is also HMAC-signed with a per-Mac secret outside the vault, so a synced or shared `trust.json` cannot pre-approve commands. Entries also record `kind` and `cwd`.)* First click shows an approval sheet displaying the precise string to be executed. Approve once, remembered. Change one character, approval resets.
- **Imported and pasted notes start untrusted.** Runner blocks render inert with a "review before running" state rather than a live button.
- **The command is always inspectable from the button.** A friendly label can never conceal what it runs.
- Approvals stored in `.pintack/trust.json` as `{ hash(command) → { command, approvedAt } }`, revocable individually in Settings → Plugins → Runner.

### 13.5 Execution

Language agnostic, as specified: if the dependencies are installed, the script runs; if not, that is the user's problem and the app does nothing about it.

**One real-world trap that must be handled:** GUI applications on macOS do not inherit the shell's `PATH`. Launch PinTack from the Dock and `python3` will not resolve, even though it works in Terminal. Execution therefore runs through the user's **login shell** so `.zprofile` and `.zshrc` are sourced:

```swift
let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
process.executableURL = URL(fileURLWithPath: shell)
process.arguments = ["-lc", command]
```

Dependency management stays entirely the user's responsibility. The app merely gives their scripts the environment they expect.

### 13.6 Output pane

- Rendered below the button, **collapsed entirely when there is no output**
- Default height ~140 pt, drag handle on the top edge, height persisted per note
- Internal scroll, monospace font, so it never reflows the note's own layout
- stderr rendered in a distinct color from stdout
- Header strip: exit code, elapsed time, stop button while running, copy and clear
- Auto-scroll to newest line, pausing the moment the user scrolls up manually
- Default timeout 30 s (configurable), with a visible stop control

---

## 14. Import and export

The vault is already the export, so this is a convenience layer.

- **Export all:** single `.json` containing every note's frontmatter and body, plus attachments base64-encoded. Suitable for moving between machines in one file.
- **Import:** reads the same format, validates structure, and **merges rather than replaces**, keyed on `id`. Conflicts on `id` prompt for keep/replace/duplicate.
- **Folder export:** zip the vault directory. This should be documented in the README as the real backup story.

---

## 15. Build and distribution

### 15.1 Not the Mac App Store

A sandboxed app cannot spawn arbitrary user processes. This is an OS-enforced entitlement boundary, not a policy that can be argued. App Sandbox is mandatory for the Mac App Store. **Shipping Runner therefore rules out MAS distribution.**

GPL-3.0 is independently incompatible with the App Store's terms, so this was settled twice over.

Distribution: notarized DMG, Homebrew cask, GitHub Releases, Sparkle for auto-updates.

Upside: no review queue, no 30% cut, no arguing with a reviewer about a notes app that executes scripts, and plugin distribution stays entirely the project's. Cost: discoverability, which is real when the incumbent sits at #58 in Productivity.

If MAS presence matters later, two build configurations from one codebase (sandboxed MAS build with Runner disabled; full direct build) is roughly a day of CI work. Not for v1.

### 15.2 Signing and notarization

- Apple Developer Program membership ($99/yr) is **unavoidable**, not because of iCloud (cut from v1) but because notarization requires a Developer ID certificate and the App Group entitlement effectively requires paid membership
- **Development requires no paid account.** A free personal signing team runs local builds. The membership is needed only at first public release.
- Individual enrollment, no D-U-N-S, no legal entity
- Succession: when a maintainer takes over, they enroll their own individual account. Nothing transfers because there is nothing to transfer. The signing identity changes, Sparkle handles it, users confirm once.

### 15.3 CI

GitHub Actions on macOS runners: build, test, lint, and on tag, sign, notarize, staple, and publish a DMG plus the Sparkle appcast. Secrets: Developer ID certificate, notarization credentials, Sparkle EdDSA key.

---

## 16. Build plan

Five phases. Each ends in something runnable.

### Phase 1 — Shell and vault (2–3 weeks)
Xcode project, App Sandbox, runtime-resolved App Group, `MenuBarExtra`. `VaultStore`: read/write markdown with frontmatter, FSEvents watcher, atomic writes. `NotePanel` with transparent margin, custom hit testing, manual shadow, drag, resize, pin/unpin, opacity, collapse, context menu. Plain `NSTextView` placeholder editor.
**Exit:** create, edit, move, resize, pin and close notes; content persists as readable markdown; external edits reload.

### Phase 2 — Editor (3–5 weeks, highest risk)
`WKWebView` host, CodeMirror 6, the message bridge, Live Preview decorations, Source toggle, image paste and drop, slash commands.
**Exit:** Live Preview quality matches Obsidian for the element list in §4.2. **This phase gates everything else. If it cannot be made to feel good, the product thesis needs revisiting before more is built on top.**

### Phase 3 — Organization (2–3 weeks)
Central window with Folders/Tags mode toggle, FTS5 index, search, show/hide, drag-to-folder, tag autocomplete, full settings implementation, global hotkeys with recorder, import/export.
**Exit:** feature-complete minus widget and plugins.

### Phase 4 — Widget and plugins (3–4 weeks)
Widget extension with snapshot data path and AppIntents write-back. Plugin loader, manifest parsing, permission enforcement, registration API, host bridge. Runner built strictly against the public API.
**Exit:** widget in the gallery with working checkboxes; Runner installs, runs, and its trust model holds under adversarial testing.

### Phase 5 — Release (2–3 weeks)
Signing, notarization, Sparkle, DMG, Homebrew cask, website, README, plugin authoring docs, icon and asset finalization.

**Total: roughly 3–4 months for one competent macOS developer working steadily.**

---

## 17. Open decisions

| # | Question | Current position |
|---|---|---|
| 1 | One webview per note, or a pooled model? | Start per-note; measure at 30 notes in Phase 2 |
| 2 | `KeyboardShortcuts` package or hand-rolled Carbon? | Package, unless dependency minimalism wins |
| 3 | Widget data: snapshot or full vault access? | Snapshot (§11.3 option B) |
| 4 | Plugin API: match Obsidian's naming closely, or diverge? | Match closely; contributors already know it |
| 5 | Does the plugin non-derivative-work clarification need legal review? | Yes before 1.0, no before first commit |
| 6 | Sparkle key custody during maintainer handoff | Unresolved; decide before first release |

---

## 18. Assets required

Not blockers for code, but blockers for release.

| Asset | Spec | Status |
|---|---|---|
| Pushpin | PNG @1x/@2x/@3x (28/56/84 px), head upper-left with shaft driving down-right, contact shadow on a **separate layer**, light variant for dark notes, redistribution license permitting commercial use and modification | Draft exists; needs mirroring, shadow rebuild, license verification |
| `<✏️>` inspect glyph | SVG or PDF, monochrome template, simplified for 16 pt legibility (silhouette + one body line, no ferrule detail), brackets matched to stroke weight | Draft pencil exists; needs vectorizing and simplification |
| App icon | 1024×1024, Apple rounded-rect grid | **Provisional accepted.** Current asset is 500×500, freeform torn-paper silhouette rather than squircle, and illegible below 48 px (see `docs/assets/icon-size-test.png`). Owner has accepted these knowingly; quality pass deferred. Must be resolved before 1.0. |

---

## 19. Contributing

The project is GPL-3.0-or-later. Plugins communicating solely through the documented public API are not considered derivative works and may be licensed however their authors choose.

The project owner handles product direction, positioning and funding. A technical maintainer owning the codebase is actively sought. Funding, if and when the project warrants it, will run through Open Collective with Open Source Collective as fiscal host, so project funds are never any individual's personal income and admin rights transfer with maintainership.
