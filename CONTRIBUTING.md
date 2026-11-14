# Contributing to PinTack

Thanks for looking. This document covers three audiences: people who want to own or build the core, people who want to write plugins, and people who want to help without writing Swift.

---

## Before anything else: read the spec

**[SPEC.md](SPEC.md)** is the source of truth. It is long, and that is deliberate: it exists so a developer can start without needing a conversation with anyone.

Three sections in particular will save you time, because each documents a problem that is expensive to discover late:

- **§5.2 — The transparent margin.** Note windows are 24pt larger than their visible card on every side, so the overhanging pushpin and the outer glow can be drawn outside the card edge. This forces custom hit testing, a manually drawn shadow, and frame math that operates on the card rect rather than the window rect. Read this before writing any window code.
- **§11.2 — The App Group trap.** On macOS, app group identifiers must be prefixed with the Team ID. An unprefixed identifier is rejected by `containermanagerd`, the widget process exits immediately, and the widget never appears in the gallery with no useful error surfaced to the user. The group identifier must additionally be resolved at runtime from the app's own entitlements, because the Team ID changes when the project moves from a free personal team to a paid one.
- **§13.5 — The shell PATH problem.** GUI applications on macOS do not inherit the shell's `PATH`. Launch the app from the Dock and `python3` will not resolve even though it works in Terminal. Runner executes through the user's login shell so profile scripts are sourced.

---

## Current state

**Built and running** (0.1.0, build 24), used so far only by its owner; build 23 was the first meant
for outside testers. Phases 1–4 are complete: the vault,
note windows, Live Preview editor, todos and reminders, Note Stacks, vim mode, All Notes and Settings in
one window, hotkeys, and the plugin system with Runner. **Phase 5 has not started**: Developer ID
signing, notarization, Sparkle and the Homebrew cask. Also not built: the WidgetKit widget (shelved
until there is a paid signing team) and the App Sandbox. [CHANGELOG.md](CHANGELOG.md) records every change and why it was made.

The project is looking for a **maintainer** to own the codebase, not just occasional contributions. See the README for the honest framing on what exists and what does not.

If you are interested in that role, open a discussion rather than a pull request. The first conversation should be about whether the code and the architecture in SPEC.md are ones you would actually want to own, including the parts you would change. Disagreement with the spec is not disqualifying; it is the most useful thing you can bring.

---

## Core development

### Requirements

- Xcode 16 or later
- macOS 14 (Sonoma) or later
- A free Apple ID is sufficient for local builds. The paid Developer Program membership is needed only for notarized releases.

### Build

```bash
git clone https://github.com/mgmourad/PinTack.git
cd PinTack
xcodebuild -scheme PinTack -configuration Debug SYMROOT="$PWD/build" build
open build/Debug/PinTack.app        # or open PinTack.xcodeproj
```

Always build into `build/` (`SYMROOT`). A second copy in DerivedData makes Spotlight list PinTack twice.

### Code style

- Swift API Design Guidelines. No house dialect.
- There is no formatter config and no CI yet. Match the code around you.
- Prefer clarity over cleverness. This project expects to change maintainers at least once, so code that requires its author to explain it is a defect.

### Comment policy

Comment the *why*, never the *what*. Specifically, any code working around a platform constraint must carry a comment naming the constraint and linking to the relevant SPEC.md section or Apple documentation. The transparent margin, the App Group prefix, and the login shell invocation all look like mistakes to a reader who does not know why they are there.

### Commits and branches

- Conventional commits: `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`
- Branch from `main`, one logical change per PR
- PRs touching window management, the vault format, or the plugin API need explicit sign-off, because all three are expensive to change after release

### Testing

**One command says whether the build is broken:**

```bash
scripts/verify.sh
```

It builds Release (what ships — the self-test and every debug hook are compiled out of it, so code
that leans on one builds in Debug and nowhere else), runs the unit tests, and runs the **self-test**:
the Debug app launches against a throwaway vault, drives its own windows and web views with real
events, asserts what happened, and exits non-zero on any failed check. If you add behaviour, add a
check. `CLAUDE.md` explains how to read its screenshots and what it cannot reach (a real pointer,
clicks on SwiftUI buttons, VoiceOver).

- Unit tests for anything that parses or writes vault files. Frontmatter round-tripping, unknown-key preservation, and atomic write behavior are non-negotiable: a bug here is user data loss.
- The search index is disposable by design. Test that a missing, corrupt, or stale-schema index rebuilds rather than blocking startup.
- Manual test matrix for window behavior: multiple displays, display disconnection (the self-test simulates it, but not with real hardware), Spaces, full-screen apps, and Stage Manager.

---

## Plugin development

Start at **[docs/PLUGINS.md](docs/PLUGINS.md)**, the author's guide, then [SPEC.md §12](SPEC.md#12-plugin-api) for the security model, then read the bundled Runner plugin (`Plugins/runner/`) as a worked example.

### Structure

```
<vault>/plugins/my-plugin/
├── manifest.json
├── main.js
└── styles.css        (optional)
```

### Rules

- **No direct filesystem access and no network access.** Everything routes through the vault API and the host bridge. The webview content security policy forbids loading remote resources, and this will not be relaxed.
- **Declare your permissions in the manifest.** They are surfaced to the user at enable time and enforced on the Swift side. A plugin without `process.execute` cannot invoke the execution bridge no matter what its JavaScript attempts.
- **`onunload` must be complete.** Plugins are enabled and disabled at runtime. Leaked listeners, decorations, or timers are bugs.
- **Preserve unknown frontmatter.** If you write to a note, keys you do not recognize must survive untouched. Other plugins own them.

### Licensing

Plugins communicating solely through the documented public API are not considered derivative works of PinTack and may be licensed however you choose.

### If the API is missing something

Open an issue. The correct fix is to extend the public API, not to reach around it. Runner was built under exactly this constraint, which is the only reason the API can be trusted to be sufficient.

---

## Contributing without writing Swift

Genuinely useful, genuinely wanted:

- **Documentation.** Plugin authoring guides, usage docs, and the eventual website.
- **Design.** The app icon and the pushpin are the owner's own art (SPEC.md §15.2 and §18). Design help is still welcome for the widget, the website and the DMG.
- **Testing.** Tester builds exist (the DMG from `scripts/make-dmg.sh`; until notarization, right-click → Open on first launch). Exercising the window behavior matrix above on hardware the maintainers do not have is genuinely useful.
- **Plugins.** The fastest way to prove the plugin API works is for someone outside the project to build something with it.

---

## Reporting issues

For bugs, include macOS version, PinTack version, and reproduction steps. For anything involving notes, attach the note's raw Markdown rather than a screenshot; the frontmatter is usually where the answer is.

For Runner issues, **redact your commands** before pasting logs.

---

## Code of conduct

Be decent. Disagree about the work, not about the person. Maintainers may remove anyone who makes the project worse to participate in, and will not be arguing about where the line is.
