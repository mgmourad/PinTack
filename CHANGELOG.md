# Changelog

Everything that has happened to PinTack, newest first, from the day it was a specification with no
compiled code to the beta it is now.

**How to read this.** The version has been **0.1.0** throughout; the **build number** is what changes,
and each build below is a disk image. **Builds 1–21 were internal**, used by the owner alone and
given to nobody; build 22 is the first meant for outside testers. Every entry names what changed and, where
the history records it, *why* — the reason is the part that stops someone "fixing" it later. Commit
hashes are given so any entry can be traced, and undone, with `git revert`. Decisions the project
owner made are marked **(owner)**; `CLAUDE.md` records them in full and `SPEC.md` describes the app as
it stands.

---

## Build 21 — 2026-09-26

### Fixed
- **The tutorial is smooth: dragging it, and the slides changing (owner).** It was burning a quarter
  of a processor core doing nothing at all. The little bar that fills under the slide showing was
  animated, which made the whole 980×700 page redraw 120 times a second for as long as the tutorial
  was open — so there was nothing left to draw a drag or a slide change with. The bar now moves in
  steps of about a point without an animation, it is its own small view so a tick no longer rebuilds
  the page, and the clock stops entirely while the page is being dragged.

  Measured, not guessed: **250 ms of processor time a second → 14 ms**, page rebuilds while idle
  **6 a second → 0**, no late frames through a slide change. Two changes that looked like obvious
  wins measured worse and were dropped.

## Build 20 — 2026-09-26

### Added
- **A stack holds ten notes (owner)**, up from five, with a key for every place: ⌘1–⌘9 and ⌘0. Ten is
  the cap because ten is as many places as the number row has keys.
- **A + beside the stack's name (owner)** opens a panel that changes who is in the stack and what it
  is called: tick a note to add it to the back of the pile, untick one to take it out and put it back
  where it was, edit the name at the top. Below two members the stack dissolves and every note is
  kept, exactly as Unstack does.
- **A pinned stack glows (owner).** Every note of the pile draws its own halo, in its own colour and
  under the same glow settings a single note follows. The pushpin stays on the stack bar.

### Changed
- **A dark note's glow is now a light version of its OWN colour (owner):** a dark blue note glows
  light blue, a burgundy one red-pink. It used to blend towards white, so every dark note glowed the
  same near-white. A grey or black note still glows white, having no hue to keep.

### Fixed
- **The tutorial can actually be dragged now (owner: "still cannot be dragged").** The drag layer was
  an AppKit view in the background, and a view behind SwiftUI never sees the mouse. It is a SwiftUI
  gesture now, simultaneous with the buttons so they still work.
- **The test that let that through.** It called the drag view's own method, which no hand can do; it
  now sends real events through `NSApp.sendEvent`, moving the pointer the way the window server does.
  That first showed the page moving 3.5x too far — the kind of failure the old test could not have.
- **A self-test picture that looked like a bug.** Photographing ten windows outlasted the delay the
  next step ran on, so the pile was being taken apart while it was still being photographed. Pictures
  now hold the next step up until they are finished.

## Build 19 — 2026-09-26

### Added
- **The slogan, “Stick it. Stack it. Ship it.” (owner)**, in Comic Sans — the app's own hand, and the
  default note font. It heads the first-run card and sits under the icon in About, and nowhere else.
- **The tutorial can be dragged anywhere on screen and stays above every window (owner).** The whole
  page is a drag handle, so it can sit beside the thing it describes while the reader tries it.
  `isMovableByWindowBackground` does nothing here — the page is SwiftUI and takes the mouse first —
  so a drag layer sits behind the content.

