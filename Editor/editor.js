// PinTack editor: CodeMirror 6 with Obsidian-style Live Preview. SPEC.md §4.
//
// Live Preview means formatting renders as you type and raw markdown syntax is
// revealed only on the line holding the cursor. It is implemented as one
// StateField that turns the markdown syntax tree into decorations (hide the
// markers, style the content, swap a few constructs for widgets).
// A StateField rather than a ViewPlugin, because block-level replacements
// (tables) are only legal from a field.

import { EditorState, EditorSelection, Compartment, StateField, StateEffect, Prec, RangeSet } from "@codemirror/state";
import { EditorView, Decoration, WidgetType, keymap, placeholder, drawSelection,
         lineNumbers, gutterLineClass, GutterMarker, lineNumberMarkers, lineNumberWidgetMarker } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxTree, ensureSyntaxTree, syntaxHighlighting, HighlightStyle } from "@codemirror/language";
import { autocompletion, completionKeymap, startCompletion, closeCompletion } from "@codemirror/autocomplete";
import { tags as t } from "@lezer/highlight";
import { codeLanguages, badgeFor } from "./languages.js";
import { htmlToMarkdown } from "./html-to-markdown.js";
import { openFind } from "./find-overlay.js";
import { createRuntime } from "./plugin-runtime.js";
import { vimExtension, vimOwnsKeys, attachVim, promptEvent, closePrompt, takeFoldSnap } from "./vim-mode.js";

/* ------------------------------------------------------------------ bridge */

const noteState = { noteId: null, tags: [], settings: {}, templates: [] };

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

