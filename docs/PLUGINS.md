# Writing a PinTack plugin

A plugin is a folder of plain JavaScript in `<vault>/plugins/<id>/`. There is no build step and no
marketplace: drop the folder in, open **Settings → Plugins**, choose **Rescan**, and switch it on.

The bundled **Runner** plugin (`Plugins/runner/`) is written only against the API below and is the best
worked example.

```
plugins/my-plugin/
├── manifest.json
├── main.js
└── styles.css        (optional)
```

## manifest.json

```json
{
  "id": "my-plugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "description": "What it does.",
  "author": "You",
  "minAppVersion": "0.1.0",
  "main": "main.js",
  "styles": "styles.css",
  "permissions": ["url.open"],
  "settings": [
    { "key": "greeting", "type": "string", "default": "hi", "label": "Greeting" }
  ]
}
```

- `id`: lowercase letters, digits and hyphens (2–40). **Must equal the folder name.** Your saved settings
  live in `settings.json` under this id, so it cannot be one of the app's own setting names.
- `main` / `styles`: plain file names in the plugin folder (no paths). `main` ends in `.js`, `styles` in `.css`.
- `settings`: `number`, `string` or `boolean`. PinTack draws the form for you in Settings → Plugins.
- A manifest that breaks any rule is listed with the reason and cannot be enabled.

## Permissions

A plugin can only call what it declared, and the user sees the list before enabling it.

| Permission | Lets the plugin |
|---|---|
| `process.execute` | Run commands. **Every new command asks the user first.** |
| `shortcuts.run` | Run a macOS Shortcut (also asks first) |
| `url.open` | Open `http`, `https` or `mailto` links |
| `path.reveal` | Reveal a file in Finder |
| `vault.read` | Read notes and list them |
| `vault.write` | Change notes and create new ones |

Plugins have **no filesystem access and no network access**. The page's Content-Security-Policy forbids
both, and there is no `eval`.

## main.js

```js
module.exports = class MyPlugin extends PinTack.Plugin {
  async onload() {
    this.registerMarkdownCodeBlockProcessor("hello", (source, el, ctx) => {
      el.textContent = "Hello, " + source.trim();
    });
    this.registerSlashCommand({ id: "hello", name: "Hello block", insert: "```hello\n$0\n```\n" });
    this.registerCommand({ id: "greet", name: "Say hello", defaultHotkey: null, callback: () => {} });
    this.registerEvent("note:save", ({ noteId }) => {});
  }
  async onunload() {}
};
```

| Method | Purpose |
|---|---|
| `registerMarkdownCodeBlockProcessor(lang, fn)` | Draw a fenced block. `fn(source, el, ctx)`; `ctx.updateSource(text)` rewrites the block; `ctx.noteId` |
| `registerMarkdownPostProcessor(fn)` | `fn(el, ctx)` on rendered widgets (tables, images, plugin blocks) |
| `registerSlashCommand({id, name, insert \| run})` | Appears in the `/` menu. `insert` may contain `$0` for the caret |
| `registerCommand({id, name, defaultHotkey, callback})` | Listed in Settings → Shortcuts, where the user can bind a key. `defaultHotkey` like `"Alt+Cmd+R"` |
| `registerSettingsTab(tab)` | `tab.display(containerEl)` draws a custom page, opened from Settings → Plugins |
| `registerEvent(name, fn)` | `note:open`, `note:save`, `note:close`, `note:rename`, `vault:change` |
| `this.settings` / `this.setSetting(k, v)` | Values from the manifest schema |
| `this.loadData()` / `this.saveData(obj)` | Private JSON storage (under 1 MB) |

`this.app.vault`: `read(id)`, `modify(id, text)`, `create(path, text)`, `getNotes({folder, tags})`,
`getAttachmentPath(name)`. `this.app.workspace.getActiveNote()` gives `{noteId, getValue()}`.

### Host calls

`await this.app.host.invoke(method, args, { onProgress })` is how everything privileged happens. Swift
checks your token, then your declared permissions, then (for commands) asks the user. Methods:
`process.execute`, `process.stop`, `process.info`, `trust.status`, `shortcuts.run`, `url.open`,
`path.reveal`, `storage.load/save`, `settings.set`, and the `vault.*` calls. A refused call rejects with
`error.code` (`permission_denied`, `denied`, `bad_args`, …).

## Runner blocks

````markdown
```runner
label: Rebuild search index
run: ~/bin/reindex.py
cwd: ~/projects/thing
```
````

One action per block: `run:` (a command, in your login shell so `python3` resolves like it does in
Terminal), `open:` (a URL), `reveal:` (a path) or `shortcut:` (a Shortcut's name). Runner only draws and
asks; **it cannot approve anything**.

## The trust model (why a plugin cannot run things on its own)

1. **No autorun, ever.** A command runs only after a physical click.
2. **A native approval window** shows the exact text, the folder and the shell. It is drawn by PinTack, not
   by the page, so no plugin can answer it. There is no setting, flag or environment variable that skips it.
3. **Approval is bound to the exact command text AND its working folder.** Change one character, or run
   the same `./run.sh` from another folder, and it asks again.
4. **Approvals belong to a person on a Mac.** They are stored in `.pintack/trust.json` with a signature made
   from a secret in `~/Library/Application Support/PinTack/`, outside the vault. A `trust.json` that arrives
   through sync or a shared folder is ignored, so importing or receiving a note can never pre-approve a
   command. Revoke any approval in Settings → Plugins.
5. Text that could render differently from how it executes (escape sequences, NUL, right-to-left
   overrides) is refused before it can reach the window.

**Honest limit:** plugins share one JavaScript realm inside a note, so a malicious plugin could interfere with
another plugin's objects. What it still cannot do is act as another plugin to Swift (capability tokens are
per page, per plugin), exceed its declared permissions, or run a command nobody approved. **Only enable
plugins you trust.**
