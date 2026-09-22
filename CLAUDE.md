# CLAUDE.md

Project context for Claude Code. Read this before doing anything in this repo.

---

## What this is

**PinTack** — an open-source macOS sticky-notes app. Notes are floating desktop
windows backed by plain Markdown files. Obsidian-style Live Preview editing, an
interactive WidgetKit widget, and a JavaScript plugin system.

**`SPEC.md` is the source of truth.** It is complete and detailed. Read the
relevant section before implementing anything. If you believe the spec is wrong,
say so and explain why rather than silently doing something different.

---

## Who you are working with

**The project owner does not write Swift.** He is a Windows endpoint automation
engineer (PowerShell, Intune, SCCM, Azure DevOps, Terraform/OpenTofu). He reads
infrastructure code fluently and Swift not at all.

This changes how you must work:

- **Never claim code works because it looks correct.** He cannot check your
  syntax. Run `xcodebuild` and report the actual result. "It should compile" is
  not an acceptable statement in this repo.
- **Verify by running, not by asserting.** Build it, launch it, and describe the
  observable behavior. He validates behavior, not implementation.
- **Explain decisions in plain language**, using infrastructure analogies where
  they help. Skip Swift idiom lectures unless he asks.
- **Raise real problems directly.** He would rather be told a design is wrong
  than be agreed with. Do not soften genuine objections.
- **He owns product decisions.** Do not change UX, naming, or feature scope
  without asking, even when you have a better idea. Propose, then wait.

---

## Hard constraints — never violate without explicit approval

1. **No cloud sync in v1.** Storage is a plain Markdown vault. Sync is the
   user's job via iCloud Drive / Dropbox / Syncthing.
2. **No dependencies without asking.** Every added package is a maintenance
   burden on a project that expects to change owners. CodeMirror 6 and Sparkle
   are pre-approved, and `@replit/codemirror-vim` + `@codemirror/search` were
   approved for vim mode (2026-09-21). Nothing else is.
3. **No network access from the app**, except Sparkle update checks and **link
   previews** (owner-approved 2026-09-19, `PinTack/Vault/LinkPreview.swift`).
   The webview CSP forbids remote resource loading and this will not be relaxed:
   link previews are fetched in **Swift**, never in the page, and the thumbnail is
   written into the vault and loaded from disk. The feature is **off by default**;
   while it is off nothing is requested. Any other network access still needs
   explicit approval, and no new one may be added inside the webview.
4. **Unknown frontmatter keys must survive a write.** Plugins own them. Dropping
   them is user data loss.
5. **Vault writes must be atomic** (temp file in the same directory, then
   `replaceItem`). A partial write must never be able to corrupt a note.
6. **No autorun in Runner.** Every command requires explicit user approval,
   trust is bound to the exact command string, and editing a command resets it.
   There is no flag that changes this.
7. **Target macOS 14.0.** Do not use APIs newer than that without a runtime
   availability check.
8. **GPL-3.0.** Do not vendor incompatible code.

---

## Three platform traps already documented

These look like mistakes to anyone who does not know why they are there. If you
find yourself "cleaning up" one of them, stop.

### 1. The transparent margin (SPEC.md §5.2)

Every note's `NSWindow` is **24pt larger than the visible card on all sides**.
macOS clips content to window bounds, so the overhanging pushpin and the pinned
glow cannot be drawn at the card edge.

Consequences, all mandatory:
- `NoteCardView.hitTest` returns `nil` outside the card rounded rect. Without
  it, every note carries an invisible 24pt halo that swallows clicks meant for
  the desktop or the app beneath.
- `hasShadow = false`. The system would draw the shadow on the transparent box.
  Card shadow and pinned glow are drawn manually.
- **All persisted geometry is the CARD rect, not the window rect.** Getting this
  wrong makes every note drift 24pt on each relaunch.

### 2. App Group Team ID prefix (SPEC.md §11.2)

On macOS, app group identifiers **must** be prefixed with the Team ID:

