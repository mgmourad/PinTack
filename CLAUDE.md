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
   are pre-approved. Nothing else is.
3. **No network access from the app**, ever, except Sparkle update checks.
   The webview CSP forbids remote resource loading and this will not be relaxed.
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
xcodebuild -scheme PinTack -configuration Debug build
xcodebuild -scheme PinTack test
open build/Debug/PinTack.app        # or run from Xcode
```

Phase 1 runs **unsandboxed** and reads `~/Documents/PinTack/` directly.
Sandboxing needs a security-scoped bookmark flow that is deferred.

**After any change touching windows, the vault, or the plugin API, build and
launch before reporting back.** Describe what actually happened on screen.

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

Existing Phase 1 source in `PinTack/` was written without a Swift compiler and
has never been built. Treat it as a detailed draft. Expect compile errors. Fixing
them is the first task, not a sign the design is wrong.
