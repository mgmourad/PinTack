// PinTack editor: CodeMirror 6 with Obsidian-style Live Preview. SPEC.md §4.
//
// Live Preview means formatting renders as you type and raw markdown syntax is
// revealed only on the line holding the cursor. It is implemented as one
// StateField that turns the markdown syntax tree into decorations (hide the
// markers, style the content, swap a few constructs for widgets).
// A StateField rather than a ViewPlugin, because block-level replacements
// (tables) are only legal from a field.

import { EditorState, Compartment, StateField, StateEffect, Prec } from "@codemirror/state";
import { EditorView, Decoration, WidgetType, keymap, placeholder, drawSelection } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxTree, ensureSyntaxTree, syntaxHighlighting, HighlightStyle } from "@codemirror/language";
import { autocompletion, completionKeymap, startCompletion } from "@codemirror/autocomplete";
import { tags as t } from "@lezer/highlight";
import { createRuntime } from "./plugin-runtime.js";

/* ------------------------------------------------------------------ bridge */

const noteState = { noteId: null, tags: [], settings: {} };

function post(type, payload = {}) {
  const msg = { type, noteId: noteState.noteId, payload };
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pintack;
  if (handler) handler.postMessage(msg);
  else console.log("[bridge → swift]", JSON.stringify(msg).slice(0, 200));
}

/* ------------------------------------------------------- Live Preview state */

const setFocus = StateEffect.define();
const refresh = StateEffect.define();

// The plugin runtime. The view does not exist yet when this module loads, so it is reached lazily.
let viewRef = null;
const runtime = createRuntime({
  post: (type, payload) => post(type, payload),
  getNoteId: () => noteState.noteId,
  getBody: () => (viewRef ? viewRef.state.doc.toString() : ""),
  insertText: (text) => { if (viewRef) { const s = viewRef.state.selection.main; edit(viewRef, s.from, s.to, text); } },
  requestRefresh: () => { if (viewRef) viewRef.dispatch({ effects: refresh.of(null) }); },
});
let pluginsStarted = false;

const focusField = StateField.define({
  create: () => false,
  update(v, tr) {
    for (const e of tr.effects) if (e.is(setFocus)) return e.value;
    return v;
  },
});

// Widgets ---------------------------------------------------------------

class BulletWidget extends WidgetType {
  eq() { return true; }
  toDOM() { const s = document.createElement("span"); s.className = "cm-bullet"; s.textContent = "•"; return s; }
}

class CheckboxWidget extends WidgetType {
  constructor(checked) { super(); this.checked = checked; }
  eq(o) { return o.checked === this.checked; }
  toDOM(view) {
    const box = document.createElement("span");
    box.className = "cm-task-box" + (this.checked ? " done" : "");
    box.setAttribute("role", "checkbox");
    box.setAttribute("aria-checked", String(this.checked));
    box.addEventListener("mousedown", (e) => {
      e.preventDefault();
      const pos = view.posAtDOM(box);          // start of the replaced "[ ]"
      const now = view.state.sliceDoc(pos + 1, pos + 2);
      view.dispatch({ changes: { from: pos + 1, to: pos + 2, insert: /x/i.test(now) ? " " : "x" } });
    });
    return box;
  }
  ignoreEvent() { return true; }
}

class HrWidget extends WidgetType {
  eq() { return true; }
  toDOM() { const s = document.createElement("span"); s.className = "cm-hr"; return s; }
}

// Greyed-out placeholder shown after "@Todo " until a title is typed. It is a widget,
// not document text, so it never reaches the file.
class HintWidget extends WidgetType {
  constructor(text) { super(); this.text = text; }
  eq(o) { return o.text === this.text; }
  toDOM() {
    const s = document.createElement("span");
    s.className = "cm-hint";
    s.textContent = this.text;
    return s;
  }
  ignoreEvent() { return true; }
}

// A fenced block a plugin has claimed (```runner …```), drawn by that plugin's processor. Kept alive
// across edits elsewhere in the note by eq(), so a plugin's UI state (e.g. running output) survives.
class PluginBlockWidget extends WidgetType {
  constructor(lang, source) { super(); this.lang = lang; this.source = source; }
  eq(o) { return o.lang === this.lang && o.source === this.source; }
  toDOM(view) {
    const el = document.createElement("div");
    el.className = "cm-plugin-block";
    const ctx = { noteId: noteState.noteId, lang: this.lang, updateSource: (text) => updateBlockSource(view, el, text) };
    if (!runtime.renderCodeBlock(this.lang, this.source, el, ctx)) el.textContent = `No plugin handles “${this.lang}” blocks`;
    return el;
  }
  ignoreEvent() { return true; }
}

