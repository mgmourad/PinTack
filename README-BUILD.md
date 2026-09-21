# Building PinTack

Requires Xcode 16 or later and macOS 14+. Node is only needed to *re-vendor* the editor;
building the app does not use it.

```bash
xcodebuild -scheme PinTack -configuration Debug SYMROOT="$PWD/build" build
open build/Debug/PinTack.app

xcodebuild -scheme PinTack SYMROOT="$PWD/build" test          # unit tests only
scripts/verify.sh                                              # Release build + unit tests + self-test
```

`scripts/verify.sh` is the one that says whether a change is safe. It builds **Release** first,
because the self-test and every debug hook are compiled out of it: code that leans on one of them
builds in Debug and nowhere else.

**Always build into `build/`** (`SYMROOT`). A second copy of the app in DerivedData makes
LaunchServices list it twice (Spotlight shows PinTack twice) and can serve an old icon.

The app is ad-hoc signed (no Apple Developer account needed) and unsandboxed, and keeps
its notes in `~/Documents/PinTack/`. It shows a Dock icon and a pushpin in the menu bar, and on the
very first launch a one-screen welcome.
If you cannot see the pushpin, a menu-bar manager (Thaw, Bartender, Ice) or the MacBook
notch has probably pushed it out of view; check that tool's hidden section.

## Making a DMG to test on another Mac

```bash
scripts/make-dmg.sh        # -> dist/PinTack-<version>.dmg (universal, ad-hoc signed, NOT notarized)
```

A styled disk image: the app and an Applications alias on a paper background, laid out by Finder and
checked by the script afterwards. The app inside is about 14 MB; the image about 6 MB. Tester builds
so far live in `dist/tester-build-<n>/`, one folder per build number.

The other Mac's Gatekeeper blocks the first launch until notarization exists (Phase 5); the DMG's
background explains the ways past it (right-click → Open is the simplest).

## Layout

| Path | What |
|---|---|
| `PinTack/` | Swift sources (Xcode folder-synchronized: new files are picked up automatically) |
| `PinTack/Vault/` | Notes as Markdown files: parsing, atomic writes, search index, file watcher, import/export |
| `PinTack/Windows/` | Note panels (24pt transparent margin, SPEC §5.2), editor host, popovers |
| `PinTack/Central/` | The one window (`MainWindow.swift`) with its All Notes tab, its look (`ChromeTheme.swift`), todo progress views |
| `PinTack/Settings/`, `Hotkeys/`, `App/` | The Settings tab, shortcuts, app shell, first-run welcome |
| `PinTack/Support/` | Motion (window animation on the app's own clock), reminders, toasts, the Debug self-test |
| `Editor/` | The Live Preview editor (HTML/JS/CSS), copied into the app as a folder |
| `Editor/vendor/` | CodeMirror 6, vendored (MIT). Regenerate: `scripts/vendor-codemirror.sh` |
| `PinTackTests/` | Unit tests (230): the vault and its formats, import safety, blank-note discard, settings, tag colours, reminders, plugin security |
| `Plugins/runner/` | The bundled Runner plugin, written only against the public API |
| `docs/assets/` | The icon as rendered for the README, its source art, the DMG background, the original HTML prototype |
| `PinTack/AppIcon.icon` | The app icon, an Icon Composer document — preview with `ictool` (see CLAUDE.md) |

## Working on the editor without the app

```bash
node scripts/dev-server.mjs          # http://localhost:8765
```

Drive it from the browser console with `window.__pintack.receive({type:"note.load", ...})`.

## Checking what the app really draws

Debug builds can render their own windows to PNG and write a report, no screen-recording
permission needed. See "Seeing what is on screen" in `CLAUDE.md`.
