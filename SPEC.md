# PinTack — Technical Specification

**Version:** 0.1.0 (build 10) — last brought up to date 2026-09-22
**Status:** Built and running; in beta with testers. Phases 1–4 complete; Phase 5 (signing,
notarization, Sparkle) and the WidgetKit widget are not built — see §11 and §15. `CHANGELOG.md`
records how it got here.
**Target platform:** macOS 14 (Sonoma) and later
**License:** GPL-3.0-or-later
**Bundle identifier:** `io.cymentix.pintack`

> **Product thesis (owner).** PinTack is for short notes on the fly: condensed data, important data,
> or both. It gives developers special attention for snippets that move between tools and
> workflows. It is **not** for knowledge bases, wikis or documentation; Obsidian and similar tools
> exist for those. Every feature in this document should be judged against that sentence.

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
   approved for language logos. `@replit/codemirror-vim` (MIT) and `@codemirror/search` were approved
   for vim mode (§4.6, 2026-09-21).
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
    ├── linkpreviews.json cached previews and dismissals
    └── welcomed, onboarded   first-run markers, empty files
```

### 3.0 First run

The very first launch shows one **welcome card** — a centred dark panel with the icon, six things
worth knowing, the four shortcuts to start with (read from the live bindings), and an **OK** button
that puts it away. Escape does the same. No pages and no "next": it is read once and dismissed.

"Once" is the empty `.pintack/onboarded` file, written when the card is *shown* rather than when it
is dismissed, so a crash before OK does not mean being greeted all over again. It is a file in the
vault, not a preference, for the same reason the welcome note's `welcomed` marker is: the vault is
what the app treats as its own state, and resetting defaults must not bring it back.

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
behind the badge; on a dark panel a dark mark gets a faint light halo instead.

A fenced block is drawn as a **panel of its own**, not a wash of the note's paper: a dark slate
(`#1B1E26` at 92%) on every note, whatever colour the note is. Settings → Editor → Code blocks
changes the colour and how solid it is, exactly like inline code's own background.

Token colours are two palettes chosen by **the panel**, not by the note's paper — a dark panel on a
light note still needs light tokens. Swift composites the panel over the note's colour, works out
which palette that calls for, and sends it as `codePaper`. Neither palette may lean on `--fg` or
`--fg-dim`, and neither may the badge: those follow the note, which is how dark lettering ended up
on a dark block. Inline code keeps its own separate setting and still follows the paper.

**Line numbers in code blocks** are a setting (Settings → Editor → Code blocks), **off** by default.
Each block counts from 1 in a narrow column inside its panel. With vim mode on they give way to the
note's own gutter (§4.6), which numbers every line including the block's, so there is one numbering.