// The text between a block's fences. `to` is exclusive of the newline before the closing fence.
function blockInner(doc, node) {
  const first = doc.lineAt(node.from), last = doc.lineAt(node.to);
  const closing = last.number > first.number && /^\s*(```|~~~)/.test(last.text);
  const from = first.to + 1;
  const to = closing ? last.from - 1 : node.to;
  return { first, from, to, empty: from > to };
}

// Rewrites the inside of the fenced block that contains `el` (the plugin's own edit path).
function updateBlockSource(view, el, text) {
  let pos;
  try { pos = view.posAtDOM(el); } catch (_) { return; }
  let n = syntaxTree(view.state).resolveInner(pos, 1);
  while (n && n.name !== "FencedCode") n = n.parent;
  if (!n) return;
  const inner = blockInner(view.state.doc, n);
  view.dispatch({ changes: inner.empty ? { from: inner.first.to, insert: "\n" + text } : { from: inner.from, to: inner.to, insert: text } });
}

class ImageWidget extends WidgetType {
  constructor(src, alt) { super(); this.src = src; this.alt = alt; }
  eq(o) { return o.src === this.src && o.alt === this.alt; }
  toDOM() {
    const img = document.createElement("img");
    img.className = "cm-image";
    img.alt = this.alt;
    img.src = resolveImage(this.src);
    img.addEventListener("error", () => {
      const s = document.createElement("span");
      s.className = "cm-image-missing";
      s.textContent = `[image not found: ${this.alt || this.src}]`;
      img.replaceWith(s);
    });
    return img;
  }
}

// Relative paths (attachments/…) resolve against the app scheme; the Swift side
// serves them out of the vault. Anything remote is refused by the CSP anyway.
function resolveImage(src) {
  if (/^(https?|file):/i.test(src)) return "about:blank";
  if (src.startsWith("/")) return "__abs__" + src;
  return src.replace(/^\.\//, "");
}

class TableWidget extends WidgetType {
  constructor(text) { super(); this.text = text; }
  eq(o) { return o.text === this.text; }
  toDOM(view) {
    const lines = this.text.split("\n").filter((l) => l.trim() !== "");
    const wrap = document.createElement("div");
    wrap.className = "cm-table-wrap";
    if (lines.length < 2) return wrap;
    const cells = (line) => {
      let s = line.trim();
      if (s.startsWith("|")) s = s.slice(1);
      if (s.endsWith("|") && !s.endsWith("\\|")) s = s.slice(0, -1);
      return s.split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, "|"));
    };
    const aligns = cells(lines[1]).map((c) => (c.startsWith(":") && c.endsWith(":") ? "center" : c.endsWith(":") ? "right" : "left"));
    const table = document.createElement("table");
    table.className = "cm-table";
    const build = (tag, row) => {
      const tr = document.createElement("tr");
      cells(row).forEach((c, i) => {
        const cell = document.createElement(tag);
        cell.style.textAlign = aligns[i] || "left";
        cell.innerHTML = inlineHTML(c);
        tr.appendChild(cell);
      });
      return tr;
    };
    const head = document.createElement("thead");
    head.appendChild(build("th", lines[0]));
    const body = document.createElement("tbody");
    lines.slice(2).forEach((l) => body.appendChild(build("td", l)));
    table.append(head, body);
    wrap.appendChild(table);
    // Clicking a rendered table drops the cursor into it, which reveals the source.
    wrap.addEventListener("mousedown", (e) => {
      e.preventDefault();
      const pos = view.posAtDOM(wrap);
      view.dispatch({ selection: { anchor: pos }, scrollIntoView: true });
      view.focus();
    });
    return wrap;
  }
  ignoreEvent() { return true; }
}

const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
function inlineHTML(s) {
  return esc(s)
    .replace(/`([^`]+)`/g, "<code class='cm-inline-code'>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^*])\*([^*]+)\*/g, "$1<em>$2</em>")
    .replace(/~~([^~]+)~~/g, "<del>$1</del>")
    .replace(/==([^=]+)==/g, "<span class='cm-highlight'>$1</span>");
}

// Decoration builder -----------------------------------------------------

const COLOR_SPAN = /(<span\s+style="color:\s*([^";]+?)\s*;?">)(.*?)(<\/span>)/g;
const SAFE_COLOR = /^(#[0-9a-fA-F]{3,8}|[a-zA-Z]{3,20}|rgba?\([\d\s,.%]+\))$/;
const EMOJI_LEAD = /^(\s*)((?:\p{Extended_Pictographic}[\u{1F3FB}-\u{1F3FF}️‍]*)+)\s+\S/u;

function build(state) {
  const doc = state.doc;
  const focused = state.field(focusField);
  const sel = state.selection.ranges;
  const deco = [];
  const atomic = [];

  // Raw syntax shows on any line the selection touches. When the editor is not
  // focused nothing is "under the cursor", so the whole note renders.
  const lineTouched = (from, to) => {
    if (!focused) return false;
    const a = doc.lineAt(from).from, z = doc.lineAt(to).to;
    return sel.some((r) => r.from <= z && r.to >= a);
  };
  const touched = (from, to) => focused && sel.some((r) => r.from <= to && r.to >= from);

  const mark = (f, t, cls, attrs) => { if (t > f) deco.push(Decoration.mark({ class: cls, attributes: attrs }).range(f, t)); };
  const line = (pos, cls) => deco.push(Decoration.line({ class: cls }).range(pos));
  const hide = (f, t) => {
    if (t <= f) return;
    const d = Decoration.replace({}).range(f, t);
    deco.push(d); atomic.push(d);
  };
  const swap = (f, t, widget, block = false) => {
    const d = Decoration.replace({ widget, block }).range(f, t);
    deco.push(d); atomic.push(d);
  };
  // A marker is either hidden (cursor elsewhere) or dimmed (cursor on its line).
  const marker = (f, t, extra = 0) => {
    if (lineTouched(f, t)) mark(f, t, "cm-syntax");
    else hide(f, Math.min(t + extra, doc.lineAt(f).to));
  };

  const codeRanges = [];     // regions the regex pass must not touch
  const inlineCode = [];

  const tree = ensureSyntaxTree(state, doc.length, 200) || syntaxTree(state);
  tree.iterate({
    enter(node) {
      const { name, from, to } = node;
      let m;
      if ((m = /^ATXHeading([1-6])$/.exec(name))) {
        line(doc.lineAt(from).from, `cm-h cm-h${m[1]}`);
      } else if ((m = /^SetextHeading([12])$/.exec(name))) {
        const first = doc.lineAt(from), last = doc.lineAt(to);
        for (let n = first.number; n < last.number; n++) line(doc.line(n).from, `cm-h cm-h${m[1]}`);
      } else if (name === "HeaderMark") {
        if (node.node.parent && node.node.parent.name.startsWith("ATX")) marker(from, to, 1);
      } else if (name === "StrongEmphasis") mark(from, to, "cm-strong");
      else if (name === "Emphasis") mark(from, to, "cm-em");
      else if (name === "Strikethrough") mark(from, to, "cm-strike");
      else if (name === "EmphasisMark" || name === "StrikethroughMark") marker(from, to);
      else if (name === "InlineCode") { mark(from, to, "cm-inline-code"); inlineCode.push([from, to]); }
      else if (name === "CodeMark") { if (node.node.parent && node.node.parent.name === "InlineCode") marker(from, to); }
      else if (name === "FencedCode") {
        const first = doc.lineAt(from), last = doc.lineAt(to);
        const editing = touched(from, to);
        // A plugin may own this language (```runner). Draw its widget unless the caret is inside.
        const info = node.node.getChild("CodeInfo");
        const lang = info ? doc.sliceString(info.from, info.to).trim() : "";
        if (lang && runtime.hasCodeBlockProcessor(lang) && !editing) {
          const inner = blockInner(doc, node.node);
          swap(from, to, new PluginBlockWidget(lang, inner.empty ? "" : doc.sliceString(inner.from, inner.to)), true);
          codeRanges.push([from, to]);
          return false;
        }
        for (let n = first.number; n <= last.number; n++) {
          const l = doc.line(n);
          let cls = "cm-codeblock";
          if (n === first.number) cls += " cm-codeblock-first";
          if (n === last.number) cls += " cm-codeblock-last";
          const isFence = n === first.number || (n === last.number && n !== first.number && /^\s*(```|~~~)/.test(l.text));
          if (isFence && !editing) { cls += " cm-fence-hidden"; hide(l.from, l.to); }
          line(l.from, cls);
        }
        codeRanges.push([from, to]);
        return false;
      } else if (name === "Blockquote") {
        const first = doc.lineAt(from), last = doc.lineAt(to);
        for (let n = first.number; n <= last.number; n++) line(doc.line(n).from, "cm-quote");
      } else if (name === "QuoteMark") marker(from, to, doc.sliceString(to, to + 1) === " " ? 1 : 0);
      else if (name === "ListMark") {
        const item = node.node.parent;
        const list = item && item.parent;
        line(doc.lineAt(from).from, "cm-li");
        if (list && list.name === "BulletList") {
          const isTask = item.getChild("Task") !== null;
          if (lineTouched(from, to)) mark(from, to, "cm-syntax");
          else if (isTask) hide(from, to + 1);
          else swap(from, to, new BulletWidget());
        } else mark(from, to, "cm-list-num");
      } else if (name === "TaskMarker") {
        const checked = /x/i.test(doc.sliceString(from, to));
        swap(from, to, new CheckboxWidget(checked));
        if (checked) mark(to, doc.lineAt(to).to, "cm-task-done");
      } else if (name === "HorizontalRule") {
        if (lineTouched(from, to)) mark(from, to, "cm-hr-raw");
        else swap(from, to, new HrWidget());
      } else if (name === "Link") {
        mark(from, to, "cm-link");
      } else if (name === "LinkMark" || name === "URL" || name === "LinkTitle") {
        const parent = node.node.parent;
        if (parent && (parent.name === "Link")) marker(from, to);
        else if (name === "URL" && parent && parent.name !== "Image") mark(from, to, "cm-url");
      } else if (name === "Image") {
        if (touched(from, to)) mark(from, to, "cm-image-raw");
        else {
          const url = node.node.getChild("URL");
          const marks = node.node.getChildren("LinkMark");
          if (url) {
            const alt = marks.length >= 2 ? doc.sliceString(marks[0].to, marks[1].from) : "";
            swap(from, to, new ImageWidget(doc.sliceString(url.from, url.to), alt));
          }
        }
        return false;
      } else if (name === "Table") {
        const first = doc.lineAt(from), last = doc.lineAt(to);
        if (touched(from, to)) {
          for (let n = first.number; n <= last.number; n++) line(doc.line(n).from, "cm-table-raw");
        } else {
          swap(from, to, new TableWidget(doc.sliceString(from, to)), true);
        }
        codeRanges.push([from, to]);
        return false;
      }
      return undefined;
    },
  });

  const inRange = (pos, ranges) => ranges.some(([a, b]) => pos >= a && pos <= b);

  // "@Todo <title>" on line 1 marks a todo note: styled as the note's title, with a
  // greyed hint until the title is typed.
  const first = doc.line(1);
  if (/^@Todo(\s|$)/.test(first.text)) {
    line(first.from, "cm-todo-title");
    mark(first.from, first.from + 5, "cm-todo-word");
    if (/^@Todo\s*$/.test(first.text)) {
      deco.push(Decoration.widget({ widget: new HintWidget("todo title"), side: 1 }).range(first.to));
    }
  }

  // Constructs markdown has no syntax for: ==highlight==, colored <span>, #tag,
  // and emoji bullets. Handled per line, skipping code. SPEC.md §4.2, §4.3.
  for (let n = 1; n <= doc.lines; n++) {
    const l = doc.line(n);
    if (inRange(l.from, codeRanges)) continue;
    const text = l.text;

    if (EMOJI_LEAD.test(text)) line(l.from, "cm-ebullet");

    for (const m of text.matchAll(/==([^=\n]+?)==/g)) {
      const f = l.from + m.index, tEnd = f + m[0].length;
      if (inlineCode.some(([a, b]) => f >= a && f <= b)) continue;
      mark(f + 2, tEnd - 2, "cm-highlight");
      if (lineTouched(f, tEnd)) { mark(f, f + 2, "cm-syntax"); mark(tEnd - 2, tEnd, "cm-syntax"); }
      else { hide(f, f + 2); hide(tEnd - 2, tEnd); }
    }

    // Colored text. The <span> tags are presentation only, so they stay hidden even on the
    // cursor line: you see the colored text, never the markup. Tab leaves the span (below).
    for (const m of text.matchAll(COLOR_SPAN)) {
      const color = m[2];
      if (!SAFE_COLOR.test(color)) continue;
      const f = l.from + m.index;
      const openEnd = f + m[1].length, closeStart = openEnd + m[3].length, tEnd = closeStart + m[4].length;
      if (inlineCode.some(([a, b]) => f >= a && f <= b)) continue;
      mark(openEnd, closeStart, "cm-colored", { style: `color:${color}` });
      hide(f, openEnd);
      hide(closeStart, tEnd);
    }

    for (const m of text.matchAll(/(^|[\s(])(#[A-Za-z][\w/-]*)/g)) {
      const f = l.from + m.index + m[1].length;
      if (inlineCode.some(([a, b]) => f >= a && f <= b)) continue;
      mark(f, f + m[2].length, "cm-tag");
    }
  }

  return { deco: Decoration.set(deco, true), atomic: Decoration.set(atomic, true) };
}

const livePreview = StateField.define({
  create: (state) => build(state),
  update(value, tr) {
    const relevant = tr.docChanged || tr.selection || tr.effects.some((e) => e.is(setFocus) || e.is(refresh));
    return relevant ? build(tr.state) : value;
  },
  provide: (f) => [
    EditorView.decorations.from(f, (v) => v.deco),
    // Arrow keys step over hidden syntax instead of into invisible characters.
    EditorView.atomicRanges.of((view) => view.state.field(f).atomic),
  ],
});

const livePreviewExt = [focusField, livePreview, EditorView.editorAttributes.of({ class: "cm-mode-live" })];

// Source mode: raw markdown everywhere, lightly tinted. SPEC.md §4.1.
const sourceHighlight = HighlightStyle.define([
  { tag: t.heading, fontWeight: "700" },
  { tag: t.strong, fontWeight: "700" },
  { tag: t.emphasis, fontStyle: "italic" },
  { tag: t.strikethrough, textDecoration: "line-through" },
  { tag: [t.link, t.url], color: "var(--accent)" },
  { tag: t.monospace, background: "var(--surface)" },
  { tag: [t.processingInstruction, t.contentSeparator], color: "var(--fg-dim)" },
]);
const sourceExt = [syntaxHighlighting(sourceHighlight), EditorView.editorAttributes.of({ class: "cm-mode-source" })];

/* ---------------------------------------------------------- slash commands */

const COLORS = [
  ["red", "#e5484d"], ["orange", "#e07b39"], ["green", "#2f9e5b"],
  ["blue", "#2f6fdd"], ["purple", "#8a4fd6"], ["pink", "#d6409f"], ["gray", "#6b6b73"],
];
const LANGS = ["powershell", "bash", "python", "json", "swift", "js", "yaml", "sql"];

function edit(view, from, to, text, cursorOffset, selectLen = 0) {
  const anchor = from + (cursorOffset ?? text.length);
  view.dispatch({
    changes: { from, to, insert: text },
    selection: { anchor, head: anchor + selectLen },
    scrollIntoView: true,
  });
}

// Block prefixes belong at the start of the line even if "/" was typed later in it.
function linePrefix(prefix) {
  return (view, _c, from, to) => {
    const l = view.state.doc.lineAt(from);
    // Both edits are expressed against the current doc: add the prefix at the line
    // start and delete the "/command" token. The caret ends up after the prefix.
    view.dispatch({
      changes: [{ from: l.from, insert: prefix }, ...(to > from ? [{ from, to }] : [])],
      selection: { anchor: from + prefix.length },
      scrollIntoView: true,
    });
  };
}

const wrap = (open, close = open, placeholderText = "") => (view, _c, from, to) =>
  edit(view, from, to, open + placeholderText + close, open.length, placeholderText.length);

const stamp = (kind) => () => {
  const d = new Date();
  return kind === "date"
    ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`
    : d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
};

const commands = [
  ["h1", "Heading 1", linePrefix("# ")],
  ["h2", "Heading 2", linePrefix("## ")],
  ["h3", "Heading 3", linePrefix("### ")],
  ["bold", "Bold", wrap("**")],
  ["italic", "Italic", wrap("*")],
  ["strike", "Strikethrough", wrap("~~")],
  ["quote", "Blockquote", linePrefix("> ")],
  ["list", "Bulleted list", linePrefix("- ")],
  ["numbered", "Numbered list", linePrefix("1. ")],
  ["todo", "Task list", linePrefix("- [ ] ")],
  ["divider", "Divider", (v, _c, f, to) => edit(v, f, to, "---\n")],
  ["highlight", "Highlight", wrap("==", "==", "text")],
  ["link", "Link", (v, _c, f, to) => edit(v, f, to, "[text](https://)", 1, 4)],
  ["table", "Table", (v, _c, f, to) => edit(v, f, to, "| Column 1 | Column 2 |\n| --- | --- |\n|  |  |\n", 2, 0)],
  ["code", "Code block", (v, _c, f, to) => edit(v, f, to, "```\n\n```", 4)],
  ["date", "Today's date", (v, _c, f, to) => edit(v, f, to, stamp("date")())],
  ["time", "Current time", (v, _c, f, to) => edit(v, f, to, stamp("time")())],
  ["tag", "Tag", (v, _c, f, to) => { edit(v, f, to, "#"); startCompletion(v); }],
  ["image", "Image from Finder…", (v, _c, f, to) => { edit(v, f, to, ""); post("image.pick"); }],
  ["emoji", "Emoji picker", (v, _c, f, to) => { edit(v, f, to, ""); openEmoji(v); }],
];
for (const [name, hex] of COLORS) {
  commands.push([name, `${name[0].toUpperCase() + name.slice(1)} text`,
    (v, _c, f, to) => edit(v, f, to, `<span style="color:${hex}"></span>`, `<span style="color:${hex}">`.length)]);
}
for (const lang of LANGS) {
  commands.push([`code-${lang}`, `Code block: ${lang}`, (v, _c, f, to) => edit(v, f, to, "```" + lang + "\n\n```", 4 + lang.length)]);
}

const slashOptions = commands.map(([id, detail, apply], i) => ({
  label: "/" + id, detail, apply, type: "keyword", boost: 100 - i,
}));

// A plugin's slash command: either `insert` text (with an optional $0 caret marker) or a `run` callback.
function applyPluginSlash(c, view, from, to) {
  if (typeof c.run === "function") {
    view.dispatch({ changes: { from, to } });
    try { c.run({ insertText: (t) => { const s = view.state.selection.main; edit(view, s.from, s.to, t); } }); } catch (e) { console.log("[plugin] slash command failed", e && e.message); }
    return;
  }
  let text = String(c.insert == null ? "" : c.insert);
  let caret = text.indexOf("$0");
  text = text.replace("$0", "");
  if (caret < 0) caret = text.length;
  // Block inserts (code fences) start on a line of their own.
  const line = view.state.doc.lineAt(from);
  const prefix = view.state.sliceDoc(line.from, from).trim() === "" ? "" : "\n";
  view.dispatch({ changes: { from, to, insert: prefix + text }, selection: { anchor: from + prefix.length + caret }, scrollIntoView: true });
}

function slashSource(ctx) {
  const m = ctx.matchBefore(/\/[\w-]*/);
  if (!m) return null;
  if (m.from > 0 && !/\s/.test(ctx.state.sliceDoc(m.from - 1, m.from))) return null;   // "/" mid-word is not a command
  return { from: m.from, options: [...slashOptions, ...runtime.slashOptions(applyPluginSlash)], validFor: /^\/[\w-]*$/ };
}

// #tag completion against the vault's existing tags. SPEC.md §3.5, §6.2.
function tagSource(ctx) {
  const m = ctx.matchBefore(/#[\w/-]*/);
  if (!m || m.text.length < 2 && !ctx.explicit) return null;
  if (m.from > 0 && !/[\s(]/.test(ctx.state.sliceDoc(m.from - 1, m.from))) return null;
  const typed = m.text.slice(1).toLowerCase();
  const options = noteState.tags
    .filter((tag) => tag.toLowerCase().startsWith(typed) && tag.toLowerCase() !== typed)
    .map((tag) => ({ label: "#" + tag, type: "keyword" }));
  return options.length ? { from: m.from, options, validFor: /^#[\w/-]*$/ } : null;
}

/* --------------------------------------------------------------- emoji UI */

const EMOJI = {
  Bullets: ["🔹", "🔸", "🔺", "🔻", "⭐️", "✅", "❌", "➡️", "▶️", "👉", "✔️", "➕", "🔷", "🔶", "🟢", "🟡"],
  Frequent: ["✅", "⭐️", "🔥", "📌", "⚡️", "💡", "🎯", "📝", "❤️", "👍", "🎉", "🚀", "✨", "📎", "🔔", "⏰"],
  Status: ["🟢", "🟡", "🔴", "🔵", "🟣", "🟠", "⚪️", "⚫️", "⏳", "🚧", "✔️", "❌", "⚠️", "🚫", "✅", "❓"],
  Work: ["💼", "📊", "🗂", "📅", "☎️", "🖥", "🔧", "🧪", "📈", "📉", "🧾", "📧", "🔑", "🛠", "🔒", "📦"],
  Life: ["🏠", "🍎", "🚗", "✈️", "🎂", "☕️", "🏋️", "🌙", "🛒", "🍕", "🎁", "💊", "📚", "🎵", "🐶", "🌳"],
  Faces: ["😀", "😂", "😍", "🤔", "😎", "😴", "😡", "😭", "🙂", "😉", "🥳", "🤯", "😅", "🙌", "🙏", "💪"],
};
let emojiMode = "insert";
const emojiEl = document.getElementById("emoji");

function closeEmoji() { emojiEl.classList.add("hidden"); }

function openEmoji(view, opts = {}) {
  const pick = opts.pick === "bullet";
  emojiEl.innerHTML = (pick ? `<div class="cat">Choose a bullet</div><button type="button" class="wide" data-clear="1">Default bullet ( • ) — clear choice</button>` : "") +
    Object.entries(EMOJI).filter(([cat]) => pick || cat !== "Bullets").map(([cat, list]) =>
      `<div class="cat">${cat}</div><div class="grid">${list.map((e) => `<button type="button" data-e="${e}">${e}</button>`).join("")}</div>`).join("") +
    (pick ? "" : `<div class="mode">
       <label><input type="radio" name="emode" value="insert" ${emojiMode === "insert" ? "checked" : ""}> Insert</label>
       <label><input type="radio" name="emode" value="bullet" ${emojiMode === "bullet" ? "checked" : ""}> As bullet</label>
     </div>`);
  const clear = emojiEl.querySelector("button[data-clear]");
  if (clear) {
    clear.addEventListener("mousedown", (e) => e.preventDefault());
    clear.addEventListener("click", () => { post("bullet.changed", { emoji: "" }); closeEmoji(); view.focus(); });
  }
  emojiEl.querySelectorAll("button[data-e]").forEach((b) => {
    b.addEventListener("mousedown", (e) => e.preventDefault());        // keep editor focus
    b.addEventListener("click", () => {
      if (pick) { post("bullet.changed", { emoji: b.dataset.e }); closeEmoji(); view.focus(); return; }
      const sel = view.state.selection.main;
      if (emojiMode === "bullet") {
        const l = view.state.doc.lineAt(sel.from);
        const text = l.text.trim() === "" ? b.dataset.e + " " : "\n" + b.dataset.e + " ";
        const at = l.text.trim() === "" ? l.from : l.to;
        view.dispatch({ changes: { from: at, to: l.text.trim() === "" ? l.to : at, insert: text }, selection: { anchor: at + text.length } });
      } else {
        edit(view, sel.from, sel.to, b.dataset.e);
      }
      closeEmoji();
      view.focus();
    });
  });
  emojiEl.querySelectorAll("input[name=emode]").forEach((r) => (r.onchange = () => (emojiMode = r.value)));

  // The bullet picker is opened from the action bar, so it sits at the bottom-left of the
  // editor. The regular picker opens at the caret.
  const c = pick ? { left: 6, bottom: window.innerHeight } : (view.coordsAtPos(view.state.selection.main.head) || { left: 20, bottom: 40 });
  emojiEl.classList.remove("hidden");
  const w = emojiEl.offsetWidth, h = emojiEl.offsetHeight;
  emojiEl.style.left = Math.max(4, Math.min(c.left, window.innerWidth - w - 4)) + "px";
  emojiEl.style.top = Math.max(6, Math.min(pick ? window.innerHeight - h - 6 : c.bottom + 4, window.innerHeight - h - 4)) + "px";
  emojiEl.scrollTop = 0;
}
document.addEventListener("mousedown", (e) => { if (!e.target.closest("#emoji")) closeEmoji(); });
document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeEmoji(); });

/* ------------------------------------------------------------------ editor */

const modeCompartment = new Compartment();
const spellCompartment = new Compartment();
let suppress = false;          // true while applying content that came from Swift
let debounce = null;

function wrapSelection(marker) {
  return (view) => {
    const { from, to } = view.state.selection.main;
    const before = view.state.sliceDoc(from - marker.length, from);
    const after = view.state.sliceDoc(to, to + marker.length);
    if (before === marker && after === marker) {       // already wrapped: unwrap
      view.dispatch({ changes: [{ from: from - marker.length, to: from }, { from: to, to: to + marker.length }] });
    } else {
      view.dispatch({
        changes: [{ from, insert: marker }, { from: to, insert: marker }],
        selection: { anchor: from + marker.length, head: to + marker.length },
      });
    }
    return true;
  };
}

// ---------------------------------------------------------- action bar commands

// Bold / italic / code from the action bar. With nothing selected, act on the word
// under the caret, or drop a marker pair and put the caret between them.
function toggleInline(view, marker) {
  const st = view.state;
  let { from, to, empty } = st.selection.main;
  if (empty) {
    const w = st.wordAt(from);
    if (w) { from = w.from; to = w.to; empty = false; }
  }
  if (empty) {
    view.dispatch({ changes: { from, insert: marker + marker }, selection: { anchor: from + marker.length } });
    view.focus();
    return;
  }
  const before = st.sliceDoc(from - marker.length, from);
  const after = st.sliceDoc(to, to + marker.length);
  // "*" also appears inside "**", so single-star italics must not mistake bold for italic.
  const stray = marker === "*" && (st.sliceDoc(from - 2, from - 1) === "*" || st.sliceDoc(to + 1, to + 2) === "*");
  if (before === marker && after === marker && !stray) {
    view.dispatch({ changes: [{ from: from - marker.length, to: from }, { from: to, to: to + marker.length }] });
  } else {
    view.dispatch({
      changes: [{ from, insert: marker }, { from: to, insert: marker }],
      selection: { anchor: from + marker.length, head: to + marker.length },
    });
  }
  view.focus();
}

const EMOJI_RUN = "(?:\\p{Extended_Pictographic}[\\u{1F3FB}-\\u{1F3FF}\\uFE0F\\u200D]*)+";
const EMOJI_ITEM = new RegExp(`^(\\s*)(${EMOJI_RUN})(\\s+)(.*)$`, "u");
const EMOJI_EMPTY = new RegExp(`^(\\s*)(${EMOJI_RUN})\\s+$`, "u");        // a bullet with nothing after it
const BULLET_MARK = new RegExp(`^(\\s*)(?:[-*+]\\s(?!\\[[ xX]\\])|${EMOJI_RUN}\\s)`, "u");
const TASK_LINE = /^\s*[-*+]\s\[[ xX]\]/;

// Toggle the user's chosen bullet (a "- " list marker, or an emoji) on the selected lines.
function toggleBullet(view) {
  const st = view.state;
  const bullet = (noteState.settings && noteState.settings.bullet) || "";
  const prefix = bullet ? bullet + " " : "- ";
  const { from, to } = st.selection.main;
  const a = st.doc.lineAt(from).number, z = st.doc.lineAt(to).number;
  const lines = [];
  for (let n = a; n <= z; n++) {
    const l = st.doc.line(n);
    if (TASK_LINE.test(l.text)) continue;                       // never break a checkbox
    if (l.text.trim() !== "" || a === z) lines.push(l);
  }
  if (!lines.length) return;
  const allHave = lines.every((l) => l.text.trimStart().startsWith(prefix));
  const changes = lines.map((l) => {
    const indent = /^\s*/.exec(l.text)[0].length;
    if (allHave) return { from: l.from + indent, to: l.from + indent + prefix.length };
    const m = BULLET_MARK.exec(l.text);
    const end = m ? l.from + m[0].length : l.from + indent;
    return { from: l.from + indent, to: end, insert: prefix };
  });
  view.dispatch({ changes });
  view.focus();
}

const applyFormat = { bold: (v) => toggleInline(v, "**"), italic: (v) => toggleInline(v, "*"), code: (v) => toggleInline(v, "`"), bullet: toggleBullet };

// Tab inside a colored span jumps past its closing tag, so typing continues in the normal color.
function tabOutOfSpan(view) {
  const st = view.state;
  const sel = st.selection.main;
  if (!sel.empty) return false;
  const line = st.doc.lineAt(sel.head);
  for (const m of line.text.matchAll(COLOR_SPAN)) {
    const openEnd = line.from + m.index + m[1].length;
    const closeStart = openEnd + m[3].length;
    if (sel.head >= openEnd && sel.head <= closeStart) {
      view.dispatch({ selection: { anchor: closeStart + m[4].length }, scrollIntoView: true });
      return true;
    }
  }
  return false;
}

// Enter: start a todo list from the "@Todo <title>" line, and keep emoji bullets going.
function enterHandler(view) {
  const st = view.state;
  const sel = st.selection.main;
  if (!sel.empty) return false;
  const line = st.doc.lineAt(sel.head);
  if (sel.head !== line.to) return false;

  if (line.number === 1 && /^@Todo(\s|$)/.test(line.text)) {
    if (/^@Todo\s*$/.test(line.text)) return true;             // no title yet: Enter does nothing
    if (st.doc.sliceString(line.to).trim() !== "") return false;
    view.dispatch({
      changes: { from: line.to, insert: "\n\n- [ ] " },
      selection: { anchor: line.to + 8 },
      scrollIntoView: true,
      userEvent: "input",
    });
    return true;
  }

  if (EMOJI_EMPTY.test(line.text)) {                            // Enter on an empty bullet ends the list
    view.dispatch({ changes: { from: line.from, to: line.to, insert: "" }, selection: { anchor: line.from } });
    return true;
  }
  const m = EMOJI_ITEM.exec(line.text);
  if (m && m[4].trim() !== "") {
    const insert = `\n${m[1]}${m[2]} `;
    view.dispatch({ changes: { from: line.to, insert }, selection: { anchor: line.to + insert.length }, scrollIntoView: true, userEvent: "input" });
    return true;
  }
  return false;
}

const imageFiles = (dt) => [...(dt ? dt.files : [])].filter((f) => /^image\//.test(f.type));
function sendImages(files) {
  files.forEach((file) => {
    const reader = new FileReader();
    reader.onload = () => {
      const data = String(reader.result).split(",")[1] || "";
      post("image.paste", { data, ext: (file.type.split("/")[1] || "png").replace("jpeg", "jpg").replace("svg+xml", "svg") });
    };
    reader.readAsDataURL(file);
  });
}

const linkAt = (view, pos) => {
  let n = syntaxTree(view.state).resolveInner(pos, -1);
  for (; n; n = n.parent) {
    if (n.name === "Link") { const u = n.getChild("URL"); return u ? view.state.sliceDoc(u.from, u.to) : null; }
    if (n.name === "URL" || n.name === "Autolink") return view.state.sliceDoc(n.from, n.to).replace(/^<|>$/g, "");
  }
  return null;
};

const view = new EditorView({
  parent: document.getElementById("editor"),
  state: EditorState.create({
    doc: "",
    extensions: [
      history(),
      drawSelection(),
      EditorView.lineWrapping,
      markdown({ base: markdownLanguage }),
      modeCompartment.of(livePreviewExt),
      spellCompartment.of(EditorView.contentAttributes.of({ spellcheck: "false", autocorrect: "off", autocapitalize: "off" })),
      placeholder("Start typing…  ( / for commands )"),
      autocompletion({ override: [slashSource, tagSource], icons: false, defaultKeymap: true }),
      Prec.highest(keymap.of([{ key: "Enter", run: enterHandler }, { key: "Tab", run: tabOutOfSpan }])),
      // With an emoji bullet chosen, typing "- " at the start of a line produces that emoji instead.
      EditorView.inputHandler.of((view, from, to, text) => {
        const bullet = noteState.settings && noteState.settings.bullet;
        if (!bullet || text !== " " || from !== to) return false;
        const line = view.state.doc.lineAt(from);
        const m = /^(\s*)[-*]$/.exec(view.state.sliceDoc(line.from, from));
        if (!m) return false;
        for (let n = syntaxTree(view.state).resolveInner(from, -1); n; n = n.parent) if (n.name === "FencedCode" || n.name === "CodeBlock") return false;
        const start = line.from + m[1].length;
        view.dispatch({ changes: { from: start, to: from, insert: bullet + " " }, selection: { anchor: start + bullet.length + 1 }, userEvent: "input.type" });
        return true;
      }),
      keymap.of([
        { key: "Mod-b", run: wrapSelection("**") },
        { key: "Mod-i", run: wrapSelection("*") },
        { key: "Mod-Shift-x", run: wrapSelection("~~") },
        ...completionKeymap, ...historyKeymap, indentWithTab, ...defaultKeymap,
      ]),
      EditorView.domEventHandlers({
        focus: (_e, v) => { v.dispatch({ effects: setFocus.of(true) }); post("focus.changed", { focused: true }); },
        blur: (_e, v) => { v.dispatch({ effects: setFocus.of(false) }); post("focus.changed", { focused: false }); },
        paste: (e) => { const f = imageFiles(e.clipboardData); if (!f.length) return false; e.preventDefault(); sendImages(f); return true; },
        drop: (e) => { const f = imageFiles(e.dataTransfer); if (!f.length) return false; e.preventDefault(); sendImages(f); return true; },
        mousedown: (e, v) => {
          if (!(e.metaKey || e.ctrlKey)) return false;
          const pos = v.posAtCoords({ x: e.clientX, y: e.clientY });
          const url = pos == null ? null : linkAt(v, pos);
          if (!url) return false;
          e.preventDefault();
          post("link.open", { url });      // Swift decides what may open; the webview never navigates. SPEC.md §4.4
          return true;
        },
      }),
      EditorView.updateListener.of((u) => {
        if (!u.docChanged || suppress) return;
        clearTimeout(debounce);
        debounce = setTimeout(() => post("content.changed", { body: u.state.doc.toString() }), 120);
      }),
    ],
  }),
});

viewRef = view;

// A webview must never navigate away from the editor. SPEC.md §4.4.
document.addEventListener("click", (e) => { if (e.target.closest("a[href]")) e.preventDefault(); }, true);

function setBody(body, keepSelection) {
  const sel = view.state.selection.main;
  suppress = true;
  view.dispatch({
    changes: { from: 0, to: view.state.doc.length, insert: body },
    // A fresh "@Todo " note opens with the caret right after it, in front of the hint.
    selection: keepSelection ? { anchor: Math.min(sel.anchor, body.length) } : { anchor: /^@Todo\s*$/.test(body) ? body.length : 0 },
    effects: refresh.of(null),
  });
  suppress = false;
}

function applySettings(s) {
  const root = document.documentElement.style;
  const map = { fg: "--fg", fgDim: "--fg-dim", fgHint: "--fg-hint", accent: "--accent", surface: "--surface", rule: "--rule", highlight: "--highlight", font: "--font", size: "--size" };
  for (const [k, cssVar] of Object.entries(map)) if (s[k] != null) root.setProperty(cssVar, k === "size" ? s[k] + "px" : s[k]);
  noteState.settings = { ...noteState.settings, ...(s.bullet !== undefined ? { bullet: s.bullet } : {}) };
  if (s.spellcheck != null) {
    view.dispatch({ effects: spellCompartment.reconfigure(EditorView.contentAttributes.of({ spellcheck: String(s.spellcheck), autocorrect: "off", autocapitalize: "off" })) });
  }
  if (s.slashCommands === false) { /* handled by Swift filtering; kept for future use */ }
}

function setMode(mode) {
  view.dispatch({ effects: modeCompartment.reconfigure(mode === "source" ? sourceExt : livePreviewExt) });
}

// Header title edit: rewrite the first heading, or add one. SPEC.md §4.4 title sync.
function setTitle(title) {
  const doc = view.state.doc;
  for (let n = 1; n <= doc.lines; n++) {
    const l = doc.line(n);
    if (l.text.trim() === "") continue;
    if (/^@Todo(\s|$)/.test(l.text)) {                 // a todo note keeps its marker
      view.dispatch({ changes: { from: l.from, to: l.to, insert: `@Todo ${title.replace(/^@Todo\s*/, "")}` } });
      return;
    }
    const m = /^(#{1,6})\s+.*$/.exec(l.text);
    view.dispatch({ changes: m ? { from: l.from, to: l.to, insert: `${m[1]} ${title}` } : { from: l.from, insert: `# ${title}\n\n` } });
    return;
  }
  view.dispatch({ changes: { from: 0, insert: `# ${title}\n\n` } });
}

window.__pintack = {
  receive(msg) {
    const p = msg.payload || {};
    switch (msg.type) {
      case "note.load":
        noteState.noteId = msg.noteId;
        noteState.tags = p.tags || noteState.tags;
        if (p.settings) applySettings(p.settings);
        setMode(p.mode || "live");
        setBody(p.body || "", false);
        if (p.focus) view.focus();
        if (!pluginsStarted) { pluginsStarted = true; runtime.loadPlugins(p.plugins || []); }
        break;
      case "note.reload": setBody(p.body || "", true); break;
      case "settings.changed": applySettings(p); break;
      case "tags.changed": noteState.tags = p.tags || []; break;
      case "mode.set": setMode(p.mode); break;
      case "title.set": setTitle(p.title); break;
      case "emoji.open": view.focus(); openEmoji(view); break;
      case "bullet.pick": openEmoji(view, { pick: "bullet" }); break;
      case "plugin.result": runtime.onResult(p); break;
      case "plugin.progress": runtime.onProgress(p); break;
      case "plugin.event": runtime.emit(p.name, p.payload); break;
      case "plugin.settings": runtime.updateSettings(p.id, p.settings); break;
      case "command.run": runtime.runCommand(p.key); break;
      case "format.apply": if (applyFormat[p.kind]) applyFormat[p.kind](view); break;
      case "focus": view.focus(); break;
      case "image.inserted": {
        const sel = view.state.selection.main;
        edit(view, sel.from, sel.to, `![${p.alt || ""}](${p.path})\n`);
        break;
      }
      default: console.warn("unknown message", msg.type);
    }
  },
  // Test hooks: let tooling read state without going through Swift.
  _view: view,
};

post("ready");