```
TEAMID.group.io.cymentix.pintack     ✅
group.io.cymentix.pintack            ❌ silently kills the widget
```

An unprefixed identifier is rejected by `containermanagerd`, the widget process
exits immediately, and the widget never appears in the gallery with no useful
error shown to the user.

Additionally: **resolve the app group at runtime from the app's own
entitlements**, never hardcode it. The Team ID changes when the project moves
from a free personal signing team to the paid Developer Program.

### 3. GUI apps do not inherit shell PATH (SPEC.md §13.5)

Launch from the Dock and `python3` will not resolve even though it works in
Terminal. Runner must execute through the user's **login shell**:

```swift
let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
process.arguments = ["-lc", command]
```

---

## Build and verify

```bash
xcodebuild -scheme PinTack -configuration Debug SYMROOT="$PWD/build" build
xcodebuild -scheme PinTack SYMROOT="$PWD/build" test     # SYMROOT keeps ONE copy of the app (see below)
open build/Debug/PinTack.app        # or run from Xcode
```

The app runs **unsandboxed** and reads `~/Documents/PinTack/` directly.
Sandboxing needs a security-scoped bookmark flow that is deferred.

**After any change touching windows, the vault, or the plugin API, build and
launch before reporting back.** Describe what actually happened on screen.

### One command that says whether the build is broken

```bash
scripts/verify.sh
```

Unit tests AND the self-test, both of which must pass. **The self-test asserts and exits non-zero**
(`SelfTest.check`); it is not a report for a human to read and judge. If you add behaviour, add a
check — a fact that is only logged is a fact nobody will notice going wrong.

### Seeing what is on screen without Screen Recording permission

An agent cannot screenshot another app. In **Debug builds** the app can render
its own windows. Point it at a throwaway vault so it never touches real notes:

```bash
PINTACK_VAULT=/tmp/pt/vault PINTACK_SELFTEST_DIR=/tmp/pt/out PINTACK_SELFTEST_QUIT=1 \
  build/Debug/PinTack.app/Contents/MacOS/PinTack
```

It writes `report.txt` — every check as PASS/FAIL, ending in a summary — plus PNGs of the Dock
icon, menu-bar icon, every note, the main window on both tabs (`all-notes.png`, `settings.png`),
every Settings pane in dark mode (`pane-*.png`), the same window in light mode, the popovers and the
shortcut list. It exits 1 if any check failed. The code is `Support/SelfTest.swift`, compiled out of Release. Other env vars:
`PINTACK_NO_HOTKEYS`, `PINTACK_NO_TOAST`, `PINTACK_ALLNOTES_TAB`, `PINTACK_SETTINGS_PANE`,
`PINTACK_LINKPREVIEW_URL` (opt-in; without it nothing on the network is contacted).

### The editor is vendored, not bundled

`Editor/` is a plain folder copied into the app. CodeMirror 6 sits in
`Editor/vendor/` as unmodified ES modules resolved by an import map, so there is
**no bundler** (esbuild etc. would be a new dependency). Regenerate with
`scripts/vendor-codemirror.sh`. Test the editor in a browser with
`node scripts/dev-server.mjs` (it only rewrites the CSP scheme for HTTP).

### App icon

The icon is an **Icon Composer** document, `PinTack/AppIcon.icon` (Xcode compiles it into `Assets.car` and a
fallback `.icns`). Do not go back to a plain `AppIcon.appiconset`: on current macOS every legacy icon is shrunk
into a dark system plate. The plate cannot be made transparent (tested: even an alpha-0 fill renders opaque);
in the user's Dark icon style the system forces it dark for every app. What we control is the plate colour in
light style and how large the art is. Preview exactly what the system draws with
`/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`.

Never set `NSApp.applicationIconImage`: it made the Dock show one icon and then swap to another.

The current art (2026-09-21) is the owner's purple note with orange code brackets and a pencil,
cropped to the artwork and filled edge to edge on a dark-indigo base. `docs/assets/pintack_icon.png`
is it rendered by `ictool` for the README; `pintack_icon_source.webp` is the owner's original.

