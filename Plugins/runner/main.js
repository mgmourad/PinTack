// Runner: inline buttons that run commands. SPEC.md §13.
//
// Written ONLY against the public plugin API (PinTack.Plugin, this.app.host.invoke, the register*
// methods). The core has no private hooks for it; if Runner needed something the API lacked, the
// API would have gained it publicly.
//
// Security: nothing here can run a command by itself. `process.execute` makes Swift show a native
// approval sheet with the exact command, and remembers the answer only for that exact command and
// folder. There is no autorun, and nothing in this file can answer that sheet.
"use strict";

const ICON_PLAY = '<svg class="rn-play" viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><path d="M4.4 2.6v10.8c0 .5.5.8.9.5l8.3-5.4c.4-.2.4-.8 0-1L5.3 2.1c-.4-.3-.9 0-.9.5z" fill="currentColor"/></svg>';
// Pencil between angle brackets: ONE monochrome template glyph, so it tints with the accent. Not an emoji.
const ICON_INSPECT = '<svg viewBox="0 0 26 14" width="24" height="14" aria-hidden="true"><path d="M5.2 2 1.6 7l3.6 5M20.8 2l3.6 5-3.6 5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/><path d="M9.6 10.8 10.3 8.4 15.7 3a1 1 0 0 1 1.4 0l.4.4a1 1 0 0 1 0 1.4l-5.4 5.4z" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linejoin="round"/></svg>';

const ACTIONS = { run: "Run a command", open: "Open a URL", reveal: "Reveal in Finder", shortcut: "Run a macOS Shortcut" };
const VALUE_LABEL = { run: "Command", open: "URL", reveal: "Path", shortcut: "Shortcut name" };

function parseBlock(src) {
  const out = { label: "", type: null, value: "", cwd: "", extra: [] };
  for (const line of src.split("\n")) {
    const m = /^([A-Za-z]+):\s?(.*)$/.exec(line);
    if (!m) { if (line.trim()) out.extra.push(line); continue; }
    const key = m[1].toLowerCase(), value = m[2].trim();
    if (key === "label") out.label = value;
    else if (key === "cwd") out.cwd = value;
    else if (ACTIONS[key] && !out.type) { out.type = key; out.value = value; }
    else out.extra.push(line);                 // unknown keys survive an edit
  }
  return out;
}

function serializeBlock(b) {
  const lines = ["label: " + b.label];
  if (b.type) lines.push(b.type + ": " + b.value);
  if (b.cwd) lines.push("cwd: " + b.cwd);
  return lines.concat(b.extra).join("\n");
}

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}

// The pasteboard API is unavailable on a non-secure origin, so copy through a hidden textarea.
function copyText(text) {
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.cssText = "position:fixed;left:-9999px;top:0;opacity:0";
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand("copy"); } catch (_) { /* nothing more to try */ }
  ta.remove();
}

const fmtElapsed = (ms) => (ms < 1000 ? Math.round(ms) + " ms" : (ms / 1000).toFixed(ms < 10000 ? 1 : 0) + " s");

class RunState {
  constructor(height) { this.output = []; this.running = false; this.callId = null; this.result = null; this.startedAt = 0; this.height = height; this.stick = true; this.ctl = null; }
}

class Controller {
  constructor(plugin, block, state, host, ctx, key) {
    this.plugin = plugin; this.block = block; this.state = state; this.host = host; this.ctx = ctx; this.key = key;
    this.trusted = null;
  }

  get app() { return this.plugin.app; }

  mount() {
    const st = this.state;
    st.ctl = this;
    this.root = el("div", "runner");
    this.host.appendChild(this.root);

    // The button: [play  label] | <pencil>
    const bar = el("div", "rn-bar");
    this.runBtn = el("button", "rn-run");
    this.runBtn.type = "button";
    this.runBtn.innerHTML = ICON_PLAY;
    this.labelEl = el("span", "rn-label", this.block.label || "Untitled action");
    this.runBtn.appendChild(this.labelEl);
    this.badge = el("span", "rn-badge");
    this.runBtn.appendChild(this.badge);
    this.runBtn.addEventListener("click", () => this.run());
    // The label is editable in place, without opening the inspector.
    this.labelEl.addEventListener("dblclick", (e) => { e.stopPropagation(); this.editLabel(); });

    const divider = el("span", "rn-div");
    this.inspectBtn = el("button", "rn-inspect");
    this.inspectBtn.type = "button";
    this.inspectBtn.title = "Inspect and edit this command";
    this.inspectBtn.innerHTML = ICON_INSPECT;
    this.inspectBtn.addEventListener("click", () => this.toggleInspector());
    bar.append(this.runBtn, divider, this.inspectBtn);
    this.root.appendChild(bar);

    this.panel = el("div", "rn-panel");
    this.panel.hidden = true;
    this.root.appendChild(this.panel);

    this.outEl = el("div", "rn-out");
    this.root.appendChild(this.outEl);
    this.buildOutput();
    this.syncOutput();
    this.refreshTrust();
  }

