<div align="center">

<img src="assets/icon/pintack-icon.png" width="128" alt="PinTack">

# PinTack

**Sticky notes for macOS, with Obsidian's editing model and a plugin system.**

Plain Markdown files. Live Preview rendering. An interactive desktop widget.
Open source, GPL-3.0.

`Status: pre-implementation. Specification complete, no code written yet.`
`Seeking a macOS developer to own the codebase.`

</div>

---

## Why this exists

A commercial sticky-notes app on the Mac App Store does the basics well and sits around #58 in Productivity with a 4.2-star rating. It is also roughly 377 MB, which is what an Electron bundle costs you.

Its users have been asking the same things for years: a hotkey to start a note, a pin to float it on top, an opacity slider, a central window listing every note, folders, tags, widgets, and a way to get your data out. The requests go unanswered, and the architecture is most of the reason why. WidgetKit is effectively out of reach from Electron. Native window levels and non-activating panels are awkward through a browser abstraction.

PinTack is the native answer to that feature list. Expected bundle size is 10 to 25 MB.

## What makes it different

### 📝 Live Preview markdown

Formatting renders as you type. Raw syntax appears only on the line holding your cursor. Same model Obsidian uses, applied to sticky notes. This is the primary quality bar for v1: if Live Preview feels janky, the product has failed regardless of what else ships.

### 🧩 An interactive widget

Tick a checkbox on a desktop widget without opening the app. Apple's own Notes widget is read-only, Windows Sticky Notes has nothing, and no competitor in this category ships one at all.

### 🗄️ Your notes are files

```
~/Documents/PinTack/
├── Work/
│   └── 2026-09-19-sprint-blockers.md
├── attachments/
│   └── 2026-09-19-142233.png
└── plugins/
    └── runner/
```

Real Markdown with YAML frontmatter, in a folder you can open in Finder. Which means:

- **Export is not a feature.** The files are the export. Zip the folder.
- **Sync is not a feature.** Put the vault in iCloud Drive, Dropbox, or Syncthing.
- **The data outlives the app.** If this project dies, you still open your notes in any text editor.

For a project whose origin story is "the incumbent stopped listening," shipping a format that traps users would be incoherent.

### 🔌 Plugins, with one in the box

JavaScript plugins with a documented API. v1 ships **Runner**: inline buttons in your notes that execute a script, open a URL, reveal a path in Finder, or fire a macOS Shortcut.

````markdown
```runner
label: Rebuild search index
run: ~/bin/reindex.py
```
````

Language agnostic. If the dependencies are on your machine, it runs. Every command requires explicit first-run approval, trust is bound to the exact command string, and editing a command resets its approval. No autorun exists, and no flag adds one.

Runner is built strictly against the public plugin API with no private hooks into the core. That is the only way a reference plugin proves anything.

## Feature list

| | |
|---|---|
| ✍️ Editing | Live Preview markdown, Source mode toggle, slash commands, image paste and drag-drop, clickable task checkboxes, syntax-highlighted code blocks, tables |
| 🪟 Windows | Floating non-activating note panels, pin-on-top with a skeuomorphic pushpin, per-note opacity, collapse, auto-arrange, cross-Space visibility |
| 🎨 Appearance | Light/dark app theme independent of note colors, arbitrary note colors with automatic text contrast, configurable outline color and width, rounded or square corners |
| 🗂️ Organization | Central window with Folders and Tags as separate views, full-text search, show/hide per note |
| ⌨️ Keyboard | System-wide hotkeys with no Accessibility permission required, fully rebindable with a recorder UI |
| 🧩 Extension | WidgetKit widget with AppIntents write-back, JavaScript plugin API, Runner bundled |

## Architecture in one paragraph

A Swift/AppKit shell hosts one `NSPanel` per note. Each panel embeds a `WKWebView` running CodeMirror 6, which provides Live Preview and doubles as the plugin execution context. A `VaultStore` owns all file I/O against the Markdown vault, with an FSEvents watcher and an SQLite FTS5 search index that is fully disposable. A WidgetKit extension reads a denormalized snapshot through an App Group container.

**`WKWebView` is not Electron.** It uses the WebKit already installed in macOS. Nothing is bundled, which is the entire difference between 15 MB and 377 MB.

Full detail in **[SPEC.md](SPEC.md)**, which is written for a developer picking this up cold.

## Status and roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Shell, vault, note panels | Not started |
| 2 | CodeMirror editor, Live Preview | Not started |
| 3 | Central window, search, settings, hotkeys | Not started |
| 4 | Widget, plugin API, Runner | Not started |
| 5 | Signing, notarization, distribution | Not started |

Estimated 3 to 4 months for one competent macOS developer working steadily.

## 🙋 Wanted: a maintainer

Honest framing, because vague calls for help waste everyone's time.

**What exists:** a complete technical specification, a working interaction prototype, documented unmet demand from a maintained competitor's reviews, a name, a domain, and funding for the Apple Developer membership.

**What does not exist:** a single line of Swift.

**Who owns what:** the project originator handles product direction, positioning, assets, and funding. He is a Windows endpoint automation engineer, not a Swift developer, and is explicit that he will not be maintaining the codebase. A technical maintainer takes ownership of the code and a real stake in the project's direction.

**Why this is worth your time:** the hard thinking is done. Most open source projects hand you an idea and a shrug. This one hands you a spec that already answers the structural questions, including the ones that bite in month two: the transparent-margin window architecture, the Team-ID-prefixed App Group requirement that silently kills widgets, the shell PATH problem for GUI-launched processes.

**What this is not:** a paid contract, a startup, or a company. It is an open source project looking for someone who wants to own a well-specified Mac app.

Open an issue or start a discussion if you are interested.

## Building

Nothing to build yet. When Phase 1 lands:

```bash
git clone https://github.com/<org>/pintack.git
cd pintack
open PinTack.xcodeproj
```

Requires Xcode 16+ and macOS 14+. A free Apple ID is sufficient for local development; the paid Developer Program membership is only needed to produce notarized releases.

## Distribution

Not the Mac App Store, and this was settled twice over: a sandboxed app cannot spawn user processes, which rules out Runner, and GPL-3.0 is independently incompatible with App Store terms.

Releases will ship as a notarized DMG, a Homebrew cask, and GitHub Releases, with Sparkle for auto-updates.

## License

**GPL-3.0-or-later.**

You can do anything you like with this code, including sell it. What you cannot do is close it. Any distributed derivative must ship complete source under the same license, so improvements come back to everyone.

Plugins that communicate solely through the documented public API are not considered derivative works and may be licensed however their authors choose.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Plugin authors, start at [SPEC.md §12](SPEC.md#12-plugin-api).
