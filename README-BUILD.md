# Building PinTack

Requires Xcode 16 or later and macOS 14+. Node is only needed to *re-vendor* the editor;
building the app does not use it.

```bash
xcodebuild -scheme PinTack -configuration Debug SYMROOT="$PWD/build" build
open build/Debug/PinTack.app

xcodebuild -scheme PinTack SYMROOT="$PWD/build" test          # unit tests
```

The app is ad-hoc signed (no Apple Developer account needed) and unsandboxed, and keeps
its notes in `~/Documents/PinTack/`. It shows a Dock icon and a pushpin in the menu bar.
If you cannot see the pushpin, a menu-bar manager (Thaw, Bartender, Ice) or the MacBook
notch has probably pushed it out of view; check that tool's hidden section.

## Layout

| Path | What |
|---|---|
| `PinTack/` | Swift sources (Xcode folder-synchronized: new files are picked up automatically) |
| `PinTack/Vault/` | Notes as Markdown files: parsing, atomic writes, search index, file watcher, import/export |
| `PinTack/Windows/` | Note panels (24pt transparent margin, SPEC §5.2), editor host, popovers |
| `PinTack/Central/`, `Settings/`, `Hotkeys/`, `App/` | All Notes, Settings, shortcuts, app shell |
| `Editor/` | The Live Preview editor (HTML/JS/CSS), copied into the app as a folder |
| `Editor/vendor/` | CodeMirror 6, vendored (MIT). Regenerate: `scripts/vendor-codemirror.sh` |
| `PinTackTests/` | Unit tests for the vault, formats, import safety, shortcuts, settings |
| `docs/assets/` | Icon source and the original HTML prototype |

## Working on the editor without the app

```bash
node scripts/dev-server.mjs          # http://localhost:8765
```

Drive it from the browser console with `window.__pintack.receive({type:"note.load", ...})`.

## Checking what the app really draws

Debug builds can render their own windows to PNG and write a report, no screen-recording
permission needed. See "Seeing what is on screen" in `CLAUDE.md`.