// ⌘↩ ticks or unticks the task on every line the selection touches (owner, 2026-09-21), so a
// checklist can be worked through without reaching for the mouse. The same three list markers
// Note.taskCounts counts (- * +), so the box that flips is always one the tracker can see.
// Anywhere that is not a task it declines, and ⌘↩ keeps doing what it did before.
function toggleTaskAtCursor(view) {
  const { state } = view;
  const changes = [];
  const seen = new Set();
  for (const range of state.selection.ranges) {
    const first = state.doc.lineAt(range.from).number, last = state.doc.lineAt(range.to).number;
    for (let n = first; n <= last; n++) {
      if (seen.has(n)) continue;
      seen.add(n);
      const line = state.doc.line(n);
      const m = /^(\s*[-*+]\s+\[)([ xX])\]/.exec(line.text);
      if (!m) continue;
      const at = line.from + m[1].length;
      changes.push({ from: at, to: at + 1, insert: m[2] === " " ? "x" : " " });
    }
  }
  if (!changes.length) return false;
  view.dispatch({ changes, userEvent: "input.toggle" });
  return true;
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

/* ------------------------------------------------------- link previews (§4.4)
 * A URL alone on its own line is drawn as a card: thumbnail, title, summary, domain. The page
 * never fetches anything — Swift does, only while Settings → Editor → Link previews is on, and
 * hands back a thumbnail already saved in the vault. `linkPreviews` holds what Swift has sent.
 * Hovering the card shows a ✕ that reverts that URL to plain text for good. */
const linkPreviews = new Map();      // url -> {title, summary, domain, image} | "failed"
const dismissedLinks = new Set();
let previewsEnabled = false;
let pasteAsMarkdown = true;      // Settings → Editor

class LinkPreviewWidget extends WidgetType {
  constructor(url, data) { super(); this.url = url; this.data = data; }
  eq(o) { return o.url === this.url && JSON.stringify(o.data) === JSON.stringify(this.data); }

  toDOM() {
    const card = document.createElement("div");
    card.className = "cm-link-card";

    if (this.data.image) {
      const img = document.createElement("img");
      img.className = "cm-link-thumb";
      img.src = resolveImage(this.data.image);
      img.alt = "";
      img.addEventListener("error", () => img.remove());
      card.appendChild(img);
    }

    const text = document.createElement("div");
    text.className = "cm-link-text";
    const title = document.createElement("div");
    title.className = "cm-link-title";
    title.textContent = this.data.title || this.url;
    text.appendChild(title);
    if (this.data.summary) {
      const summary = document.createElement("div");
      summary.className = "cm-link-summary";
      summary.textContent = this.data.summary;
      text.appendChild(summary);
    }
    const domain = document.createElement("div");
    domain.className = "cm-link-domain";
    domain.textContent = this.data.domain || "";
    text.appendChild(domain);
    card.appendChild(text);

    // Shown only on hover (CSS): cancels the embed and leaves the URL as written.
    const close = document.createElement("button");
    close.className = "cm-link-close";
    close.type = "button";
    close.textContent = "✕";
    close.title = "Show the plain link instead";
    close.setAttribute("aria-label", "Show the plain link instead");
    close.addEventListener("mousedown", (e) => {
      e.preventDefault();
      e.stopPropagation();
      dismissedLinks.add(this.url);
      post("linkpreview.dismiss", { url: this.url });
      if (viewRef) viewRef.dispatch({ effects: refresh.of(null) });
    });
    card.appendChild(close);

    // Swift decides what may open; the web view itself never navigates. SPEC.md §4.4
    card.addEventListener("mousedown", (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      post("link.open", { url: this.url });
    });
    // The card's margin lives on a plain slot around it: the editor's height map does not count a
    // block widget's own margin, and every gutter number below it drifted by that much.
    const slot = document.createElement("div");
    slot.className = "cm-link-slot";
    slot.appendChild(card);
    return slot;
  }

  ignoreEvent() { return true; }
}

/** A line that is nothing but one http(s) URL is the only thing that becomes a card. */
function bareLinkURL(text) {
  const t = text.trim();
  if (!/^https?:\/\/\S+$/i.test(t)) return null;
  return t;
}

// Asking is batched and asked once per URL: the decoration builder runs on every keystroke.
const requestedPreviews = new Set();
let previewRequestTimer = null;
function requestPreview(url) {
  if (requestedPreviews.has(url)) return;
  requestedPreviews.add(url);
  clearTimeout(previewRequestTimer);
  previewRequestTimer = setTimeout(() => {
    const pending = [...requestedPreviews].filter((u) => !linkPreviews.has(u));
    if (pending.length) post("linkpreview.request", { urls: pending });
  }, 250);
}

/* ------------------------------------------------------------ images (§7)
 * An image is edited where it sits. Click it and it grows four corner handles for resizing and a
 * small toolbar: crop, and a bin. There is no dialog and nothing to type — this is a sticky-note
 * app. The display width is written into the link as `![alt|320](path)`, the convention Obsidian
 * uses, so the file stays ordinary Markdown. Cropping is the one thing the page cannot do itself:
 * it hands Swift a rectangle, Swift writes a NEW attachment and the link is repointed at it. */
let selectedImage = null;            // document position of the image showing its handles
let pendingCrop = null;              // { pos, path } while Swift is doing the pixel work

function parseImageAlt(raw) {
  const m = /^([\s\S]*?)\|(\d{1,5})$/.exec(raw);
  return m ? { alt: m[1], width: Number(m[2]) } : { alt: raw, width: null };
}

function imageRangeAt(view, pos) {
  let n = syntaxTree(view.state).resolveInner(pos, 1);
  while (n && n.name !== "Image") n = n.parent;
  return n ? { from: n.from, to: n.to } : null;
}

function writeImage(view, pos, { alt, width, url }) {
  const range = imageRangeAt(view, pos);
  if (!range) return;
  const label = alt + (width ? "|" + Math.round(width) : "");
  view.dispatch({ changes: { from: range.from, to: range.to, insert: `![${label}](${url})` } });
}

function deleteImage(view, pos) {
  const range = imageRangeAt(view, pos);
  if (!range) return;
  selectedImage = null;
  view.dispatch({ changes: { from: range.from, to: range.to, insert: "" } });
}

function selectImage(pos) {
  if (selectedImage === pos) return;
  selectedImage = pos;
  if (viewRef) viewRef.dispatch({ effects: refresh.of(null) });
}

function deselectImage() {
  if (selectedImage === null) return;
  selectedImage = null;
  if (viewRef) viewRef.dispatch({ effects: refresh.of(null) });
}

const ICON = {
  crop: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4.5 1v10.5H15M1 4.5h10.5V15" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
  trash: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2.5 4h11M6.5 4V2.5h3V4M4 4l.8 9.5h6.4L12 4M6.6 6.6v5M9.4 6.6v5" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  tick: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3 8.5l3.5 3.5L13 4.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  cross: '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>',
};

class ImageWidget extends WidgetType {
  constructor(src, alt, width, from, selected) {
    super();
    this.src = src; this.alt = alt; this.width = width; this.from = from; this.selected = selected;
  }

  eq(o) {
    return o.src === this.src && o.alt === this.alt && o.width === this.width && o.selected === this.selected;
  }

  /// Where this image starts NOW. The stored `from` is only a fallback: the DOM outlives edits
  /// made elsewhere in the note, which shift every position after them.
  position(view, wrap) {
    try { return view.posAtDOM(wrap); } catch (_) { return this.from; }
  }

  toDOM(view) {
    const wrap = document.createElement("span");
    wrap.className = "cm-image-wrap" + (this.selected ? " cm-image-selected" : "");

    const img = document.createElement("img");
    img.className = "cm-image";
    img.alt = this.alt;
    img.draggable = false;
    img.src = resolveImage(this.src);
    if (this.width) img.style.width = this.width + "px";
    img.addEventListener("error", () => {
      const s = document.createElement("span");
      s.className = "cm-image-missing";
      s.textContent = `[image not found: ${this.alt || this.src}]`;
      wrap.replaceWith(s);
    });
    // A picture that arrives after the line was measured makes the line taller; tell the editor, or
    // the gutter numbers below it keep the old height.
    img.addEventListener("load", () => view.requestMeasure());
    wrap.appendChild(img);

    wrap.addEventListener("mousedown", (e) => {
      if (wrap.classList.contains("cm-image-cropping")) return;
      e.preventDefault();
      selectImage(this.position(view, wrap));
    });

    if (this.selected) {
      this.addTools(view, wrap, img);
      this.addHandles(view, wrap, img);
    }
    return wrap;
  }

  // MARK: resize

  addHandles(view, wrap, img) {
    for (const corner of ["nw", "ne", "sw", "se"]) {
      const handle = document.createElement("span");
      handle.className = "cm-image-handle cm-image-handle-" + corner;
      handle.addEventListener("mousedown", (e) => {
        e.preventDefault();
        e.stopPropagation();
        const startX = e.clientX;
        const startWidth = img.getBoundingClientRect().width;
        const grows = corner === "ne" || corner === "se" ? 1 : -1;
        wrap.classList.add("cm-image-resizing");

        const onMove = (ev) => {
          // Width only; the height follows so the picture can never be squashed.
          img.style.width = Math.max(48, startWidth + grows * (ev.clientX - startX)) + "px";
        };
        const onUp = () => {
          document.removeEventListener("mousemove", onMove);
          document.removeEventListener("mouseup", onUp);
          wrap.classList.remove("cm-image-resizing");
          const width = Math.round(img.getBoundingClientRect().width);
          writeImage(view, this.position(view, wrap), { alt: this.alt, width, url: this.src });
        };
        document.addEventListener("mousemove", onMove);
        document.addEventListener("mouseup", onUp);
      });
      wrap.appendChild(handle);
    }
  }

  // MARK: toolbar

  addTools(view, wrap, img) {
    const bar = document.createElement("span");
    bar.className = "cm-image-tools";
    const button = (name, title, run) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "cm-image-tool";
      b.title = title;
      b.setAttribute("aria-label", title);
      b.innerHTML = ICON[name];
      b.addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); run(); });
      bar.appendChild(b);
      return b;
    };
    button("crop", "Crop", () => this.startCrop(view, wrap, img, bar));
    button("trash", "Delete image", () => deleteImage(view, this.position(view, wrap)));
    wrap.appendChild(bar);

    // The bar sits above the picture. For an image at the very top of a note there is nothing
    // above to sit in and the scroller would clip it, so in that case it goes underneath instead.
    requestAnimationFrame(() => {
      const scroller = wrap.closest(".cm-scroller");
      if (!scroller) return;
      const room = wrap.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
      if (room < bar.getBoundingClientRect().height + 6) wrap.classList.add("cm-tools-below");
    });
  }

  // MARK: crop, framed on the picture itself

  startCrop(view, wrap, img, bar) {
    wrap.classList.add("cm-image-cropping");
    bar.innerHTML = "";

    // The shade and box live in their own layer, INSERTED BEFORE the toolbar. The dimming is an
    // oversized shadow that has to be clipped to the picture, and a full-size shade appended after
    // the toolbar covered it: the tick and cross drew fine and could not be clicked.
    const layer = document.createElement("span");
    layer.className = "cm-crop-layer";
    const shade = document.createElement("span");
    shade.className = "cm-crop-shade";
    const box = document.createElement("span");
    box.className = "cm-crop-box";
    layer.appendChild(shade);
    layer.appendChild(box);
    wrap.insertBefore(layer, bar);

    // Start with a rectangle inset from the edges, so there is something to drag straight away.
    const area = () => img.getBoundingClientRect();
    let rect = { x: area().width * 0.1, y: area().height * 0.1, w: area().width * 0.8, h: area().height * 0.8 };
    const paint = () => {
      box.style.left = rect.x + "px"; box.style.top = rect.y + "px";
      box.style.width = rect.w + "px"; box.style.height = rect.h + "px";
    };
    paint();

    const clampToImage = (r) => {
      const a = area();
      const x = Math.max(0, Math.min(r.x, a.width));
      const y = Math.max(0, Math.min(r.y, a.height));
      return { x, y, w: Math.max(12, Math.min(r.w, a.width - x)), h: Math.max(12, Math.min(r.h, a.height - y)) };
    };

    // Dragging anywhere on the picture draws a new rectangle.
    shade.addEventListener("mousedown", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const origin = area();
      const startX = e.clientX - origin.left, startY = e.clientY - origin.top;
      const onMove = (ev) => {
        const nowX = ev.clientX - origin.left, nowY = ev.clientY - origin.top;
        rect = clampToImage({ x: Math.min(startX, nowX), y: Math.min(startY, nowY),
                              w: Math.abs(nowX - startX), h: Math.abs(nowY - startY) });
        paint();
      };
      const onUp = () => {
        document.removeEventListener("mousemove", onMove);
        document.removeEventListener("mouseup", onUp);
      };
      document.addEventListener("mousemove", onMove);
      document.addEventListener("mouseup", onUp);
    });

    const finish = (apply) => {
      if (apply) {
        // The rectangle is in displayed pixels; the file is in its own. Scale before sending.
        const a = area();
        const scale = img.naturalWidth / a.width;
        pendingCrop = { pos: this.position(view, wrap), path: this.src };
        post("image.crop", {
          path: this.src,
          x: Math.round(rect.x * scale), y: Math.round(rect.y * scale),
          w: Math.round(rect.w * scale), h: Math.round(rect.h * scale),
        });
      }
      wrap.classList.remove("cm-image-cropping");
      layer.remove();
      document.removeEventListener("keydown", onKey, true);
      if (viewRef) viewRef.dispatch({ effects: refresh.of(null) });
    };

    // Return applies, Escape cancels. Capture phase, because the note's editor would otherwise
    // swallow Return as a newline before this ever sees it.
    const onKey = (e) => {
      if (e.key === "Enter") { e.preventDefault(); e.stopPropagation(); finish(true); }
      else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); finish(false); }
    };
    document.addEventListener("keydown", onKey, true);

    const button = (name, title, run) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "cm-image-tool";
      b.title = title;
      b.setAttribute("aria-label", title);
      b.innerHTML = ICON[name];
      b.addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); run(); });
      bar.appendChild(b);
    };
    button("tick", "Apply crop", () => finish(true));
    button("cross", "Cancel crop", () => finish(false));
  }

  ignoreEvent() { return true; }
}