  // ------------------------------------------------------------ trust

  async refreshTrust() {
    const b = this.block;
    if (b.type !== "run" && b.type !== "shortcut") { this.trusted = true; this.paint(); return; }
    try {
      const args = b.type === "run" ? { command: b.value, cwd: b.cwd } : { shortcut: b.value };
      const r = await this.app.host.invoke("trust.status", args);
      this.trusted = !!r.trusted;
    } catch (_) { this.trusted = false; }
    this.paint();
  }

  paint() {
    // An unapproved command renders as "review before running", not as a plain live button.
    const review = this.trusted === false && (this.block.type === "run" || this.block.type === "shortcut");
    this.root.classList.toggle("rn-review", review);
    this.root.classList.toggle("rn-running", this.state.running);
    this.badge.textContent = review ? "Review" : "";
    this.runBtn.title = review
      ? "This command has not been approved yet. Clicking shows exactly what would run and asks first."
      : (this.block.value ? this.block.value : "Add a command in the inspector");
  }

  // ------------------------------------------------------------ actions

  async run() {
    const b = this.block;
    if (!b.type || !b.value) { this.toggleInspector(true); return; }
    if (this.state.running) return;
    const s = this.plugin.settings;
    try {
      if (b.type === "open") { await this.app.host.invoke("url.open", { url: b.value }); return; }
      if (b.type === "reveal") { await this.app.host.invoke("path.reveal", { path: b.value, cwd: b.cwd }); return; }
    } catch (e) { this.note(e.message); return; }
    const method = b.type === "run" ? "process.execute" : "shortcuts.run";
    const args = b.type === "run"
      ? { command: b.value, cwd: b.cwd, timeout: Number(s.timeout) || 30, shell: s.shell || "" }
      : { shortcut: b.value, timeout: Number(s.timeout) || 30 };
    await this.execute(method, args);
  }

  async execute(method, args) {
    const st = this.state;
    st.output = []; st.result = null; st.running = true; st.startedAt = Date.now(); st.stick = true;
    this.syncOutput();
    this.tick = setInterval(() => this.updateHead(), 250);
    const call = this.app.host.invoke(method, args, { onProgress: (d) => this.append(d.stream, d.text) });
    st.callId = call.callId;
    try {
      st.result = await call;
      this.trusted = true;                                     // it ran, so the user approved it
    } catch (e) {
      st.result = { error: e.code || "error" };
      this.append("stderr", e.code === "denied" ? "Not approved, so nothing ran.\n" : e.message + "\n");
    } finally {
      st.running = false; st.callId = null;
      clearInterval(this.tick);
      this.updateHead(); this.paint();
    }
    return st.result;
  }

  stop() { if (this.state.callId) this.app.host.invoke("process.stop", { callId: this.state.callId }).catch(() => {}); }

  note(text) { this.append("stderr", text + "\n"); this.state.running = false; this.syncOutput(); }

  // ------------------------------------------------------------ label

  editLabel() {
    const input = el("input", "rn-label-input");
    input.value = this.block.label;
    this.labelEl.replaceWith(input);
    input.focus(); input.select();
    let done = false;
    const finish = (commit) => {
      if (done) return; done = true;
      if (commit && input.value.trim() && input.value.trim() !== this.block.label) this.save({ ...this.block, label: input.value.trim() });
      else input.replaceWith(this.labelEl);
    };
    input.addEventListener("keydown", (e) => { e.stopPropagation(); if (e.key === "Enter") finish(true); if (e.key === "Escape") finish(false); });
    input.addEventListener("blur", () => finish(true));
    input.addEventListener("mousedown", (e) => e.stopPropagation());
  }

  // ------------------------------------------------------------ inspector