### Changed
- **A more professional app icon (owner's own artwork)**, in the Dock, in the gallery and in About.
- **About is bigger (owner):** a 160pt icon over the name, the slogan, the version and build, and the
  licence, centred in a pane that was mostly empty.
- **The eye in every All Notes row says which notes are out (owner):** a note on the desk gets a
  plain eye, lit in the app's orange with a glow; a note that is not gets a struck eye, grey and
  unlit.

### Fixed
- **Every All Notes tab tooltip is drawn whole (owner).** The Templates tip hung off the window's
  left edge: build 18 hung the last two tabs' tips from their RIGHT edge, and a 180pt bubble does not
  fit to the left of a tab 150pt from the edge. Every tip now hangs from its own tab's left edge and
  runs right, into a window ten times wider than the strip.
- **A tooltip check that could not fail.** The self-test moved the tip on the model's side and
  photographed the same tab five times: a plain static does not make SwiftUI redraw. It now observes
  the change, and checks the frame each bubble actually landed in — all five, because a fix on one
  proves nothing about the rest.
- **Two checks that failed for want of focus now say `skipped`.** A paste that never reached the note
  and a `/find` check with no key window mean another app was in front; a false failure is as bad as
  a missed one.

## Build 18 — 2026-09-23

### Fixed
- **No real company name in the tutorial (owner).** Two slides carried a customer's name; the scenes
  are invented content now, and a check fails if those words ever return.
- **The tutorial's pictures are sharp.** They were being flattened to 72 dpi when saved, throwing
  away every Retina pixel; they are now written at 2x for windows and 3x for notes.
- **The All Notes tab tooltips are no longer cut off (owner):** the sidebar draws above the pane
  beside it, and a tip anchors to the side it is nearest instead of running off the left edge.

### Added
- **A calendar button beside a todo's due date (owner).** It carries the day; the field keeps the
  time of day.

## Build 17 — 2026-09-22

### Fixed
- **In a stack, the note clicked now comes forward even when macOS raises the clicked window late
  (owner, the bug behind every report).** A back note's title bar is covered by the margin of the
  note in front, so the press lands on that window; macOS raises it through the window server, and
  that can arrive after PinTack has already handed the click to the right note. The late event then
  dragged the receiving note forward instead. A click that has been handed on is remembered for a
  moment and such an event ignored, and the pile's window order is re-asserted twice more so a late
  raise cannot leave the wrong note drawn on top. Reproduced by raising the window late on purpose:
  6 of 12 clicks wrong before, 0 after.

## Build 16 — 2026-09-22

### Added
- **The stack click log also records what is DRAWN:** the front-to-back order the window server has,
  any window at a level of its own, and any member not on the desk. A pile whose order is right can
  still be drawn wrong, and only the log can say which it is on the owner's Mac.

## Build 15 — 2026-09-22

### Added
- **A stack click log** in `.pintack/stack-clicks.log` (Release builds too): one line per attempt to
  bring a note forward, with what asked for it and the pile before and after. A hundred simulated
  clicks at one a second found nothing wrong, so the owner's own clicks have to be recorded.
- **`scripts/stack-click-stress.sh`:** a hundred clicks on a pile of five, with a marker showing each
  one, checking the swap, the drawing, the window order and that nothing is left renaming.

## Build 14 — 2026-09-22

### Fixed
- **Clicking a stacked note's title twice dropped it into a rename (owner).** The title bar is how a
  note is brought forward in a pile, so the second click left the note in a text field and every
  click after that went into the field instead of the stack. In a stack the title bar only brings the
  note forward now; rename from All Notes or unstack first.
- **A click allows 6pt of drift rather than 4,** since a trackpad click drifts under a finger and
  those presses were read as drags of the pile.

## Build 13 — 2026-09-22

### Changed
- **Bringing a note forward in a stack is now a swap (owner).** The note you click trades places
  with the one in front and nothing else moves, so two clicks at the same place leave the pile as it
  was. It used to be pushed onto the front, which rotated everything in between and left the pile
  reshuffling under the pointer. ⌘1–⌘5 work the same way; ⌥Tab still walks the whole pile.

## Build 12-canary — 2026-09-22

### Fixed
- **In a stack, the note you clicked was not always the one that came forward (owner, twice).**
  macOS makes the window whose margin covers a back title bar key on the press — usually the note in
  front of the one aimed at — and that key event undid the hand-off a moment later: clicking #4
  brought #3 up. The self-test now clicks through a pile of five faster than it animates and checks
  that the note aimed at is the one in front; it failed three clicks in four before the fix.
- **A todo in a pile hung its action bar out below the front note**, a stray strip of another
  colour. Behind the front, a note no longer reserves room for a wrapped task tracker.

## Build 12 — 2026-09-22

### Added
- **Tutorial | Help (owner):** a button in the All Notes sidebar opens a presentation with one slide
  per feature, each showing a real screenshot of that feature in use. It plays itself every 5
  seconds until ‹ or › is pressed; OK and ✕ close it. The first-run card now offers it too, and both
  wear the app's dark indigo instead of the system's grey HUD.
- **`scripts/make-tutorial-shots.sh`:** the app photographs its own windows to make those pictures,
  so a slide can never show a version of PinTack that no longer exists.

### Fixed
- **Clicking a stacked note's title bar did nothing on its lower part (owner).** The front window's
  margin lies over the title bars behind it, and macOS gave those clicks to the front window, which
  dropped them. It now hands them on; the self-test routes clicks across every title bar the way
  macOS does, and fails without the fix.
- **All Notes row icons are in one order everywhere (owner):** show/hide, rename, Unstack, delete.
- **The Unstack strike crosses the paperclip** instead of running alongside it (owner).

### Added
- **`/stack`** opens the paperclip's stack popover, with the same rules (owner).

### Changed
- **Tooltips wait 1 second (owner),** and the All Notes tab glyphs show a bolder, orange tip after
  half a second.

## Build 11 — 2026-09-22

### Added
- **Stack delete asks three ways (owner):** Unstack (the default, on Return), Delete N Notes (red),
  Cancel (Esc), naming any folder the notes are filed in. The self-test presses Return on it.
- **All Notes row actions (owner):** Stacks rows get rename and Unstack; Templates rows show/hide,
  rename (the `@name`) and delete; Todos rows rename, show/hide and delete. The Todos checkbox is now
  a selection box, with **Mark Complete** and **Delete selected** at the bottom.
- **Tooltips on every control in All Notes and Settings (owner),** "Name | description", after 2 s.
- **The All Notes tab has the owner's sticky-pad glyph,** so it no longer shares the Stacks icon.
- **An orange pill behind a stack's name (owner),** black lettering, as wide as the name.
- **The product thesis** at the top of SPEC and README; CLAUDE.md tells sessions to check features
  against it.
- **`scripts/measure-memory.sh`** and its numbers in SPEC §17: about 37 MB per open note, 1.95 GB for 51.

### Changed
- **Stack numbers are places (owner):** the front note is always #1; ⌘N brings the note in place N
  forward. They used to stay with their notes.
- **The pushpin is 40% smaller (owner),** sitting where it did.
- **Glow strength goes to 200% (owner),** and a dark note's glow is light instead of invisible.
- The vim notice points long-form writing at Obsidian or VS Code; the Stacks tab has a tooltip.
- CONTRIBUTING's "Current state" matches build 10 and says Phase 5 has not started.

### Fixed
- **A note brought forward in a stack left the rest of the pile where it was (owner, serious).**
  macOS raises a clicked window on the press, and a click with a hair of movement counted as a drag.
  A click is now anything under 4 pt, and a back note that becomes the active window by any route
  brings the pile round behind it, with the spring.
- `stacks.json` is disposable: missing, unreadable, wrong-shaped or stale never blocks a launch or
  touches a note (tests added).

## Build 10 — 2026-09-22

### Added
- **Note Stacks (owner).** The paperclip beside a note's pushpin piles 2 to 5 open notes into one:
  every title bar shows, fanned above the front note, and a stack bar under its title bar holds the
  stack's name (double-click to rename), Unstack, pin, collapse and close. Title bars carry `#1`…`#5`,
  which stay with their notes; ⌘1–⌘5 bring a note to the front and ⌥Tab walks the stack. Dragging
  any title bar moves the pile; clicking a back one brings it forward. Unstack puts every note back
  where it was, at its own size. Stacks live in `.pintack/stacks.json`; the notes stay plain Markdown.
- **A Stacks tab in All Notes (owner):** list, search (by stack or by any note in it), show/hide,
  Add to Folder, and delete. Deleting a stack deletes its notes, always after a confirmation that
  says how many; Undo brings back the notes and the stack.
- **Tables are folds in vim mode (owner's idea).** The gutter shows `3 [+3]` beside a rendered table;
  `j` stands on it, then steps past it; `zo`, `za` or a click on `[+]` shows its Markdown, `zc` folds
  it back, `zR`/`zM` do every table. The vim notice says so.

### Fixed
- **Gutter numbers drifted below a rendered table (owner).** The editor's height map ignored the
  table's margin, and measured it mid pop-in animation, so every number underneath rode ~14px high.
  Block widgets now use padding and animate their contents; a late-loading picture asks for a
  re-measure. A self-test check measures every number against its line.

### Changed
- ⌘1–⌘5 rather than ⌥⇧1–5 for stack notes (owner): ⌥⇧2 is already the global Templates key.

## Build 9 — 2026-09-21

### Added
- **Vim mode (owner).** One switch in Settings → Editor, off by default. Notes start in NORMAL
  mode; the mode shows in the action bar. `:` and `/` turn the action bar into the command bar, with
  vim's own incremental search and history; `:w` saves, `:q` closes, `:wq`, `:x` and `ZZ` do both.
  A line-number gutter runs down the note, counting its visible lines. Built on
  `@replit/codemirror-vim` and `@codemirror/search` (both MIT, approved), vendored and loaded only
  the first time vim mode is switched on.
- **A one-time notice when vim mode is first switched on (owner).** It says plainly that pictures
  and tables are drawn as blocks, what moving through them does, and that Source mode (⌥⌘M) is the
  way out.
- **Line numbers in code blocks (owner)**, a setting under Code blocks, off by default.

### Fixed
- **`j`/`k` skipped whole tables and code fences** in vim mode — found while building it, before
  release. The engine took Live Preview's block widgets for folded text. Clamped to the next line.
- **Ending a `:` command by clicking away renamed the note** to what was typed — found while
  building it. The command field now cancels the prompt instead.
- **The PinTack window could open on Settings but keep drawing All Notes**, about one time in two
  when a setting had changed just before. SwiftUI dropped the tab change; a second nudge on the
  next run-loop turn fixes it, and the self-test now reads the pixels to prove which tab is drawn.

### Changed
- `scripts/vendor-codemirror.sh` pins every package version, so re-running it cannot quietly
  upgrade the editor.
- **Docs:** every Markdown file brought up to date with the app as it stands at build 8, and this
  changelog written. `KICKOFF-PROMPT.md` is kept verbatim as a historical record, with a note saying so.

---

## Build 8 — 2026-09-21

### Added
- **A new app icon (owner):** orange code brackets and a pencil on a purple note with a page curl,
  the owner's own design. Cropped to the artwork and filled edge to edge, so the system's rounded
  shape is the icon's edge rather than a plate around a smaller square; the base behind it is the
  window's dark indigo, which is what shows behind the curl. Previewed with Apple's `ictool` in light
  and dark before use. `01ac8e5`

### Fixed
- **Black lettering on every orange selection (owner).** The segmented choices (App theme, New notes
  get, Corners, Default mode, and a note's own Auto/Dark/Light) and the New note button were system
  controls, which draw the chosen item in the accent colour with **white** text that no tint can
  reach. They are now the app's own `ChromeSegmented` and `ChromeProminentButtonStyle`, with near-black
  lettering at 9 : 1 against the orange. The self-test now photographs every Settings pane in dark
  mode, so a stray one cannot hide on a pane nobody opens. `4e7e74b`

---

## Build 7 — 2026-09-21

The biggest single round: ten refinements the owner chose from a list, four more of his own, and a
run of bugs those turned up.

### Added
- **All Notes and Settings are one window (owner),** with two big tabs across its title bar. The old
  window controllers stay as thin fronts that pick a tab, so every shortcut and menu works as before:
  ⌥⌘H shows All Notes (and closes only when it is already in front), ⌘, shows Settings. Both tabs stay
  alive underneath, so a search or a Settings pane is still there on the way back. `72d9eb0`
- **A new look for that window (owner):** dark means a deep indigo (#141128) rather than system grey;
  light mode is a warm paper tone; every selection is a solid orange that springs to the new choice;
  Settings' sidebar glyphs are monochrome, outlined at rest and filled when chosen, with the coloured
  tiles gone. `72d9eb0`
- **A collapsed todo keeps its progress in the title bar (owner):** a plain progress bar, dull green
  with a bright glowing fill, then `3/7`. `444dc62`
- **A finished todo looks finished (owner):** a green ✓, the title struck through, and the note dimmed
  to 72%. Drawn, never written into the file. `236e5bc`
- **Hover to reveal (owner, off by default):** a faded note turns fully opaque while the pointer is
  over it. Settings → Notes → Faded notes. `c5c4d72`
- **Closing an empty note discards it (owner)** instead of leaving an empty `.md` behind. "Empty" is
  strict — no words, no name, not a template, no reminder, no user tag, nothing a plugin stored — and
  the file on disk must be empty too, so an edit another app just made is never lost. `a69e856`
- **Undo on delete, for five seconds (owner).** Puts back the same note, window and all. `6c6597a`
- **⌘↩ ticks or unticks the checkbox on the current line (owner).** `d66fd31`
- **Pick a tag's colour (owner):** click the dot on a chip in the tag editor for Automatic, ten
  presets or any colour. It applies to that tag everywhere. `d2d946f`
- **A strength control for the pinned glow (owner),** 25–160%. `1a66615`

### Changed
- **Reminder banners (owner):** titled "PinTack - @Todo", with the note's name as the body and no
  date, because the banner arriving is the date. `db62ea9`
- **Bigger, clearer controls (owner):** 13.5 pt glyphs in 24 pt buttons instead of 11 in 20; the
  snowflake was hard to make out. All sizes live in one table the layout maths also reads. `ccc05a5`
- **`verify.sh` now builds Release first.** See the fix below for why. `a67e200`

### Fixed
- **Settings wrote every value, chosen or not,** which froze the default in force on the day of first
  launch — anyone who had run an early build would never see new defaults such as 300 × 250 notes.
  Only real choices are written now; an old file holding a since-changed default is read as "not
  chosen". `43963d8`
- **Window fades and frame animations did not run at all while PinTack was not the active app** —
  which is most of the time, since notes never bring the app forward. Measured: a fade from 0.2 still
  read 0.2 a second later. Paths that set the value directly afterwards had hidden it. Window opacity
  and frames now animate on the app's own clock. `4e7f914`
- **Notes stranded on an unplugged display** now come back onto a screen while the app is running,
  not only at the next launch. `a39d4b8`
- **A frozen todo with a thick action bar could not be unfrozen from its snowflake:** the live spot was
  a fixed corner, and the snowflake had moved up with the extra tracker rows. It now follows the
  button. `207dc1a`
- **The self-test posted reminders to the logged-in user.** It shares a bundle identifier — and so a
  notification store — with any installed copy, so every run's sample todo fired a real banner an hour
  later, and its launch tidy-up deleted the user's own pending reminders. The self-test now uses an
  in-memory store. `7cbfdfa`
- **All Notes covered its own Undo toast** with a second "Moved to Trash" message. `72d9eb0`
- **Release builds were broken for six commits** without anything noticing: a rect the freeze feature
  needs had landed among the debug-only helpers, and a second copy sat silently inside a nested
  function. Found only when the DMG would not build — hence the Release step in `verify.sh`. `a67e200`
- Tag pills lost a point of padding so a second line of tags fits beside a wrapped tracker. `ccc05a5`

---

## Build 6 — 2026-09-20

### Changed
- **Fenced code gets its own dark panel (owner)** on every note, with a colour and opacity setting
  beside inline code's. The token colours now follow the **panel** rather than the note's paper — a
  dark panel on a light note needs light tokens — decided by compositing the panel over the note's
  colour. The language badge had to follow too, or it came out dark on dark. `a47c00b`
- **A blockquote's bar is bright red (owner).** `a47c00b`

---

## Build 5 — 2026-09-20

### Added
- **A one-screen welcome on first launch (owner),** dismissed with OK. "Once" is a marker file in the
  vault, written when it is shown so a crash before OK does not greet you again. `add492c`

### Changed
- **New notes default to 300 × 250 (owner).** 300 is the narrowest width where a todo's bar fits six
  squares, the count and a tag pill together. `add492c`
- The self-test takes the foreground before starting; several checks read the key window. `add492c`

---

## Build 4 — 2026-09-20

### Fixed
- **The todo tracker only appeared after reopening the note,** and past about seven items it vanished,
  taking the tags with it. It now appears with the first checkbox, wraps at six squares a row with no
  limit on rows **(owner)**, and the action bar grows **downward (owner)** so the text never shrinks;
  tags wrap into the extra height but never add to it. `2dcdb7a`
- **The reminder panel's Done button left it on screen,** and typing "37" into the minutes field gave
  7. Both were SwiftUI re-rendering on every keystroke; the date now lives outside SwiftUI's state in
  a real `NSDatePicker`. `2dcdb7a`

---

## Build 3 — 2026-09-20

Three bugs found on a tester's Mac.

### Fixed
- **The slash menu's selected row was black on black** with some outline colours: it used the note's
  accent, whose low-contrast fallback is near-black. Menus now use the app's own fixed orange — the
  second time that bug class appeared. `8de7311`
- **A bare `@` listed no templates;** it now lists them all, the way `/` lists commands. `8de7311`
- **"Show all notes on desktop" became a toggle (owner)** named Show/Hide Opened Notes. `8de7311`

---

## Build 2 — 2026-09-19 to 2026-09-20

The first build that went to another Mac, and everything added over the following day before build 3.

### Added
- **Syntax highlighting for fenced code**, for every language CodeMirror ships, loaded only when a note
  uses one — a note with no code loads nothing extra. `6670ae1`
- **Language logos on code blocks** (Devicon, MIT) with the language name, and no pill behind them
  **(owner)**. `c71132c`, `c856268`
- **Tags as coloured pills** in the action bar, the colour from a stable hash of the name so a tag looks
  the same everywhere and after a relaunch. A `+N` pill opens the rest. `3544e74`, `d847ee0`
- **A note's title and first line separate once you rename it (owner):** renaming writes `title:` into
  the frontmatter and never rewrites what you wrote. `bad1f48`
- **Link previews** for a URL on its own line — off by default, the only feature that contacts a
  website, fetched in Swift and never in the page. `05efc41`
- **Image editing inside the note (owner):** click an image for corner handles, a crop tool and a bin,
  with nothing to type; a crop writes a new file and never overwrites the original. This replaced a
  crop-before-paste dialog the owner rejected. `e86d24e`, `c856268`, `e8cdb06`
- **Paste rich text as Markdown:** headings, links, lists and tables survive a paste from a browser or
  mail; ⇧⌘V pastes plain text. `a8be25d`
- **Freeze mode:** a note that lets clicks pass through it, with a live snowflake as the way back — by
  polling the pointer, because the alternative needs Accessibility permission. `2ae1bc9`
- **Due dates and reminders** for todo notes, stored in the note so a reminder travels with it;
  notification permission is asked when a reminder is first set, never at launch. `6a85b5b`
- **Todo progress** as squares in the note, and a todo tab in All Notes with four sort orders.
  `382f423`
- **`/find`**, quick open across every note, which deliberately leaves your caret where it was.
  `54f4765`
- **Quick capture from any app** through the Services menu and ⌥⌘C, with no Accessibility permission.
  `7817dcc`
- **Templates**, recalled anywhere with `@name`; **`@todo`** turns any note into a todo; a templates tab.
  `60cc98d`
- **Five new shortcuts** (⌥⌘D delete, ⌥⌘T by tag, ⌥⇧T todos, ⌥⇧2 templates, ⌥⇧= show all) and a tooltip
  per All Notes tab. `f6dfa5a`
- **Lively animation (owner):** real spring physics for windows, back-out curves in the page, springing
  popovers, a cross-fading action bar, and a note scrollbar that stays out of sight until wanted.
  `95e6ff0`, `3d426c6`, `9f1cbb8`
- **A styled disk image** with a laid-out window and the Gatekeeper instructions on its background.
  `570e8a0`, `a15a211`
- **`scripts/verify.sh`**, one command that says whether the build is broken. `0dd039d`

### Changed
- **The app icon became an Icon Composer document,** full-bleed art so no system plate shows in the
  light icon style. `3a3844b`, `570e8a0`
- **The self-test became assertions.** It had been prose a person had to read and judge; now every fact
  is a check and the run exits non-zero on a failure. `0dd039d`
- **SPEC.md rewritten to describe the app as built,** instead of the plan it started as. `LICENSE`
  (GPL-3.0) added. `2f52c6c`

### Fixed
- **⌥⌘K collapsed a note and immediately expanded it again:** one key press arrives by two paths, and a
  slow animated resize let the second copy slip past the de-duplication. It now de-dupes on the
  identity of the key event itself. `d791149`
- **The Dock showed one icon and then swapped to another,** and Spotlight listed PinTack twice. `3a3844b`,
  `7ace194`
- **Cropping a Retina image came out black** (pixel and point space confused), and the crop ✓ and ✕
  could not be clicked (a shade layered over them). `c856268`, `e8cdb06`
- **"Find unused attachments" could offer pictures still in use** for deletion; it now reads the files
  on disk and refuses to act when it read no notes. `898b10e`
- **Deleting a note left its reminders scheduled,** and a failed save was silent. `0dd039d`
- A quote in a title grew a backslash on every save. `bad1f48`

### Decided against (owner)
- **Wikilinks and backlinks, note version history, sync conflict resolution** — scope creep for a
  sticky-note app. Obsidian exists for the rest.

---

## Build 1 — 2026-09-19

The app goes from a specification to something that runs.

### Added
- **A Live Preview editor:** CodeMirror 6 vendored as plain ES modules with an import map, so there is
  no bundler dependency; markdown renders as you type with raw syntax only on the caret's line. `e270620`
- **The app rebuilt around it in one pass, Phases 1–3 (owner overrode the one-phase-at-a-time plan):** a
  Dock app with a menu-bar item; note panels with the 24 pt transparent margin so a pushpin can
  overhang the card; the All Notes window with folders, tags and FTS5 search; Settings; rebindable
  hotkeys; import and export; an external-edit watcher; and a Debug self-test that renders the app's own
  windows. The vault keeps unknown frontmatter verbatim and preserves Windows line endings. `d027e29`
- **Owner feedback, first round:** notes drag by the title and rename on double-click; an action bar
  with formatting tools; Auto/Dark/Light palette per note with automatic text colour; `@Todo` notes;
  Comic Sans MS as the default font; Settings in a sidebar. `2615955`
- **The owner's pushpin art,** a glow in the note's own colour, the note's own right-click menu, folders
  and multi-select in All Notes, and colour commands like `/red`. `6024ae1`
- **The plugin system and Runner (Phase 4, minus the widget):** JavaScript plugins with no filesystem
  or network access; security enforced in Swift with per-page tokens, declared permissions and a
  native approval sheet no plugin can answer; trust bound to the exact command and folder and signed
  with a per-Mac secret. Runner is written only against the public API. `d160655`

### Fixed
- Shortcut reliability: held keys, two paths for one press, and rapid new-note presses. `6024ae1`
- Settings and All Notes stopped taking the note-outline colour, after a dark outline made them
  unreadable. `6024ae1`
- An outside edit that un-hid a note now opens its window. `08dc244`

### Started from
- `SPEC.md`, an interaction prototype (`docs/assets/tack-prototype.html`), and about 940 lines of Phase 1
  Swift written without a compiler. The project owner is not a Swift developer; everything since was
  built by an AI coding agent under his direction and checked by running it, not by reading it.
  `0dd3f81`

---

## Not built yet

The WidgetKit widget (shelved until a signing team is chosen), Developer ID signing and notarization,
Sparkle updates, a Homebrew cask, and the App Sandbox. See `SPEC.md` §16–17.