// Relative paths (attachments/…) resolve against the app scheme; the Swift side
// serves them out of the vault. Anything remote is refused by the CSP anyway.
function resolveImage(src) {
  if (/^(https?|file):/i.test(src)) return "about:blank";
  if (src.startsWith("/")) return "__abs__" + src;
  return src.replace(/^\.\//, "");
}

class TableWidget extends WidgetType {
  // `onFold`: vim's cursor is standing on this table while it is folded (SPEC.md §4.6).
  constructor(text, onFold = false) { super(); this.text = text; this.onFold = onFold; }
  eq(o) { return o.text === this.text && o.onFold === this.onFold; }
  toDOM(view) {
    const lines = this.text.split("\n").filter((l) => l.trim() !== "");
    const wrap = document.createElement("div");
    wrap.className = "cm-table-wrap" + (this.onFold ? " pt-fold-cursor" : "");
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
      // In vim mode the table's first position is where the cursor stands on the FOLD, which keeps
      // it drawn; one character in is inside it, which opens it, as a click always has.
      const pos = view.posAtDOM(wrap) + (vimOn ? 1 : 0);
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
  const hiddenLines = [];      // start of every line Live Preview squashes out of sight (fences)
  const foldOpenLines = [];    // first line of every table open in vim mode, which gets a [−]
  const pinned = state.field(tableFolds);

  // Raw syntax shows on any line the selection touches. When the editor is not
  // focused nothing is "under the cursor", so the whole note renders.
  const lineTouched = (from, to) => {
    if (!focused) return false;
    const a = doc.lineAt(from).from, z = doc.lineAt(to).to;
    return sel.some((r) => r.from <= z && r.to >= a);
  };
  const touched = (from, to) => focused && sel.some((r) => r.from <= to && r.to >= from);

  const mark = (f, t, cls, attrs) => { if (t > f) deco.push(Decoration.mark({ class: cls, attributes: attrs }).range(f, t)); };
  const line = (pos, cls, attrs) => deco.push(Decoration.line({ class: cls, attributes: attrs }).range(pos));
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
        // The language badge (glyph + name) rides on the block's first line as data attributes;
        // editor.css draws it in the corner. Only a block that names a language gets one.
        const badge = lang ? badgeFor(lang) : null;
        let codeLine = 0;
        for (let n = first.number; n <= last.number; n++) {
          const l = doc.line(n);
          let cls = "cm-codeblock";
          let attrs;
          if (n === first.number) {
            cls += " cm-codeblock-first";
            if (badge) {
              cls += " cm-codeblock-tagged " + (badge.icon ? "cm-lang-icon" : "cm-lang-dot");
              attrs = { "data-lang": badge.name, style: `--lang-color:${badge.color}` };
              // The logo rides in as a CSS background so the badge can stay a ::after pseudo-element.
              // It is a file in the app bundle: the CSP's img-src allows pintack-app:, nothing remote.
              if (badge.icon) attrs.style += `;--lang-icon:url("icons/${badge.icon}.svg")`;
            }
          }
          if (n === last.number) cls += " cm-codeblock-last";
          const isFence = n === first.number || (n === last.number && n !== first.number && /^\s*(```|~~~)/.test(l.text));
          if (isFence && !editing) { cls += " cm-fence-hidden"; hide(l.from, l.to); hiddenLines.push(l.from); }
          // The block's own line numbers (Settings → Editor → Code blocks). The number rides in as an
          // attribute and editor.css draws it, so it is never part of the text and never copied.
          if (!isFence) { cls += " cm-code-body"; attrs = { ...(attrs || {}), "data-code-line": String(++codeLine) }; }
          line(l.from, cls, attrs);
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
            const raw = marks.length >= 2 ? doc.sliceString(marks[0].to, marks[1].from) : "";
            // `![alt|320](path)`: the number after the pipe is the display width the user dragged to.
            const { alt, width } = parseImageAlt(raw);
            swap(from, to, new ImageWidget(doc.sliceString(url.from, url.to), alt, width, from, selectedImage === from));
          }
        }
        return false;
      } else if (name === "Table") {
        const first = doc.lineAt(from), last = doc.lineAt(to);
        // In vim mode a table is a FOLD (SPEC.md §4.6): it opens when zo / the gutter's [+] pins it
        // open, or when the cursor is INSIDE it. Standing on its first or last position is standing
        // on the fold, which keeps it drawn, so j and k can step onto it and past it.
        const open = vimOn
          ? pinned.some((p) => p >= from && p <= to)
            || (focused && sel.some((r) => r.to > from && r.from < to && !(r.empty && (r.head === from || r.head === to))))
          : touched(from, to);
        if (open) {
          for (let n = first.number; n <= last.number; n++) line(doc.line(n).from, "cm-table-raw");
          if (vimOn) foldOpenLines.push(first.from);
        } else {
          const onFold = vimOn && sel.some((r) => r.empty && (r.head === from || r.head === to));
          swap(from, to, new TableWidget(doc.sliceString(from, to), onFold), true);
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

    // A line that is just a URL becomes a preview card, unless the caret is on it (so it stays
    // editable) or the user dismissed it. Anything not yet known is asked of Swift, once.
    if (previewsEnabled) {
      const linkURL = bareLinkURL(text);
      if (linkURL && !dismissedLinks.has(linkURL)) {
        const data = linkPreviews.get(linkURL);
        if (data === undefined) requestPreview(linkURL);
        else if (data !== "failed" && !touched(l.from, l.to)) {
          swap(l.from, l.to, new LinkPreviewWidget(linkURL, data), true);
          continue;
        }
      }
    }

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

  return { deco: Decoration.set(deco, true), atomic: Decoration.set(atomic, true),
           hiddenGutter: RangeSet.of(hiddenLines.map((pos) => hiddenGutterMarker.range(pos)), true),
           foldGutter: RangeSet.of(foldOpenLines.map((pos) => new FoldMarker(doc.lineAt(pos).number, 0).range(pos)), true) };
}

// ---- Table folds (vim mode, SPEC.md §4.6) --------------------------------------------------------
// A rendered table is several lines drawn as one block, so the gutter had no number for it and the
// cursor had nowhere to stand. In vim mode it is a fold, as vim itself would have it: "3 [+3]" in
// the gutter, j/k step onto it and over it, and zo / za / a click on [+] shows its Markdown.

// Starts of the tables pinned open, mapped through every edit.
const toggleTableFold = StateEffect.define();   // { pos, open: true | false }
const clearTableFolds = StateEffect.define();
const tableFolds = StateField.define({
  create: () => [],
  update(pins, tr) {
    let next = tr.docChanged ? pins.map((p) => tr.changes.mapPos(p, 1)) : pins;
    for (const e of tr.effects) {
      if (e.is(clearTableFolds)) next = [];
      else if (e.is(toggleTableFold)) {
        const rest = next.filter((p) => p !== e.value.pos);
        next = e.value.open ? [...rest, e.value.pos] : rest;
      }
    }
    return next;
  },
});

/** The table covering `pos` as { from, to, fromLine, toLine } (1-based lines), or null. */
function tableAt(state, pos) {
  let found = null;
  syntaxTree(state).iterate({ from: pos, to: pos, enter: (n) => {
    if (found) return false;
    if (n.name === "Table") { found = { from: n.from, to: n.to }; return false; }
  } });
  if (!found) return null;
  return { ...found, fromLine: state.doc.lineAt(found.from).number, toLine: state.doc.lineAt(found.to).number };
}

/** Is this table drawn folded right now? The same test build() makes. */
function tableClosed(state, t) {
  const pins = state.field(tableFolds, false);
  if (!pins) return false;                       // Source mode: tables are plain text, never folded
  if (pins.some((p) => p >= t.from && p <= t.to)) return false;
  return !state.selection.ranges.some((r) => r.to > t.from && r.from < t.to && !(r.empty && (r.head === t.from || r.head === t.to)));
}

/** For vim's line motions: the folded table on 1-based `line`, or null. */
function closedTableOnLine(state, line) {
  if (line < 1 || line > state.doc.lines) return null;
  const t = tableAt(state, state.doc.line(line).from);
  return t && tableClosed(state, t) ? t : null;
}

/** Opens (open=true), closes (false) or toggles (undefined) the table at `pos`. */
function foldTable(view, pos, open) {
  const t = tableAt(view.state, pos);
  if (!t) return false;
  const pins = view.state.field(tableFolds, false);
  if (!pins) return false;
  const pinnedOpen = pins.some((p) => p >= t.from && p <= t.to);
  const want = open === undefined ? tableClosed(view.state, t) : open;
  const effects = pins.filter((p) => p >= t.from && p <= t.to)
    .map((p) => toggleTableFold.of({ pos: p, open: false }));
  if (want) effects.push(toggleTableFold.of({ pos: t.from, open: true }));
  const spec = { effects };
  // Closing with the cursor inside would reopen it at once: the cursor goes to stand on the fold.
  const head = view.state.selection.main.head;
  if (!want && head > t.from && head < t.to) spec.selection = EditorSelection.cursor(t.from);
  if (!want && !pinnedOpen && !spec.selection) return true;
  view.dispatch(spec);
  return true;
}

/** zR / zM: every table open, or every one closed. */
function foldAllTables(view, open) {
  if (!open) {
    const spec = { effects: clearTableFolds.of(null) };
    const t = tableAt(view.state, view.state.selection.main.head);
    const head = view.state.selection.main.head;
    if (t && head > t.from && head < t.to) spec.selection = EditorSelection.cursor(t.from);
    view.dispatch(spec);
    return;
  }
  const effects = [];
  syntaxTree(view.state).iterate({ enter: (n) => {
    if (n.name === "Table") { effects.push(toggleTableFold.of({ pos: n.from, open: true })); return false; }
  } });
  view.dispatch({ effects });
}

/** The gutter's entry for a table: its first line number and [+N] folded, or [−] open. */
class FoldMarker extends GutterMarker {
  constructor(line, hidden) { super(); this.line = line; this.hidden = hidden; }
  eq(o) { return o.line === this.line && o.hidden === this.hidden; }
  toDOM() {
    const el = document.createElement("span");
    el.className = "pt-fold-entry";
    const num = document.createElement("span");
    num.textContent = String(this.line);
    const toggle = document.createElement("span");
    toggle.className = "pt-fold" + (this.hidden ? "" : " pt-fold-open");
    toggle.textContent = this.hidden ? `[+${this.hidden}]` : "[−]";
    toggle.title = this.hidden ? "Show this table's Markdown (zo)" : "Fold this table again (zc)";
    el.append(num, toggle);
    return el;
  }
}

const foldGutter = [
  lineNumbers({ domEventHandlers: {
    mousedown(view, block, event) {
      if (!(event.target instanceof Element) || !event.target.closest(".pt-fold")) return false;
      foldTable(view, block.from);
      return true;
    },
  } }),
  lineNumberWidgetMarker.of((view, widget, block) => {
    if (!(widget instanceof TableWidget)) return null;
    const first = view.state.doc.lineAt(block.from).number;
    return new FoldMarker(first, view.state.doc.lineAt(block.to).number - first + 1);
  }),
  // After j lands on a folded table's first line, the cursor stands on the fold, not in a cell.
  EditorState.transactionFilter.of((tr) => {
    const snap = takeFoldSnap();
    if (!snap || tr.docChanged || !tr.selection) return tr;
    const main = tr.selection.main;
    if (main.head <= snap.from || main.head >= snap.to) return tr;
    return [tr, { selection: EditorSelection.range(main.empty ? snap.from : main.anchor, snap.from), sequential: true }];
  }),
];

// A gutter number beside a line squashed to 4px would be a clipped smudge, so those lines keep
// their number (it is still a real line: `12G` counts it) but do not show it.
const hiddenGutterMarker = new (class extends GutterMarker { get elementClass() { return "pt-gutter-hidden"; } })();

const livePreview = StateField.define({
  create: (state) => build(state),
  update(value, tr) {
    const relevant = tr.docChanged || tr.selection
      || tr.effects.some((e) => e.is(setFocus) || e.is(refresh) || e.is(toggleTableFold) || e.is(clearTableFolds));
    return relevant ? build(tr.state) : value;
  },
  provide: (f) => [
    EditorView.decorations.from(f, (v) => v.deco),
    // Arrow keys step over hidden syntax instead of into invisible characters.
    EditorView.atomicRanges.of((view) => view.state.field(f).atomic),
    gutterLineClass.from(f, (v) => v.hiddenGutter),
    lineNumberMarkers.from(f, (v) => v.foldGutter),
  ],
});

const livePreviewExt = [focusField, tableFolds, livePreview, EditorView.editorAttributes.of({ class: "cm-mode-live" })];

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

// Tokens INSIDE a fenced code block, once its language has loaded. Markdown itself never produces
// these tags, so this style is safe in Live Preview too, where markdown is drawn by decorations.
// Colours are CSS variables so they follow the note's own light/dark paper. SPEC.md §4.2.
const codeHighlight = HighlightStyle.define([
  { tag: [t.keyword, t.moduleKeyword, t.controlKeyword, t.operatorKeyword], color: "var(--code-keyword)" },
  { tag: [t.string, t.special(t.string), t.regexp], color: "var(--code-string)" },
  { tag: [t.comment, t.lineComment, t.blockComment, t.docComment], color: "var(--code-comment)", fontStyle: "italic" },
  { tag: [t.number, t.bool, t.null, t.atom], color: "var(--code-number)" },
  // Builtins and definitions carry most of the meaning in shell and PowerShell, where the legacy
  // stream modes tag Get-Process and friends as standard/defined variable names rather than keywords.
  { tag: [t.function(t.variableName), t.function(t.propertyName), t.macroName,
          t.standard(t.variableName), t.definition(t.variableName), t.definition(t.propertyName)],
    color: "var(--code-function)" },
  { tag: [t.typeName, t.className, t.namespace, t.standard(t.typeName), t.definition(t.typeName)], color: "var(--code-type)" },
  { tag: [t.propertyName, t.attributeName, t.labelName], color: "var(--code-property)" },
  { tag: [t.variableName, t.special(t.variableName), t.character, t.literal, t.unit], color: "var(--code-variable)" },
  { tag: [t.operator, t.derefOperator, t.compareOperator, t.arithmeticOperator,
          t.logicOperator, t.bitwiseOperator, t.updateOperator, t.definitionOperator],
    color: "var(--code-operator)" },
  { tag: [t.punctuation, t.separator, t.bracket, t.squareBracket, t.paren, t.brace], color: "var(--code-punct)" },
  { tag: [t.attributeValue], color: "var(--code-string)" },
  { tag: [t.escape, t.special(t.string)], color: "var(--code-meta)" },
  { tag: [t.tagName, t.angleBracket], color: "var(--code-tag)" },
  { tag: [t.meta, t.processingInstruction], color: "var(--code-meta)" },
  { tag: t.invalid, color: "var(--code-invalid)" },
  { tag: [t.inserted], color: "var(--code-string)" },
  { tag: [t.deleted], color: "var(--code-invalid)" },
]);

/* ---------------------------------------------------------- slash commands */

const COLORS = [
  ["red", "#e5484d"], ["orange", "#e07b39"], ["green", "#2f9e5b"],
  ["blue", "#2f6fdd"], ["purple", "#8a4fd6"], ["pink", "#d6409f"], ["gray", "#6b6b73"],
];
// The languages offered in the slash menu. Any language in Editor/languages.js highlights when
// typed after the fence; these are just the ones worth a one-keystroke shortcut.
const LANGS = ["powershell", "bash", "python", "json", "yaml", "sql", "swift", "javascript",
               "typescript", "html", "css", "xml", "go", "rust", "dockerfile", "ini", "diff"];

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
  ["checklist", "Checklist", linePrefix("- [ ] ")],
  ["divider", "Divider", (v, _c, f, to) => edit(v, f, to, "---\n")],
  ["highlight", "Highlight", wrap("==", "==", "text")],
  ["link", "Link", (v, _c, f, to) => edit(v, f, to, "[text](https://)", 1, 4)],
  ["table", "Table", (v, _c, f, to) => edit(v, f, to, "| Column 1 | Column 2 |\n| --- | --- |\n|  |  |\n", 2, 0)],
  ["code", "Code block", (v, _c, f, to) => edit(v, f, to, "```\n\n```", 4)],
  ["date", "Today's date", (v, _c, f, to) => edit(v, f, to, stamp("date")())],
  ["time", "Current time", (v, _c, f, to) => edit(v, f, to, stamp("time")())],
  ["tag", "Tag", (v, _c, f, to) => { edit(v, f, to, "#"); startCompletion(v); }],
  // Native actions: the slash menu is just another way to reach what the note's own controls do.
  ["freeze", "Freeze / thaw (click-through)", (v, _c, f, to) => { edit(v, f, to, ""); post("note.action", { action: "freeze" }); }],
  ["find", "Find a note…", (v, _c, f, to) => { edit(v, f, to, ""); post("notes.list"); }],
  ["stack", "Stack with other notes…", (v, _c, f, to) => { edit(v, f, to, ""); post("note.action", { action: "stack" }); }],
  ["template", "Save as template…", (v, _c, f, to) => { edit(v, f, to, ""); post("template.save"); }],
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

/* ---------------------------------------------------------- @ recall (§8)
 * `@todo` typed anywhere turns the note into a todo list; `@name` recalls a template. The @Todo
 * marker already sitting on line 1 is neither: it IS the todo note, so it is left alone. */

const TODO_TRIGGER = /(^|[\s(])@todo$/i;

/** Puts "@Todo " on line 1 with the greyed title hint, and removes the trigger the user typed. */
function convertToTodo(view, triggerFrom, triggerTo) {
  const doc = view.state.doc;
  if (/^@Todo(\s|$)/.test(doc.line(1).text)) {
    // Already a todo note: just drop the text they typed rather than stacking a second marker.
    view.dispatch({ changes: { from: triggerFrom, to: triggerTo, insert: "" } });
    return;
  }
  view.dispatch({
    changes: [{ from: triggerFrom, to: triggerTo, insert: "" }, { from: 0, insert: "@Todo \n\n" }],
    selection: { anchor: 6 },        // right after "@Todo ", in front of the hint
    // Converting from the bottom of a long note used to leave you staring at the bottom while the
    // title you are meant to type sat off-screen at the top.
    scrollIntoView: true,
  });
  post("note.action", { action: "tagTodo" });
}

/** Template names offered after an @. */
function templateSource(ctx) {
  const m = ctx.matchBefore(/@[\w.-]*/);
  // A bare "@" opens the list, the way a bare "/" opens the commands. Requiring a letter first
  // meant nobody could discover what templates existed.
  if (!m) return null;
  if (m.from > 0 && !/[\s(]/.test(ctx.state.sliceDoc(m.from - 1, m.from))) return null;
  // Line 1's @Todo marker is the note's own title, not a template recall.
  if (ctx.state.doc.lineAt(m.from).number === 1 && /^@Todo(\s|$)/.test(ctx.state.doc.line(1).text)) return null;

  const typed = m.text.slice(1).toLowerCase();
  const options = noteState.templates
    .filter((t) => t.name.toLowerCase().startsWith(typed))
    .map((t) => ({
      label: "@" + t.name,
      detail: t.title,
      type: "keyword",
      apply: (view, _c, from, to) => {
        // Enter inserts the whole template where the @ was.
        view.dispatch({ changes: { from, to, insert: t.body }, userEvent: "input.complete" });
      },
    }));
  // "@todo" is offered too, because converting a note is the other thing an @ can do here.
  if ("todo".startsWith(typed)) {
    options.unshift({
      label: "@todo",
      detail: "Turn this into a todo note",
      type: "keyword",
      apply: (view, _c, from, to) => convertToTodo(view, from, to),
    });
  }
  return options.length ? { from: m.from, options, validFor: /^@[\w.-]*$/ } : null;
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
const vimCompartment = new Compartment();
const gutterCompartment = new Compartment();
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

/* ------------------------------------------------------- scrollbar (§4.1)
 * The bar is invisible until it is useful: while the view is actually scrolling, or while the
 * pointer is near the right edge where you would reach for it. A permanent bar down the side of a
 * sticky note is a lot of furniture for something usually two lines long.
 *
 * WebKit gives no "is scrolling" state and cannot style a pseudo-element from a parent's :hover in
 * the way this needs, so the class is managed here. */
const SCROLLBAR_EDGE = 26;        // how close to the right edge counts as reaching for it
let scrollbarTimer = null;

function showScrollbar(scroller, sticky) {
  scroller.classList.add("cm-show-scrollbar");
  clearTimeout(scrollbarTimer);
  // Cleared to null, not just cancelled: a timeout id stays truthy after it has fired, and the
  // pointer check below reads this as "still in the grace period after a scroll" — which left the
  // bar up for good once anything had scrolled.
  scrollbarTimer = null;
  if (sticky) return;                       // the pointer is there: leave it up until it leaves
  scrollbarTimer = setTimeout(() => {
    scrollbarTimer = null;
    scroller.classList.remove("cm-show-scrollbar");
  }, 900);
}

function watchScrollbar(view) {
  const scroller = view.scrollDOM;
  scroller.addEventListener("scroll", () => showScrollbar(scroller, false), { passive: true });
  scroller.addEventListener("mousemove", (e) => {
    const near = scroller.getBoundingClientRect().right - e.clientX <= SCROLLBAR_EDGE;
    if (near) showScrollbar(scroller, true);
    else if (!scrollbarTimer) scroller.classList.remove("cm-show-scrollbar");
  });
  scroller.addEventListener("mouseleave", () => {
    if (!scrollbarTimer) scroller.classList.remove("cm-show-scrollbar");
  });
}

const view = new EditorView({
  parent: document.getElementById("editor"),
  state: EditorState.create({
    doc: "",
    extensions: [
      history(),
      drawSelection(),
      EditorView.lineWrapping,
      markdown({ base: markdownLanguage, codeLanguages }),
      syntaxHighlighting(codeHighlight),
      modeCompartment.of(livePreviewExt),
      spellCompartment.of(EditorView.contentAttributes.of({ spellcheck: "false", autocorrect: "off", autocapitalize: "off" })),
      placeholder("Start typing…  ( / for commands )"),
      autocompletion({ override: [slashSource, tagSource, templateSource], icons: false, defaultKeymap: true }),
      vimCompartment.of([]),
      gutterCompartment.of([]),
      // In vim's normal and visual modes these keys are vim's (Enter moves down a line); the checklist
      // continuation, span exit and ⌘↩ belong to typing, which is insert mode.
      Prec.highest(keymap.of([{ key: "Enter", run: (v) => !vimOwnsKeys(v) && enterHandler(v) },
                              { key: "Tab", run: (v) => !vimOwnsKeys(v) && tabOutOfSpan(v) },
                              { key: "Mod-Enter", run: (v) => !vimOwnsKeys(v) && toggleTaskAtCursor(v) }])),
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
        paste: (e, v) => {
          const files = imageFiles(e.clipboardData);
          if (files.length) { e.preventDefault(); sendImages(files); return true; }
          // Rich text: keep the headings, links and lists instead of flattening them. Shift-Cmd-V
          // skips this and pastes the plain flavour, the usual macOS escape hatch.
          if (e.shiftKey || !pasteAsMarkdown) return false;
          const html = e.clipboardData && e.clipboardData.getData("text/html");
          if (!html) return false;
          let markdown = "";
          try { markdown = htmlToMarkdown(html); } catch (_) { return false; }
          const plain = (e.clipboardData.getData("text/plain") || "").trim();
          // Only worth it when the conversion actually kept something the plain text lost.
          if (!markdown || markdown === plain) return false;
          e.preventDefault();
          const sel = v.state.selection.main;
          v.dispatch({ changes: { from: sel.from, to: sel.to, insert: markdown },
                       selection: { anchor: sel.from + markdown.length }, userEvent: "input.paste" });
          return true;
        },
        drop: (e) => { const f = imageFiles(e.dataTransfer); if (!f.length) return false; e.preventDefault(); sendImages(f); return true; },
        mousedown: (e, v) => {
          if (selectedImage !== null && !(e.target instanceof Element && e.target.closest(".cm-image-wrap"))) deselectImage();
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
        // A ✕'d preview is forgotten as soon as its link leaves the note, so deleting the URL and
        // pasting it again shows the card again. Swift prunes its own copy the same way.
        if (dismissedLinks.size) {
          const text = u.state.doc.toString();
          for (const url of [...dismissedLinks]) if (!text.includes(url)) dismissedLinks.delete(url);
        }
        clearTimeout(debounce);
        debounce = setTimeout(() => post("content.changed", { body: u.state.doc.toString() }), 120);
      }),
    ],
  }),
});

viewRef = view;
watchScrollbar(view);

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
  const map = { fg: "--fg", fgDim: "--fg-dim", fgHint: "--fg-hint", accent: "--accent", chromeAccent: "--chrome-accent", surface: "--surface", rule: "--rule", highlight: "--highlight", font: "--font", size: "--size", inlineCode: "--inline-code-bg", codeBlock: "--code-bg" };
  for (const [k, cssVar] of Object.entries(map)) if (s[k] != null) root.setProperty(cssVar, k === "size" ? s[k] + "px" : s[k]);
  // Which of the two code-token palettes suits this note's paper. editor.css keys off it.
  if (s.paper != null) document.documentElement.dataset.paper = s.paper;
  // Tokens INSIDE a fenced block follow the block's own panel instead, which may be dark on a
  // light note. Swift decides by compositing the panel over the paper.
  if (s.codePaper != null) document.documentElement.dataset.codePaper = s.codePaper;
  noteState.settings = { ...noteState.settings, ...(s.bullet !== undefined ? { bullet: s.bullet } : {}) };
  if (s.spellcheck != null) {
    view.dispatch({ effects: spellCompartment.reconfigure(EditorView.contentAttributes.of({ spellcheck: String(s.spellcheck), autocorrect: "off", autocapitalize: "off" })) });
  }
  if (s.slashCommands === false) { /* handled by Swift filtering; kept for future use */ }
  if (s.pasteAsMarkdown != null) pasteAsMarkdown = s.pasteAsMarkdown;
  if (s.codeLineNumbers != null) codeLineNumbers = s.codeLineNumbers;
  if (s.vim != null && s.vim !== vimOn) setVim(s.vim);
  // A block numbers itself only when vim mode is off; with vim on, the note's gutter numbers
  // every line, code included (owner, 2026-09-21).
  document.documentElement.dataset.codeLines = codeLineNumbers && !vimOn ? "on" : "off";
  if (s.linkPreviews != null && s.linkPreviews !== previewsEnabled) {
    previewsEnabled = s.linkPreviews;
    // Turning the setting off must drop the cards immediately, not at the next keystroke.
    if (viewRef) viewRef.dispatch({ effects: refresh.of(null) });
  }
}

let vimOn = false;
let codeLineNumbers = false;

async function setVim(on) {
  vimOn = on;
  document.documentElement.dataset.codeLines = codeLineNumbers && !vimOn ? "on" : "off";
  document.documentElement.dataset.vim = on ? "on" : "off";
  if (!on) {
    closePrompt();
    view.dispatch({ effects: [vimCompartment.reconfigure([]), gutterCompartment.reconfigure([]), clearTableFolds.of(null), refresh.of(null)] });
    post("vim.mode", { mode: null });
    return;
  }
  const ext = await vimExtension();
  if (!vimOn) return;                     // switched off again while the package was loading
  view.dispatch({ effects: [vimCompartment.reconfigure(ext), gutterCompartment.reconfigure(foldGutter), refresh.of(null)] });
  attachVim(view, post, (mode) => {
    // Leaving insert mode must not leave a slash or template menu floating over normal mode.
    if (mode !== "INSERT") closeCompletion(view);
    post("vim.mode", { mode });
  }, {
    closedTableOnLine: (line) => closedTableOnLine(view.state, line),
    fold: (pos, open) => foldTable(view, pos, open),
    foldAll: (open) => foldAllTables(view, open),
  });
}

function setMode(mode) {
  view.dispatch({ effects: modeCompartment.reconfigure(mode === "source" ? sourceExt : livePreviewExt) });
}

window.__pintack = {
  receive(msg) {
    const p = msg.payload || {};
    switch (msg.type) {
      case "note.load":
        noteState.noteId = msg.noteId;
        noteState.tags = p.tags || noteState.tags;
        noteState.templates = p.templates || noteState.templates;
        if (p.settings) applySettings(p.settings);
        setMode(p.mode || "live");
        setBody(p.body || "", false);
        if (p.focus) view.focus();
        if (!pluginsStarted) { pluginsStarted = true; runtime.loadPlugins(p.plugins || []); }
        break;
      case "note.reload": setBody(p.body || "", true); break;
      case "settings.changed": applySettings(p); break;
      case "tags.changed": noteState.tags = p.tags || []; break;
      case "templates.changed": noteState.templates = p.templates || []; break;

      // Swift answered /find with the vault's notes; put the quick-open overlay up. SPEC.md §8.
      case "notes.list":
        if (viewRef) openFind({ view: viewRef, post, notes: p.notes || [] });
        break;

      // Link previews arriving from Swift (it alone fetches them). SPEC.md §4.4.
      case "linkpreview.result":
        for (const preview of p.previews || []) linkPreviews.set(preview.url, preview);
        if (viewRef) viewRef.dispatch({ effects: refresh.of(null) });
        break;
      case "linkpreview.failed":
        linkPreviews.set(p.url, "failed");
        break;
      // Swift cropped the pixels into a NEW attachment; repoint the link at it. SPEC.md §7.
      case "image.cropped": {
        const job = pendingCrop;
        pendingCrop = null;
        if (!job || !viewRef || !p.newPath) break;
        const range = imageRangeAt(viewRef, job.pos);
        if (!range) break;
        const current = viewRef.state.sliceDoc(range.from, range.to);
        const m = /^!\[([\s\S]*)\]\(([^)]*)\)$/.exec(current);
        if (!m || m[2] !== job.path) break;        // the note moved on; leave it alone
        viewRef.dispatch({ changes: { from: range.from, to: range.to, insert: `![${m[1]}](${p.newPath})` } });
        break;
      }
      case "linkpreview.dismissed":
        dismissedLinks.add(p.url);
        if (viewRef) viewRef.dispatch({ effects: refresh.of(null) });
        break;
      case "mode.set": setMode(p.mode); break;
      case "emoji.open": view.focus(); openEmoji(view); break;
      case "bullet.pick": openEmoji(view, { pick: "bullet" }); break;
      case "plugin.result": runtime.onResult(p); break;
      case "plugin.progress": runtime.onProgress(p); break;
      case "plugin.event": runtime.emit(p.name, p.payload); break;
      case "plugin.settings": runtime.updateSettings(p.id, p.settings); break;
      case "command.run": runtime.runCommand(p.key); break;
      case "format.apply": if (applyFormat[p.kind]) applyFormat[p.kind](view); break;
      case "focus": view.focus(); break;
      case "vim.prompt.input":
      case "vim.prompt.key":
      case "vim.prompt.submit": promptEvent(msg.type, p); break;
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