**Blockquotes** carry a bright red bar down their left edge (`--quote-bar`, owner's call).

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

### 4.6 Vim mode

One global switch, Settings → Editor → Vim mode, **off** by default. `@replit/codemirror-vim` (MIT)
supplies vim; `Editor/vim-mode.js` adapts it. The package is **imported the first time vim mode is
switched on**, never with the editor, the same rule as the language parsers.

- **Notes start in NORMAL mode.** `i` types, Esc stops. The mode (NORMAL, INSERT, VISUAL, V-LINE,
  REPLACE) shows as a pill at the right of the action bar. While vim holds the keys, the editor's own
  Enter, Tab and ⌘↩ handlers stand aside (`vimOwnsKeys`); in INSERT they work as usual.
- **`:` and `/` turn the action bar into the command bar** (owner's request). The prompt is not drawn
  in the page: `cm.openDialog` is replaced, and every keystroke in the bar is handed back to the
  engine's own prompt handlers, so incremental search and history (↑/↓) work unchanged. Return runs
  it, Esc (or Backspace on an empty bar) cancels, and the bar goes back to being the action bar.
  Messages such as `E492` show there briefly. Ending an edit in the bar never renames the note.
- **Ex commands:** `:w` saves now, `:q` closes the note, `:wq`, `:x` and `ZZ` do both. A note is one
  buffer: no splits, tabs or `:e`.
- **A line-number gutter** runs down every note while vim is on, so counts and `12G` can be read off
  it. It counts the note's **visible** lines, starting after the hidden frontmatter; a hidden code
  fence keeps its number without showing it, so the numbers stay the ones vim uses.
- **`j` and `k` land on the next line**, and a rendered **table is a fold** (build 10, the owner's
  idea). A table is several lines drawn as one block, so the gutter had no number for it. Now it
  shows its first line number and how many lines it holds, `3 [+3]`, and it behaves as vim's own
  folds do: `j` onto it stands the cursor on the fold (the table is outlined), `j` again steps past
  it, `k` from below lands back on it. `zo` / `za` / a click on `[+]` show its Markdown with real
  numbers and a `[−]` to fold it back; `zc` folds it with the cursor standing on it; `zR` / `zM`
  open or fold every table. Any other way in (`w`, a search, a click on the table itself) opens it
  while the cursor is inside, as before. `dd` or `x` standing on a folded table edits its first row,
  not the whole table. `cm.findPosV` steps one line at a time and clamps, because the engine
  otherwise mistook squashed code fences for folds and jumped them whole.
- **The gutter stays level with the text.** A block widget's margin is not in the editor's height
  map, and a block measured mid pop-in animation was booked at its shrunken size, so every number
  below a table rode ~14px high (owner caught it). Block widgets use padding, their pop-in animates
  what is inside them, and a picture that loads late asks for a re-measure. The self-test measures
  every number against its line.
- **Live Preview is otherwise unchanged**, and pictures are still drawn as blocks. The first time
  vim mode is switched on, a notice in Settings (`VimNotice`, dismissed with Got it, recorded as
  `vimNoticeShown`) says what that means: tables are folds and how to open them; moving onto a
  picture opens its raw Markdown, the note can jump in height, `x` on a picture's first character
  turns it into a link, resizing and cropping still need the mouse, and Source mode (⌥⌘M) is the
  way out.

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

Controls are **13.5 pt glyphs in 24 pt buttons** (26 wide in the action bar), sized in one
`ChromeSize` table that the tracker's room calculation also reads, so layout and arithmetic cannot
drift apart. They were 11 pt in 20 pt buttons, and the snowflake was hard to make out.

**A collapsed todo keeps its progress in the title bar:** a plain progress bar — dull green track,
bright glowing green fill — between the title and the buttons, then `3/7`. A bar rather than squares
because a collapsed note is one line tall. It ignores the mouse, so the header still drags and
renames.

**A finished todo looks finished:** once every box is ticked its title gets a green ✓ and is struck
through, and the note dims to 72% of its own opacity. All of it is drawn, never written: the file
keeps its plain title and its opacity setting.

New notes are **300 × 250 pt** by default, adjustable in Settings. 300 is not arbitrary: it is the
narrowest width at which a todo note's bar can show six progress squares, the `5/14` count and a
tag pill all at once (§5.3).

**Footer — the "action bar":** a palette button, a `>` that opens the formatting tools, and then
either the tools (bullet, bold, italic, code, opacity) or the tag side (tag icon, reminder bell,
task progress, tag pills). The two sides **cross-fade**; only a real open or close animates.

The bar is **32 pt tall plus a row for every extra row of task-tracker squares**, and it grows
**downward**: the window's bottom edge moves and the text area above it never shrinks as a checklist
is typed. The stored card frame is always the plain-bar card, so nothing drifts across relaunches.
A note low on the screen is nudged up rather than grown off it.

Tag pills are coloured from a **djb2 hash of the tag text** — never `hashValue`, which is seeded per
process and would repaint every tag on each launch. They **wrap onto as many lines as the bar is
thick**, but never make it thicker themselves; the ones that still do not fit collapse into a `+N`
pill that opens a popover listing them all. `TagPillsView` is transparent to the mouse so the empty
action bar still drags the note — **except** over that `+N` pill.

**A tag's colour can be picked** in the tag editor: click the dot on a tag's chip and a row of
swatches opens in the popover — Automatic, ten presets and a custom colour. The choice belongs to
the tag, not the note, so it repaints that tag everywhere; it is kept in `settings.json` under
`tagColors`. Because a picked colour can be dark, a pill's lettering is chosen by how light the pill
is rather than always being black.

### 5.4 Pin

⌥⌘P. A pinned note floats above other windows and draws the owner's pushpin PNG, anchored by the
crack in the paper (drawn 40% smaller than the first version, owner 2026-09-22), with a glow in the note's own colour. **Settings → Notes → Glow strength** runs
from 25% to 160%; it is mostly brightness, and the halo never widens past the 24 pt margin, where
the window edge would slice it flat.

### 5.5 Placement

New notes are placed by the configured rule (cursor, centred, cascade) and clamped on screen.
They spring in; closing fades out (§5.7).

**Notes on a display that has gone come back.** At launch a note whose title bar is on no screen is
moved to the main one. While running, a screen-parameters change (a monitor unplugged or
rearranged) rescues every open note that is out of reach, in a short cascade on the main screen,
and saves the new position so the next launch agrees.

### 5.6 Freeze mode

⌥⌘F, `/freeze`, the snowflake in the action bar, or the right-click menu. A frozen note ignores the
mouse entirely and sits on the desktop as a reference card.

**The way out matters more than the way in.** A window that ignores the mouse cannot be clicked to
un-ignore itself, cannot be right-clicked, and can never become key — so no shortcut reaches it.
`FreezeMode` therefore keeps the **snowflake live**: it polls `NSEvent.mouseLocation` and hands the
mouse back while the pointer is over the snowflake button itself, with room around it. It used to
be a fixed box at the card's bottom-right, which stopped covering the snowflake once a todo's bar
grew tracker rows and lifted the controls to its top row. Polling rather than a global
mouse monitor, because that API family asks for Accessibility permission and a sticky-note app has
no business doing so. All Notes also offers a thaw, for a note that ends up off-screen.

### 5.7 Movement

`Motion` (windows) and the movement block in `editor.css` (page). Windows use real
`CASpringAnimation` physics. Restoring a deskful at launch animates nothing. Only things that
appear **once** are animated — an image or code block is rebuilt whenever the caret moves on or off
its line. Window **frame** animations overshoot less than layer springs, because a frame is clamped
by `minSize` and a collapse targets exactly that.

The system's Reduce Motion setting switches all of it off, on both sides.

**Window opacity and frame animations run on our own clock.** AppKit's window animator
(`window.animator().alphaValue` and `.setFrame`) does not run at all in an app that is not the active
one — measured: a fade from 0.2 still read 0.2 a second later and never reached its end. Notes are
non-activating panels, so PinTack is usually not the active app while they are in use. `Motion.fade`
and `Motion.springFrame` drive a timer on the main run loop in common modes instead. Layer and
SwiftUI animations are drawn by the system compositor and were never affected.

### 5.8 Opacity and hover

A note's opacity is its own setting (30–100%). Window opacity is set in exactly one place,
`NotePanel.applyOpacity`, which combines the user's value with the finished-todo dimming (§5.3) and
**Settings → Notes → Faded notes**: when that option is on (it is off by default — someone who faded a
note may want it faded), a note eases to fully opaque while the pointer is over the **card** (never
the window, which is 24 pt bigger) and back when it leaves. The chosen opacity is never rewritten.

### 5.9 Closing and deleting

**Closing a blank note discards its file** instead of hiding it, so a change of mind after ⌥⌘N leaves
nothing behind. `Note.isBlank` is deliberately strict, because this deletes a file: no words (an
untouched `@Todo ` counts as none), no name of its own, not a template, no due date, no tag beyond
the automatic `todo`, and nothing a plugin stored in the frontmatter. The file on disk must be blank
too, so an edit another app has just made is never lost; otherwise it is an ordinary hide. The file
is removed outright rather than sent to the Trash. Only an explicit close does this.

**Deleting** (⌥⌘D, the menus, All Notes) moves the file to the Trash and offers **Undo** on the
toast for five seconds. Undo puts back the same note — id, frame, colour, reminders — and reopens its
window if it was open, and refuses rather than overwrite if something new has taken the name. All
of it goes through `WindowManager.delete`; nothing may show another toast after calling it, which
once replaced the one carrying Undo.

### 5.10 Note Stacks

Owner decision, 2026-09-22: **2 to 5 open notes piled into one**, to clear a crowded desk. Five is
the cap so a stack never grows tall.

- **Making one:** the **paperclip**, just left of the pushpin in every note's title bar, opens a
  popover listing the open notes with a checkbox each (the clicked note is checked and becomes #1),
  a name field and OK. A note already in a stack is listed, greyed, with its stack's name: a note is
  in one stack at a time. Past five, the rest cannot be checked.
- **The pile:** every note takes the front note's size, and each sits one title bar higher than the
  one in front of it, so only title bars show above the front note. A pile that would leave the top
  of the screen is moved down as a whole.
- **The stack bar**, under the front note's title bar: the stack's name (double-click to rename)
  and, on the right, Unstack (a struck-through paperclip), pin the stack on top, collapse the stack,
  close the stack. In a stack a note's own pin, collapse, close and paperclip give way to these; the
  front note keeps its Live Preview / Source switch. ⌥⌘P, ⌥⌘K and ⌥⌘W act on the whole stack.
- **Numbers:** each title bar leads with `#1`…`#5`, shown only while the note is in a stack. A number
  belongs to its **note**, not to a place in the pile: #1 is the note that was in front when the
  stack was made, and it keeps #1 wherever it moves. **⌘1–⌘5** bring that note to the front (not
  ⌥⇧1–5, which collided with the global ⌥⇧2 and type characters). **⌥Tab** sends the front note to
  the back, so pressing it walks the whole stack. Both only act while a stacked note is key; anywhere
  else the key is left alone. Clicking a back note's title bar brings it forward; dragging any title
  bar moves the whole pile; resizing the front note resizes the pile.
- **Pinned** is the stack's, not the notes': every window of it floats, and no note's own pin or
  glow is drawn while it is stacked. **Collapsed** folds every note to its title bar, with the front
  note's stack bar still under it.
- **Unstack** puts every note back exactly where it was, at its own size and collapse state.
- **Stored in `.pintack/stacks.json`** (atomic, like every vault write): name, the notes in number
  order, the front-to-back order, pin, collapse, and each note's frame from before. The notes
  themselves get nothing added. On load a missing note leaves its stack, a note listed twice stays in
  the first, and a stack of one is dissolved.
- **All Notes → Stacks** tab (§8.2) lists, searches, shows / hides, deletes and files stacks.
  **Deleting a stack deletes its notes** (owner decision), always after a question with three
  answers: **Unstack** (the default, on Return: keeps every note, exactly like the stack bar's
  Unstack), **Delete N Notes** (red, destructive, a deliberate click) and **Cancel** (Esc). It names
  how many notes go and, when any are filed, "including N filed in ‹folder›" or "in N folders".
  Undo on the toast brings the notes back and the stack with them. `StackDeleteAlert`.

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
of minutes/hours/days, and **Done closes it**. The banner's title is **PinTack - @Todo** and its
body is the note's name with the `@Todo` marker stripped; the date is not repeated, because the
banner arriving is the date. The date field is AppKit's `NSDatePicker`, not
SwiftUI's `DatePicker`, and the chosen date is held in a reference outside SwiftUI's state: writing
state on each keystroke re-rendered the panel, which threw away a half-typed entry (`37` became `7`)
and took the keyboard out of the field. Dates live in the frontmatter so a reminder travels with the note.
Notifications go through a `ReminderStore`: the system's `UNUserNotificationCenter` in the app, an
in-memory one under the self-test, which shares a bundle identifier — and so a notification store —
with any installed copy. They are re-armed at launch, where anything queued for a note the vault no
longer has is dropped, and are **cancelled when the note is deleted**. Permission is asked the first time a reminder is *set*, never at launch.
A moment already past is dropped rather than scheduled.

**Progress.** A todo's action bar shows one square per task — bright and glowing for done, dark for
not — then `3/7`. The squares **wrap at six to a row** and take as many rows as the tasks need,
thickening the bar; there is no cap. The tracker appears the moment the first checkbox is typed,
without reopening the note. On a note too narrow for six squares, the count goes first and then
squares come off the row, in that order; the tracker itself is never hidden and neither are the
tags. A note counts as *done* only when it **has** tasks and all are ticked.

**⌘↩ ticks or unticks** the checkbox on every line the selection touches, using the same three list
markers the tracker counts (`-`, `*`, `+`), so the box that flips is always one the tracker sees. On a
line that is not a task it declines and ⌘↩ keeps its old job.

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

### 8.0 One window, two tabs

All Notes and Settings are **one window** with two big tabs across its title bar, **All Notes** and
**Settings** (owner decision, 2026-09-21). Every shortcut that used to open either window picks
the tab instead: ⌥⌘H shows All Notes (and closes the window only when All Notes is already in
front), ⌘, shows Settings, and ⌥⌘T / ⌥⇧T / ⌥⇧2 open All Notes on their own sub-tab. Both tabs stay
alive underneath, so a search or a chosen Settings pane is still there on the way back.

**The look.** Dark means dark: a deep indigo (`#141128`), not the system's grey, with a slightly
lighter sidebar and surfaces. Light mode is a warm paper tone. A selection — a tab, a sidebar row, a
Settings pane, a glyph tab — is a **solid** `Brand.accentNS` orange with dark lettering, and it
slides to the new choice on a spring. Settings' sidebar glyphs are monochrome SF Symbols, outlined
at rest and filled when chosen, with no coloured tiles. All of it is in `ChromeTheme`.

### 8.1 Layout

A sidebar with four **glyph** tabs — folder, `#`, `@` (todos), cube (templates), a solid orange pill
sliding between them — a search field, a list, and a footer. The gear at the sidebar's bottom-left
corner switches to the Settings tab.

### 8.2 Tabs

- **Folders / Tags** — the note list, with check-boxes, reveal, rename and delete per row, and
  bulk move/delete/export/import.
- **Todos** — every todo note with a checkbox that finishes the whole note, its title (with the
  `@Todo` marker stripped), a one-line preview, progress squares and `3/7`, and its due date.
  Sorted by date created, most done, least done, or due date. Under the due-date sort, notes with
  **no** date sort last: no date is not the same as overdue. "Show done todos" strikes them through
  rather than hiding them.
- **Templates** — every template, with multi-select, Add to Folder and Delete selected.
- **Stacks** (a stack glyph) — every stack (§5.10): its name, its notes by number, a fan of their
  colours, show / hide, search by stack name or by any note's title, Add to Folder (every note of the
  stack moves into it and stays stacked) and Delete selected, which asks first because it deletes
  the notes.

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

The Settings tab of the one window (§8.0). Seven panes in a sidebar (a `TabView` overflowed into a
"»" menu and looked unfinished): Appearance, Notes, Shortcuts, Editor, Vault, Plugins, About.

App chrome uses the fixed `Brand.accentNS`, **never** the user's outline colour — a dark outline
once made Settings unreadable. Choices in this window are **our own controls** (`ChromeSegmented`,
`ChromeProminentButtonStyle`), not the system segmented picker or prominent button: those draw the
chosen item in the accent with white text, and no tint reaches it. Every orange selection carries
near-black lettering, 9 : 1 against the orange.

Notes pane covers the outline, the pinned glow and its strength, faded notes (§5.8), new-note size
and placement, auto-save and the action bar.

**The settings file records choices, not defaults.** Since `settingsVersion` 2, only values that
differ from the built-in defaults are written, so a better default reaches everyone who never
touched that setting. Every earlier build wrote every value, which froze the default in force on the
day of first launch; a version-1 file holding a *superseded* default (a 280 or 210 note size) is
therefore read as "not chosen". Anything else in it was picked by somebody and is kept. Keys a plugin
owns are preserved however little the app writes of its own.

Editor pane covers default mode, spellcheck, slash commands, image handling, bullet, inline-code
background colour and opacity, code-block background colour and opacity, line numbers in code blocks, rich-text paste, link
previews, and vim mode (§4.6) with its one-time notice.

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

Stacks (§5.10; only while a note in a stack is key): next note ⌥Tab, note #1–#5 to the front ⌘1–⌘5.

In the editor: **⌘↩** ticks the checkbox on the current line (§6.3). It is a keystroke of the editor,
not a rebindable action.

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

Three layers, all run by `scripts/verify.sh`, all required:

- **A Release build** — what actually ships. The self-test and every debug hook are compiled out of
  it, so code that leans on one of them builds in Debug and nowhere else. That went unnoticed for six
  commits once, found only when the DMG would not build.
- **Unit tests** (`PinTackTests/`) — frontmatter round-tripping, unknown-key preservation, atomic
  writes, import safety, search, image maths, reminders, templates, plugin security. The plugin
  security tests were mutation-checked: skipping approval, ignoring the token's page, and accepting
  unsigned trust all fail them.
- **The self-test** (`Support/SelfTest.swift`, Debug only) — the app launches, drives its own
  windows and web views with real events, and **asserts**. It exits non-zero on any failed check.
  It renders PNGs of everything as evidence — every note, both tabs of the main window, every
  Settings pane in dark mode, and the same window in light mode. If you add behaviour, add a check: a
  fact that is only logged is a fact nobody will notice going wrong.

  Two lessons it has taught. A check that measures what Swift *intended* proves nothing about what
  the page drew: compare the page's computed style against the value Swift sent. And the self-test
  shares a bundle identifier with any installed copy, so anything it writes outside its throwaway
  vault — notifications, the pasteboard, the Trash — reaches the real user; reminders therefore go
  to an in-memory `ReminderStore` under the self-test. It also takes the foreground before it starts,
  because several checks read the key window.

  **What it cannot reach:** a real pointer (hover), clicks on SwiftUI buttons, the notification banner
  itself, and VoiceOver. Those are tested by hand.

### 15.2 App icon

An **Icon Composer** document, `PinTack/AppIcon.icon`. Do not go back to an `AppIcon.appiconset`:
modern macOS shrinks a legacy icon into a dark system plate. The plate cannot be made transparent
(an alpha-0 fill still renders opaque), and in the Dark icon style the system forces it dark for
every app. The art is full-bleed so no plate shows in the Default style.

The current art (2026-09-21) is the owner's design: orange code brackets and a pencil on a purple
note with a page curl. It is cropped to the artwork and filled edge to edge, so the system's rounded
shape is the icon's edge; the base behind it is the window's dark indigo, which is what shows behind
the curl. Preview exactly what the system draws with
`/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`.

Never set `NSApp.applicationIconImage`: it made the Dock show one icon and swap to another.

### 15.3 Distribution — PARTLY BUILT

`scripts/make-dmg.sh` builds a universal (arm64 + x86_64) Release app and packages a DMG with a
custom background and layout. The app is **14 MB** (3.5 MB of it the vendored editor and its
language parsers); the compressed DMG is about 6 MB.

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
- **Memory at scale** — one web view per open note (§2.1). **Measured 2026-09-22** with
  `scripts/measure-memory.sh` (Debug build, macOS 27.2, Apple silicon; short notes each holding a
  checklist and a bash block; two runs agreed within 1%). Footprint is what Activity Monitor calls
  Memory; RSS double-counts pages shared between processes.

  | Open notes | WebContent processes | PinTack footprint | WebKit footprint | **Total footprint** | Total RSS |
  |---:|---:|---:|---:|---:|---:|
  | 1  | 1  | 48 MB  | 63 MB    | **111 MB**  | 226 MB  |
  | 11 | 11 | 95 MB  | 399 MB   | **493 MB**  | 974 MB  |
  | 26 | 26 | 170 MB | 876 MB   | **1.0 GB**  | 2.1 GB  |
  | 51 | 51 | 279 MB | 1,680 MB | **1.95 GB** | 3.9 GB  |

  **About 37 MB per open note**, ~31 MB of it in that note's own WebContent process (WebKit gives
  every page one; the counts match what each page reports for itself). Fine for a handful of notes,
  heavy for fifty. Hidden notes have no window and no page (not yet measured). Search has still never
  been run against a vault of 1,000 notes.
