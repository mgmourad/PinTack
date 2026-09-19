# PinTack — Phase 1 source

**⚠️ This code has never been compiled.** It was written on Linux with no Swift
toolchain, no macOS SDK, and no Xcode. Treat it as a detailed starting point, not
working software. Expect compile errors on the first build. That is normal and
expected, not a sign it is wrong in concept.

## What Phase 1 covers

| Feature | Status |
|---|---|
| Markdown vault at `~/Documents/PinTack/` | ✅ |
| YAML frontmatter read/write, unknown-key preservation | ✅ |
| Atomic saves (temp file + `replaceItem`) | ✅ |
| Floating note panels with transparent margin | ✅ |
| Custom hit testing so the margin does not eat clicks | ✅ |
| Pin on top, with glow and an overhanging pushpin | ✅ (vector stand-in for the PNG asset) |
| Per-note color with automatic text contrast | ✅ |
| Drag by header, header context menu | ✅ |
| Debounced autosave (800 ms) | ✅ |
| `⌥⌘N` system-wide hotkey via Carbon | ✅ |
| Menu bar item | ✅ |
| Live Preview markdown editor | ❌ Phase 2 (`NSTextView` placeholder for now) |
| Central window, search, tags | ❌ Phase 3 |
| Widget, plugins, Runner | ❌ Phase 4 |

## Setup

1. Xcode → **New Project → macOS → App**
   - Product Name: `PinTack`
   - Organization Identifier: `io.cymentix`
   - Interface: **SwiftUI**, Language: **Swift**
2. Delete the generated `ContentView.swift` and `PinTackApp.swift`.
3. Drag the four files in `PinTack/` into the target.
4. In **Signing & Capabilities**, **turn App Sandbox off** for now. Phase 1 reads
   `~/Documents` directly; sandboxing needs a security-scoped bookmark flow that
   is not worth building yet.
5. In **Info.plist**, add `Application is agent (UIElement)` = `YES` so it runs
   as a menu bar utility without a Dock icon.
6. Set the deployment target to **macOS 14.0**.
7. Build and run.

## What you should see

A pin in the menu bar. A welcome note floating on the desktop. `⌥⌘N` creates a
new note from anywhere, even when another app is focused. Type in a note, wait a
second, then open `~/Documents/PinTack/` in Finder: the `.md` file is there with
your text in it. Quit and relaunch; notes return where you left them.

Click the pin button in a note's header. It should rise above other windows and
gain a glow.

## Likely first-build problems

- `NSMenu.addItem(withTitle:action:keyEquivalent:)` returns a non-optional
  `NSMenuItem`; if the compiler disagrees about the `.target` chain, split those
  lines into a local variable.
- `MenuBarExtra` plus `NSApplicationDelegateAdaptor` occasionally needs the
  delegate's `applicationDidFinishLaunching` to defer window creation by one
  runloop turn. If notes do not appear at launch, wrap
  `WindowManager.shared.restoreVisibleNotes()` in `DispatchQueue.main.async`.
- The Carbon event handler closure is a C function pointer and cannot capture
  context. It is written that way deliberately; if you refactor it, keep it
  capture-free.
- SF Symbols names (`pin`, `xmark`, `pin.fill`) are correct as of macOS 14 but
  verify in the SF Symbols app.

## Fixing it

The fastest loop is Claude Code in the project directory: it reads the errors
from `xcodebuild`, edits the files, and rebuilds. That loop is what turns this
from a draft into something that runs.