  async toggleInspector(forceOpen) {
    const open = forceOpen === true ? true : this.panel.hidden;
    this.panel.hidden = !open;
    this.root.classList.toggle("rn-inspecting", open);
    if (!open) return;
    this.panel.textContent = "";
    const b = this.block;
    const info = await this.app.host.invoke("process.info").catch(() => ({ shell: "/bin/zsh" }));
    const shell = this.plugin.settings.shell || info.shell;

    const form = el("div", "rn-form");
    const row = (label, control) => { const r = el("label", "rn-row"); r.append(el("span", "rn-k", label), control); form.appendChild(r); return control; };

    const label = row("Label", el("input")); label.value = b.label;
    const type = row("Action", el("select"));
    for (const [k, v] of Object.entries(ACTIONS)) { const o = el("option", null, v); o.value = k; type.appendChild(o); }
    type.value = b.type || "run";
    const value = row(VALUE_LABEL[type.value], el("textarea", "rn-mono")); value.rows = 2; value.value = b.value;
    const cwd = row("Working folder", el("input", "rn-mono")); cwd.value = b.cwd; cwd.placeholder = "~ (home)";
    const cwdRow = cwd.parentElement;
    const sync = () => { value.parentElement.firstChild.textContent = VALUE_LABEL[type.value]; cwdRow.hidden = type.value !== "run"; };
    type.addEventListener("change", sync); sync();

    const facts = el("div", "rn-facts");
    facts.append(
      el("div", null, "Runs in: " + shell + (this.plugin.settings.shell ? " (override)" : " (your login shell)")),
      el("div", null, "Status: " + (this.trusted === false ? "not approved yet" : "approved")),
      el("div", "rn-warn", "Changing the command asks for approval again."),
    );
    form.appendChild(facts);

    const buttons = el("div", "rn-buttons");
    const save = el("button", "rn-save", "Save"); save.type = "button";
    const cancel = el("button", null, "Cancel"); cancel.type = "button";
    save.addEventListener("click", () => this.save({ ...b, label: label.value.trim() || "Untitled action", type: type.value, value: value.value.trim(), cwd: cwd.value.trim() }));
    cancel.addEventListener("click", () => this.toggleInspector(false));
    buttons.append(cancel, save);
    form.appendChild(buttons);
    this.panel.appendChild(form);
  }

  // Writes the block back into the note. The output moves to the new key so a rename keeps it.
  save(next) {
    const source = serializeBlock(next);
    this.plugin.states.set(this.plugin.keyFor(this.ctx.noteId, source), this.state);
    this.ctx.updateSource(source);
  }

  // ------------------------------------------------------------ output pane

  buildOutput() {
    const o = this.outEl;
    o.textContent = "";
    this.handle = el("div", "rn-handle");
    this.handle.title = "Drag to resize";
    this.head = el("div", "rn-head");
    this.chip = el("span", "rn-chip");
    this.time = el("span", "rn-time");
    this.stopBtn = el("button", "rn-mini", "Stop"); this.stopBtn.type = "button";
    this.stopBtn.addEventListener("click", () => this.stop());
    this.copyBtn = el("button", "rn-mini", "Copy"); this.copyBtn.type = "button";
    this.copyBtn.addEventListener("click", () => copyText(this.state.output.map((c) => c.text).join("")));
    this.clearBtn = el("button", "rn-mini", "Clear"); this.clearBtn.type = "button";
    this.clearBtn.addEventListener("click", () => { this.state.output = []; if (!this.state.running) this.state.result = null; this.syncOutput(); });
    this.head.append(this.chip, this.time, el("span", "rn-spacer"), this.stopBtn, this.copyBtn, this.clearBtn);
    this.body = el("pre", "rn-body");
    this.body.addEventListener("scroll", () => { this.state.stick = this.body.scrollTop + this.body.clientHeight >= this.body.scrollHeight - 4; });
    o.append(this.handle, this.head, this.body);

    this.handle.addEventListener("mousedown", (e) => {
      e.preventDefault(); e.stopPropagation();
      const startY = e.clientY, startH = this.state.height;
      const move = (m) => { this.state.height = Math.max(60, Math.min(520, startH + (m.clientY - startY))); this.body.style.height = this.state.height + "px"; };
      const up = () => { document.removeEventListener("mousemove", move); document.removeEventListener("mouseup", up); this.plugin.saveHeight(this.ctx.noteId, this.state.height); };
      document.addEventListener("mousemove", move); document.addEventListener("mouseup", up);
    });
  }