**Always build and test into `build/`** (`SYMROOT="$PWD/build"`). A second copy in DerivedData makes
LaunchServices list two apps (Spotlight shows PinTack twice) and can serve an old icon. After changing the
icon: `lsregister -f -R -trusted build/Debug/PinTack.app`, then `killall Dock`.

### Menu-bar icon caveat

The pushpin is a real `NSStatusItem`. On a notched MacBook with a crowded menu
bar, or with a menu-bar manager (Thaw, Bartender, Ice), new items are pushed out
of sight. Check the manager's hidden section before assuming a bug. The Dock
icon is the guaranteed entry point.

---

## Code conventions

- Swift API Design Guidelines. No house dialect.
- Comment the **why**, never the **what**. Any workaround for a platform
  constraint must name the constraint and cite the SPEC.md section.
- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`
- One logical change per commit. Small commits, because the owner's only
  practical undo is `git revert`.
- Tests are required for anything that parses or writes vault files. Frontmatter
  round-tripping, unknown-key preservation, and atomic writes are the three
  places a bug means data loss.

---

## Phase discipline

| Phase | Scope |
|---|---|
| **1** | Shell, vault, note panels, hotkeys. Placeholder `NSTextView` editor. |
| **2** | `WKWebView` + CodeMirror 6, Live Preview, slash commands, image paste. |
| **3** | Central window, FTS5 search, folders/tags, settings, import/export. |
| **4** | WidgetKit widget, plugin API, Runner plugin. |
| **5** | Signing, notarization, Sparkle, DMG, Homebrew cask. |

**Do not start a phase before the previous one runs.** Phase 2 is the gate: if
Live Preview cannot be made to feel like Obsidian, the product thesis needs
revisiting before more is built on top of it. Say so plainly if you hit that.

### Where things stand

The owner overrode the strict phase order: the app was rebuilt in one pass
covering Phases 1, 2 and 3 (vault, note windows, Live Preview editor, All Notes,
Settings, hotkeys, import/export, FTS5 search). It builds, and the unit tests
(`xcodebuild -scheme PinTack test`) cover frontmatter round-tripping, unknown-key
preservation, atomic writes, import safety and search.

**Phase 4, plugins and Runner: built.** The WidgetKit widget is **shelved by the owner**: it needs a real
Apple signing team (app group must carry the Team ID, trap 2), so it waits on that decision.

**As of 2026-09-22: 0.1.0, build 12, in beta with testers.** `verify.sh` covers a Release build, 241
unit tests and 236 self-test checks. `CHANGELOG.md` records every change, day by day, with the reason
— read it before assuming something is an accident. Honest view of what separates this from a 1.0:
signing and notarization, a stretch of daily use with no new bugs (bugs were still being found by
use at a rate of about ten a session), a measurement with many notes open and a large vault, and a
VoiceOver pass.

**Not built yet:** the widget, Sparkle, signing/notarization, App Sandbox.
The app is a normal Dock app (no `LSUIElement`) plus a menu-bar item: an
owner decision that replaced the original menu-bar-only design.

Owner decisions added after the rebuild (2026-09-19):
- A note's `theme` is its palette mode (Auto/Dark/Light), not a text override. Text color is
  always automatic. Do not add a text-color control.
- New todo notes start as `@Todo ` (greyed "todo title" hint), are tagged `todo`, and Enter
  after the title creates the first checkbox. The default note font is Comic Sans MS.
- Titles are draggable; double-click renames. The bottom strip is called the **action bar**.
- Settings use a sidebar (the TabView overflowed into a "»" menu and looked cheap).
- All Notes and Settings are ONE window with two tabs (owner decision, 2026-09-21), in
  `Central/MainWindow.swift`. `AllNotesWindowController` and `SettingsWindowController` are kept as
  thin fronts that pick a tab, so no shortcut or menu had to change. Its look lives in
  `ChromeTheme`: dark = deep indigo, never system grey; a selection is SOLID `Brand.accentNS` with
  dark lettering; Settings glyphs are monochrome with no coloured tiles. Never use the system
  `.pickerStyle(.segmented)` or `.borderedProminent` in that window: both draw the choice in the
  accent with WHITE text, which no tint changes. Use `ChromeSegmented` / `ChromeProminentButtonStyle`.
- The menu-bar item takes the system's default position (left end); do not seed one.
- The pinned pushpin is the owner's PNG (`Assets.xcassets/Pushpin`), anchored by its crack; the
  pinned glow is the note's own color. App chrome (Settings, All Notes, popovers) uses the fixed
  `Brand.accentNS`, NEVER the user's outline color: a dark outline once made Settings unreadable.
- Every note-scoped action runs through `NoteCardView.perform`, from the key monitor, both menus and
  the right-click menu. `ActionRouter` runs an action once per 250 ms, because a press can arrive by
  two paths (Carbon + key monitor) and a toggle then cancels itself. Key auto-repeats are swallowed.
- Colored text uses `<span style="color:…">`, but its tags are always hidden in the editor and
  Tab leaves the span. `/red`, `/blue`... are the slash commands (no `color-` prefix).
- Renaming a note writes `title:` into the frontmatter and NEVER rewrites the body. A note with no
  `title:` follows its first line; once renamed, the two are independent both ways.
- Every language CodeMirror ships is vendored, but `Editor/languages.js` loads a parser only when a
  note actually contains a block in that language. Do not import them eagerly: that is ~3.5 MB per
  note window. A fenced block that names a language also gets a logo + name badge: the logos are
  Devicon SVGs (MIT) in `Editor/icons`, vendored by `scripts/vendor-language-icons.sh`, and the
  badge has NO pill behind it (an owner decision, 2026-09-20); dark marks such as Rust and Markdown
  get a faint light halo on dark paper instead. A language with no logo gets a dot in its own colour.
- `TagPillsView.hitTest` returns nil almost everywhere so the empty action bar still drags the note
  — EXCEPT over the "+N" overflow pill, which takes its own click and shows the tags that did not
  fit. Do not "simplify" that back to nil.
- Animation lives in `Motion` (windows, real `CASpringAnimation` physics) and the movement block at
  the end of `editor.css` (back-out cubic-beziers that overshoot). The owner wants these LIVELY
  (2026-09-20) — do not quieten them. Both sides honour the system's Reduce Motion setting, which
  is an accessibility promise, not a default. Only things that appear ONCE get animated: an image or
  code block is rebuilt whenever the caret moves on or off its line, so animating those flickers on
  every click. Window FRAME animations get a gentler overshoot than layer springs, because a frame
  is clamped by `minSize` and a collapse targets exactly that.
- Tag pill colours come from a **djb2 hash of the tag text**, never `hashValue` (seeded per process,
  so colours would change every launch). Pills are washed out to always take dark text.
- Pasting an image inserts it straight away. Cropping and resizing happen IN the note: click the
  image and it grows four corner handles, plus a crop tool and a bin that sit OUTSIDE the picture,
  above its top-right corner (an owner decision, 2026-09-20), falling below it when the image is at
  the very top of a note. Return applies a crop, Escape cancels. There is no dialog and nothing to
  type. The crop shade and box live in `.cm-crop-layer` UNDER the toolbar in both DOM order and
  z-index: appending a full-size shade after the toolbar drew the tick and cross fine but ate every
  click on them. Drive the self-test's clicks through `document.elementFromPoint`, never straight
  at an element, or that whole class of bug is invisible. The display width is written into the link as `![alt|320](path)`, the
  Obsidian convention, so the file stays ordinary Markdown. Cropping asks Swift for the pixels;
  Swift writes a NEW attachment and the link is repointed, so the original is never overwritten.
- `ImageEditing.png` takes crop rects in IMAGE PIXELS with a bottom-left origin, but `draw(in:from:)`
  reads `from` in the image's POINT space. The conversion between them is not optional: without it a
  crop of any Retina image came out black. Test the CONTENT of a 2x crop, not just its dimensions —
  that gap is what let the bug through the first time.
- Freeze mode (⌥⌘F, `/freeze`, the snowflake, the right-click menu) makes a note ignore the mouse.
  The snowflake CORNER stays live via pointer polling (`FreezeMode`), because a window that ignores
  the mouse cannot be clicked to un-ignore itself. Never switch that to a global mouse monitor: that
  API family asks for Accessibility permission.
- Todo notes (tagged `todo` or starting `@Todo`) get a reminder bell and progress squares in the
  action bar, and their own `@` tab in All Notes. `due:`/`remindOnTime:`/`remindAhead:` live in the
  frontmatter so a reminder travels with the note. Notification permission is asked the first time
  a reminder is SET, never at launch. A note is "done" only when it has tasks and all are ticked.
- Quick capture: the Services entry ("New PinTack Note") gets the selection from any app with NO
  Accessibility permission, because the user chose the menu item. ⌥⌘C captures the clipboard. Never
  implement this by synthesising ⌘C into another app — that needs Accessibility, and this app must
  not ask for it. NSServices is why the app uses a real `PinTack/Info.plist` instead of
  GENERATE_INFOPLIST_FILE: `INFOPLIST_KEY_*` cannot express an array of dictionaries.
- `@` in a note means two things and they must not collide: `@todo` converts the note to a todo
  (puts `@Todo` on line 1 with the greyed hint and adds the `todo` tag), and `@name` recalls a
  template. Line 1's own `@Todo` marker is NEVER a template trigger, and `todo` is a reserved
  template name. The old `/todo` command is now `/checklist`.
- Templates are ordinary notes carrying `template: <name>` in the frontmatter — they still live in
  folders and appear in lists. Names are one word (letters, digits, hyphen, dot, underscore),
  because the name has to be parsed back out of `@name` in a note's text.
- All Notes has four glyph tabs: folder, #, @ (todos), cube (templates). Todo rows strip the
  `@Todo` marker from the title, since every row there is a todo.
- The slash / tag / template menus and the `/find` overlay float on their OWN dark panel, so they
  use `--chrome-accent` (fixed, from `Brand.accentNS`), never `--accent`. `--accent` is
  `accentForNote()`, whose low-contrast fallback is near-black — which painted the selected menu
  row black-on-black on a tester's Mac. Same rule as Settings chrome, same bug twice now.
- A bare `@` lists every template, the way a bare `/` lists every command. Requiring a letter first
  meant nobody could discover what templates existed.
- `⌥⇧=` is Show/Hide Opened Notes: a TOGGLE (owner decision, 2026-09-20). Its rawValue is still
  `showAllOnDesktop` because stored overrides in `hotkeys.json` are keyed by it.
- The action bar's height is `NotePanel.footerHeight` plus one `footerRowHeight` per EXTRA row of
  task-tracker squares, and it grows DOWNWARD (owner decision, 2026-09-20) so a checklist never
  shrinks the text area. `note.cardFrame` always stores the PLAIN-bar card; the extra is re-derived
  from the note's own tasks in `NotePanel.visibleCardRect`, the same trick `collapsed` uses, so the
  stored rect cannot drift across relaunches. `syncFrameToNote` subtracts it again.
- Six squares a row is the cap, rows are UNLIMITED, and the tracker is never hidden for want of
  room — it used to be one row that vanished past about seven tasks, taking the tags with it. On a
  note too narrow for all of it, `TaskProgressView.grid` gives things up in a fixed order: the tags'
  elbow room last, the "3/7" count first, squares a row in between.
- Tag pills wrap onto as many lines as the bar is thick but NEVER make it thicker (owner decision,
  2026-09-20): tags overflow into `+N`, tasks add rows.
- `NoteCardView.syncTodoState` is what makes the tracker appear as the first checkbox is typed.
  Rebuilding the bar on every keystroke would cut its cross-fade short, so it is keyed on a
  signature of `isTodo` + the task counts.
- The reminder popover's date is an `NSDatePicker` in a `DateBox` — a reference deliberately OUTSIDE
  SwiftUI's state. Any SwiftUI state write re-renders the panel, and a re-render both discards a
  half-typed entry ("37" became "7") and moves first responder off the field. Do not "tidy" it back
  into `@State`, and do not push a value into the picker while the panel is open. Done closes the
  popover; the panel commits on `onDisappear` too, so clicking away still saves.
- The first launch shows `OnboardingWindow` — one card, OK dismisses it. "Once" is the empty
  `.pintack/onboarded` file, written when it is SHOWN, and its words live in `OnboardingContent`
  apart from the view: SwiftUI puts none of its own views into the accessibility tree an NSView
  hands out, so text only inside the view is text no test can read. The self-test skips it at
  launch (`SelfTest.isRequested`) and drives it deliberately later, because a modal panel taking
  key status at launch breaks every check that types into a note.
- Default new-note size is 300 × 250 (owner decision, 2026-09-20). 300 is the narrowest width where
  a todo's bar fits six squares, the count and a tag pill together; below it the count goes first.
- The self-test calls `NSApp.activate` before anything else. Several checks read the KEY window, and
  an installed copy of PinTack or the terminal being in front makes them measure nothing.
- A fenced code block is its own PANEL — a dark slate on every note (owner decision, 2026-09-20),
  with its own colour + opacity setting beside inline code's. The token palettes and the language
  badge key off `--code-paper`/`data-code-paper`, which follows the PANEL, not the note: Swift
  composites the panel over the note's colour to decide. Nothing inside a block may use `--fg` or
  `--fg-dim` — those follow the note, which is how the badge came out dark on a dark panel. Third
  time this bug class has appeared (Settings chrome, the slash menu, this).
- Checks that only measure what Swift INTENDED prove nothing about what the page drew: the first
  version of the code-panel checks passed with the stylesheet reverted. Compare the page's computed
  style against the value Swift sent, numerically (the two format alpha differently).
- A blockquote's left bar is `--quote-bar`, bright red, on purpose (owner, 2026-09-20).
- The self-test shares a BUNDLE IDENTIFIER with any installed copy, and a notification store is
  keyed by bundle identifier. Left on the system store, every run posted its own fake reminders to
  the logged-in user an hour later AND its launch-time tidy-up deleted the user's real ones. The
  self-test now injects `MemoryReminderStore` (in `AppDelegate`, BEFORE anything can schedule).
  Treat the same way anything else that writes outside the throwaway vault — the notification
  centre, Services, LaunchServices, the pasteboard.
- AppKit's WINDOW animator (`window.animator().alphaValue` / `.setFrame`) does not run at all in an
  app that is not the active one — measured, and PinTack is usually not the active app. Window
  opacity and frame animations go through `Motion.fade` / `Motion.springFrame`, which run on our own
  timer. Do not go back to `animator()` for a window. Layer and SwiftUI animations are unaffected.
- Closing a BLANK note discards its file (`Note.isBlank`, deliberately strict); ⌥⌘D and All Notes'
  delete offer Undo for five seconds through `WindowManager.delete`. Nothing may show a second toast
  after calling it: that replaced the Undo toast once already.
- Settings files write only what differs from the defaults (`settingsVersion` 2), so a better
  default can reach people who never touched it. A v1 file holding a SUPERSEDED default (280/210) is
  read as not chosen.
- `/find` is quick open. Opening a note from it deliberately does NOT move focus: the key window and
  the caret stay where the search started.
- Link previews are off by default and fetched only in Swift. A dismissed preview is remembered in
  `.pintack/linkpreviews.json`, not in the note, so notes stay plain Markdown, and it is forgotten
  once the link leaves the note: the ✕ hides the card that is there, not that address for ever.
- Vim mode (owner-approved 2026-09-21, SPEC §4.6) is ONE global switch, off by default. The package
  is imported the first time it is switched on, never eagerly. `:` and `/` open in the note's ACTION
  BAR, not in the page: `cm.openDialog` is replaced and each keystroke is fed back to the engine's
  own prompt handlers. `controlTextDidEndEditing` for the command field cancels the prompt and
  RETURNS — falling through renamed the note to whatever was typed. `cm.findPosV` is clamped to the
  next line because the engine treats a table or a squashed fence as folded text and jumps it whole.
  The line gutter counts visible lines; a hidden fence keeps its number (`pt-gutter-hidden`). The
  first-time notice (`VimNotice`, `vimNoticeShown`) is the owner's condition for shipping: it names
  the risk of moving through pictures and tables. Do not drop it or water it down.
- Code-block line numbers are a setting, off by default; with vim on they give way to the gutter.
- In vim mode a rendered TABLE IS A FOLD (owner, build 10): `3 [+3]` in the gutter, j stands on it
  then steps past it, zo/zc/za/zR/zM and the [+]/[−] click. The cursor "stands on the fold" at the
  table's first or last position, which `build()` treats as NOT inside it; `takeFoldSnap` moves a j
  that the engine landed mid-row back onto the fold. `tableFolds` must be listed in the fields that
  make Live Preview rebuild, or zo changes nothing on screen (it did, first time).
- Block widgets (table, plugin block, link card) take PADDING, never margin, and animate what is
  inside them, never themselves: CodeMirror's height map ignores a block's margin and books a block
  measured mid-scale at the shrunken size. Both made every gutter number below a table drift ~14px.
  `gutterAlignmentProbe` measures it.
- In GFM a line straight after a table with no blank line between is another ROW of it. A test note
  that forgets the blank line is testing a different table.
- Note Stacks (owner, 2026-09-22, SPEC §5.10): `Windows/Stacks.swift`. A stack is a relationship
  between notes, so it lives in `.pintack/stacks.json` and the notes get NOTHING in their
  frontmatter. Numbers are PLACES: the front note is always #1 (owner, 2026-09-22 — this REPLACED
  numbers that stayed with their notes, so do not go back). ⌘1–⌘5, not ⌥⇧1–5, because ⌥⇧2 is the
  global Templates key. `NotePanel.becomeKey` brings a back note forward by ANY route: macOS raises a
  clicked window on the press, and the pile used to stay behind (owner-reported). A click is < 4pt. Stack keys pass through unless a stacked note is key.
  In a stack the STACK is pinned (`NotePanel.isOnTop`), and the note's own pin art and glow are not
  drawn (`showsOwnPin`). Unstack restores each note's pre-stack frame from `before`. Deleting a stack
  deletes its notes, always behind `StackDeleteAlert`, whose DEFAULT (Return) is Unstack — the
  answer that loses nothing — and whose destructive button needs a click. The self-test presses
  Return on the real alert. `WindowManager.delete(_:onUndo:)` brings the stack back on Undo.
- The Tutorial (owner, 2026-09-22, SPEC §8.4) shows REAL screenshots: `scripts/make-tutorial-shots.sh`
  drives the app (`TutorialShots`, Debug + throwaway vault only) and writes
  `PinTack/Resources/Tutorial/*.png`, which ship in the bundle. Re-run it when a feature's look
  changes. Slides play themselves every 5 s until ‹ / › is used; `TutorialModel` holds that so the
  self-test can run the clock without watching pixels.
- All Notes and Settings tooltips read "Name | description" through `Tip.text` / `.tip(_:_:)`, after
  1 second; the All Notes glyph tabs draw their own (`GlyphTabs`, 0.5 s, orange). Every new control
  there gets one. Row icons go through `RowActionIcons`: show/hide, rename, (Unstack), delete.
- A stacked window TAKES clicks in its margin that lie over another member's title bar and hands
  them on (`stackMemberUnder`). Without it, clicks low on a back title bar were dropped: macOS routes
  them to the front window wherever its shadow is not fully transparent. Synthetic clicks sent
  straight to the back window never showed this — the self-test routes points the way macOS does. Row actions live in `Central/RowActions.swift`
  (`RowIconButton`, `NoteRowActions`, `TemplateNaming`), shared by every tab.
- A pinned note's glow is its own colour on light paper and LIGHT on dark paper
  (`NoteCardView.glowColor`); strength goes to 200%. The pushpin is drawn at `pinScale` 0.6.
- `scripts/measure-memory.sh` (Debug `MemoryProbe`, throwaway vault only): about 37 MB per open note.
- `MainWindowController.show` switches the tab INSTANTLY and then sends `objectWillChange` once
  more on the next run-loop turn. Without that nudge, a tab change landing while SwiftUI was mid-update
  was dropped: the model said Settings while the window drew All Notes, one run in two (measured
  2026-09-21 by `SelfTest.drawnTab`, which reads the pixels, not the model). Only a click springs.

### Scope: a sticky-note app, not a note-taking app

**Check every proposed feature against the product thesis at the top of SPEC.md before suggesting
it:** short notes on the fly (condensed data, important data, or both), with special attention for
developers' snippets that move between tools and workflows; not knowledge bases, wikis or
documentation. If a feature only makes sense for long documents, say so and do not propose it.

The owner turned these down by name (2026-09-20) as scope creep. **Do not propose them again**
without new reasoning; the goal is concentrated, important information that takes little screen
space and can be referenced fast. Obsidian already exists for the rest.

- **`[[wikilinks]]` and backlinks.** Notes referencing each other turns this into a knowledge base.
- **Note version history / snapshots.** Defeats the point of a sticky note.
- **Sync conflict resolution.** Sync is the user's job; this is personal, not collaborative.

### Plugins (docs/PLUGINS.md is the author's guide)

- The core has NO private hooks for Runner. `Plugins/runner/` uses only the public API, and it must stay that way.
- Every privileged call goes through `PluginBridge.handle`: token (per plugin, per web view) → declared
  permission → for commands, the native `ApprovalPresenter`. Never add a path that skips a step.
- **There is no flag, setting or environment variable that answers the approval sheet.** Tests inject a fake
  presenter; the self-test seeds approvals through `TrustStore` and never clicks an unapproved command.
- Trust is bound to command text AND working folder, and each entry is HMAC-signed with a per-Mac secret that
  lives outside the vault, so a synced or shared `trust.json` cannot pre-approve anything.
- Plugins run in each note's web view. They share a JS realm, so they are not isolated from each other; the
  boundary is on the Swift side. Do not claim more than that.
- `PinTackTests/PluginBridgeTests.swift` and `PluginFoundationTests.swift` are the security tests. They were
  mutation-checked (skipping approval, ignoring the token's page, accepting unsigned trust all fail them).

Choices that differ from SPEC.md or the prototype, made deliberately:
- The **global** hotkeys are the ones that open or switch a window plus the three capture ones:
  New note, New todo, New note from clipboard, All Notes, All Notes by tag, Todos, Templates,
  Auto-arrange, Show all on desktop. Everything that acts on ONE note stays app-scoped — a
  system-wide key that bins whatever note happens to be focused is not a thing to hand out.
  Registering ⌥⌘W or ⌥⌘H system-wide would steal them from every other app.
  The ⌥⇧ rank (⌥⇧2, ⌥⇧T, ⌥⇧=) is owner-chosen (2026-09-20); note that ⌥⇧ combinations normally
  type dead keys, so a global one takes that character away from every app.
- ⌥⌘M toggles Live Preview/Source (SPEC §10.2); the prototype used it for minimize.
- Footer has three controls (SPEC §5.3), not the prototype's swatches and sliders.
- The prototype's iCloud status is omitted: cloud sync is out of scope for v1.