- **Accessibility** — no VoiceOver pass has been made over the window or the notes.
- **1.0** — what separates the beta from a release is signing and notarization, a stretch of daily
  use with no new bugs, a measurement at scale, and a VoiceOver pass.
- **JavaScript tests** — roughly 2,000 lines of editor JS have no automated coverage. A test runner
  would be a new dependency; assertions could instead run inside the self-test's web view.

---

## 18. Assets

- `PinTack/AppIcon.icon` — app icon (Icon Composer document)
- `Assets.xcassets/Pushpin` — the pinned-note pushpin PNG
- `Editor/icons/` — language logos, Devicon (MIT), vendored
- `Editor/vendor/` — CodeMirror 6, Lezer, `@codemirror/search` and `@replit/codemirror-vim`, all MIT, vendored
- `docs/assets/` — the icon as rendered for the README, its source art, the DMG background, and the
  original HTML prototype

## 19. Contributing

Conventional commits (`feat:`, `fix:`, `refactor:`, `docs:`, `chore:`), one logical change each,
small — the owner's practical undo is `git revert`. Comment the **why**, never the **what**; any
workaround for a platform constraint must name the constraint and cite its section here.

Tests are required for anything that parses or writes vault files. Frontmatter round-tripping,
unknown-key preservation and atomic writes are the three places a bug means data loss.