  // Collapsed entirely when there is nothing to show.
  syncOutput() {
    const st = this.state;
    const show = st.running || st.output.length > 0 || st.result;
    this.outEl.hidden = !show;
    if (!show) return;
    this.body.style.height = st.height + "px";
    this.body.textContent = "";
    for (const c of st.output) this.body.appendChild(this.chunkEl(c));
    this.updateHead();
    if (st.stick) this.body.scrollTop = this.body.scrollHeight;
  }

  chunkEl(c) { return el("span", c.stream === "stderr" ? "rn-err" : "rn-outtext", c.text); }

  append(stream, text) {
    const st = this.state;
    st.output.push({ stream, text });
    if (st.output.length > 4000) st.output.splice(0, st.output.length - 4000);      // bound memory in the page
    const live = st.ctl && st.ctl.root && st.ctl.root.isConnected ? st.ctl : null;
    if (!live) return;
    if (live.outEl.hidden) live.syncOutput();
    else {
      live.body.appendChild(live.chunkEl({ stream, text }));
      if (st.stick) live.body.scrollTop = live.body.scrollHeight;     // pauses the moment the user scrolls up
    }
  }

  updateHead() {
    const st = this.state, r = st.result;
    this.stopBtn.hidden = !st.running;
    let text = "", cls = "rn-chip";
    if (st.running) { text = "Running…"; cls += " rn-run-chip"; }
    else if (r && r.timedOut) { text = "timed out"; cls += " rn-bad"; }
    else if (r && r.stopped) { text = "stopped"; cls += " rn-bad"; }
    else if (r && r.error) { text = r.error === "denied" ? "not approved" : "failed"; cls += " rn-bad"; }
    else if (r) { text = "exit " + r.exitCode; cls += r.exitCode === 0 ? " rn-good" : " rn-bad"; }
    this.chip.className = cls; this.chip.textContent = text;
    const ms = st.running ? Date.now() - st.startedAt : (r && r.elapsedMs) || 0;
    this.time.textContent = st.running || r ? fmtElapsed(ms) : "";
  }
}

class RunnerSettingsTab {
  constructor(plugin) { this.plugin = plugin; }
  async display(container) {
    container.textContent = "";
    const info = await this.plugin.app.host.invoke("process.info").catch(() => ({ shell: "/bin/zsh" }));
    container.append(
      el("h3", null, "Runner"),
      el("p", null, "Commands run in your login shell (" + info.shell + "), so your PATH, python3 and friends resolve the way they do in Terminal."),
      el("p", null, "Every new command asks for approval first, showing exactly what will run. Approvals are remembered for that exact command and folder, and can be revoked in Settings → Plugins."),
    );
  }
}

module.exports = class RunnerPlugin extends PinTack.Plugin {
  async onload() {
    this.states = new Map();          // one RunState per (note, block text)
    this.controllers = new Set();
    this.data = (await this.loadData().catch(() => null)) || {};

    this.registerMarkdownCodeBlockProcessor("runner", (source, host, ctx) => this.render(source, host, ctx));

    this.registerSlashCommand({
      id: "runner", name: "Runner button", icon: "play",
      insert: "```runner\nlabel: New action\nrun: $0\n```\n",
    });

    this.registerCommand({
      id: "runner:run-all", name: "Run all buttons in note", defaultHotkey: null,
      callback: () => this.runAll(),
    });

    this.registerSettingsTab(new RunnerSettingsTab(this));

    // A note that closes must not leave its processes running.
    this.registerEvent("note:close", () => {
      for (const st of this.states.values()) if (st.running && st.ctl) st.ctl.stop();
    });
  }

  keyFor(noteId, source) { return noteId + " " + source; }

  render(source, host, ctx) {
    const key = this.keyFor(ctx.noteId, source);
    let st = this.states.get(key);
    if (!st) { st = new RunState((this.data.heights || {})[ctx.noteId] || 140); this.states.set(key, st); }
    const ctl = new Controller(this, parseBlock(source), st, host, ctx, key);
    ctl.mount();
    this.controllers.add(ctl);
  }

  saveHeight(noteId, h) {
    this.data.heights = { ...(this.data.heights || {}), [noteId]: h };
    this.saveData(this.data).catch(() => {});
  }

  async runAll() {
    const live = [...this.controllers].filter((c) => c.root.isConnected && (c.block.type === "run" || c.block.type === "shortcut"));
    live.sort((a, b) => (a.root.compareDocumentPosition(b.root) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1));
    for (const c of live) {
      await c.run();
      if (c.state.result && c.state.result.error === "denied") break;      // the user said no: do not keep asking
    }
  }
};
