# Claude Code kickoff prompt

> **Historical — kept as it was.** This is the first message that started the build on 2026-09-19,
> when PinTack was a specification and ~940 lines of Swift that had never been compiled. It is not
> instructions for today: the app has since been built, rebuilt and taken to a beta (0.1.0, build 8).
> For where things stand read `CLAUDE.md`; for how it got there read `CHANGELOG.md`. Several things
> below were later changed on purpose — PinTack is a Dock app rather than a menu-bar-only one, and
> the owner overrode the "stop after Phase 1" instruction — and those decisions are recorded there.

Paste everything below the line into Claude Code as your first message, after
you have put the artifacts in the project folder.

---

I'm building PinTack, an open-source macOS sticky-notes app. I need you to get it
compiling and running.

Important context about me: **I don't write Swift.** I'm a Windows endpoint
automation engineer. I'm fluent in PowerShell, Intune, SCCM, Azure DevOps and
Terraform, and I can read infrastructure code all day, but I cannot check your
Swift syntax or tell you whether an AppKit call is correct.

That means I need you to work differently than you might with a Swift developer:

- Don't tell me code "should work." Run `xcodebuild` and tell me what actually
  happened. If it fails, fix it and build again.
- When something runs, launch it and describe the observable behavior, because
  that's the only layer I can validate.
- Explain your decisions in plain language. Infrastructure analogies help.
- If you think I'm wrong about something, say so directly. I'd much rather be
  corrected than agreed with.
- Ask before changing UX, naming, or feature scope. Those are mine.

## What's in this folder

- **`SPEC.md`** — the complete technical specification. This is the source of
  truth. Read it before implementing anything.
- **`CLAUDE.md`** — project constraints, three documented platform traps, and how
  I want you to work. Read this first.
- **`PinTack/`** — roughly 940 lines of Phase 1 Swift that has **never been
  compiled**. It was written without a Swift toolchain. Expect errors.
- **`README-BUILD.md`** — setup steps and the four failures I was told to expect.
- **`README.md`, `CONTRIBUTING.md`, `.gitignore`** — repo files, already written.
- **`tack-prototype.html`** — an interaction prototype. Open it in a browser to
  see the intended UX. It is not the app, but it shows what I'm aiming for.

## Start here

Please do these in order, and stop after each to tell me what happened:

1. **Read `CLAUDE.md`, then `SPEC.md` sections 1 through 5.** Then tell me, in
   plain language, whether the architecture makes sense to you and what you'd
   push back on. I want your honest technical read before we build anything. If
   something in the spec is wrong or impractical, now is the cheapest time to
   find out.

2. **Set up the Xcode project.** macOS App, SwiftUI lifecycle, bundle identifier
   `io.cymentix.pintack`, deployment target macOS 14.0, App Sandbox off for now,
   `LSUIElement` set so it runs as a menu bar app with no Dock icon. Wire in the
   four existing Swift files. Initialize git and make the first commit.

3. **Get it compiling.** Work through the errors. Show me what you changed and
   why, briefly. Don't rewrite the architecture to make errors go away: the
   transparent-margin window design and the Carbon hotkey handler are deliberate
   and documented in `CLAUDE.md`. If one of them genuinely cannot work, tell me
   rather than quietly replacing it.

4. **Run it and tell me what you see.** I'm expecting: a pin icon in the menu
   bar, a welcome note floating on the desktop, ⌥⌘N creating a new note from
   inside any other app, and a real `.md` file appearing in
   `~/Documents/PinTack/` after I type.

5. **Then stop.** Don't start Phase 2. Let me click around first.

One more thing: commit early and often, small commits with clear messages.
`git revert` is realistically my only undo, so I need the history to be useful.
