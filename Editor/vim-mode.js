// Vim mode, owner-approved 2026-09-21. SPEC.md §4.6.
//
// @replit/codemirror-vim (MIT) supplies vi/vim itself. It is imported the first time vim mode is
// switched on, never with the editor, so a note in an ordinary PinTack pays nothing for it — the
// same rule as the language parsers.
//
// What PinTack adds on top:
//  - The ":" and "/" prompt does not draw in the page. It is handed to Swift, which turns the note's
//    ACTION BAR into the command bar (owner's request), and every keystroke is handed back to the
//    engine's own prompt handlers, so incremental search and command history work unchanged.
//  - :w saves, :q closes the note, :wq / :x / ZZ do both. A note is one buffer, so there are no
//    splits, tabs or :e.
//  - The mode (NORMAL, INSERT, VISUAL…) is reported to Swift for the action bar.

import { Prec } from "@codemirror/state";

let pkg = null;                 // the vim package, once loaded
let post = () => {};            // the bridge to Swift, set by attachVim
let exDefined = false;          // :w/:q are defined on the package's global Vim object, once
let session = null;             // the prompt Swift is showing, if any

/** Loads the package (once) and returns the extension to install. */
export async function vimExtension() {
  if (!pkg) pkg = await import("@replit/codemirror-vim");
  return Prec.highest(pkg.vim());
}

/** True when vim is on and NOT in insert mode: the editor's own Enter/Tab/⌘↩ must stand aside. */
export function vimOwnsKeys(view) {
  if (!pkg) return false;
  const cm = pkg.getCM(view);
  return !!(cm && cm.state.vim && !cm.state.vim.insertMode);
}

/** The vim mode as the action bar shows it, or null when vim is off. */
function modeName(event) {
  const mode = event && event.mode;
  if (mode === "visual") return event.subMode === "linewise" ? "V-LINE" : event.subMode === "blockwise" ? "V-BLOCK" : "VISUAL";
  if (mode === "insert") return "INSERT";
  if (mode === "replace") return "REPLACE";
  return "NORMAL";
}

/** Wires a freshly installed vim into PinTack: the prompt, messages, mode reports, ex commands. */
export function attachVim(view, bridge, onModeChange) {
  if (!pkg) return;
  post = bridge;
  const cm = pkg.getCM(view);
  if (!cm || cm.__pintack) return;
  cm.__pintack = true;

  if (!exDefined) {
    exDefined = true;
    const { Vim } = pkg;
    Vim.defineEx("write", "w", () => post("note.action", { action: "save" }));
    Vim.defineEx("quit", "q", () => post("note.action", { action: "close" }));
    Vim.defineEx("wq", "wq", () => { post("note.action", { action: "save" }); post("note.action", { action: "close" }); });
    Vim.defineEx("xit", "x", () => { post("note.action", { action: "save" }); post("note.action", { action: "close" }); });
    Vim.map("ZZ", ":x<CR>", "normal");
  }

  // The prompt, redirected to the action bar. The engine calls this with a template holding the
  // prefix (":" "/" "?") and an input; everything it needs back comes through the handlers below.
  cm.openDialog = (template, callback, options = {}) => {
    const input = template && template.querySelector ? template.querySelector("input") : null;
    if (!input) {
      // No input: a status line, such as "recording @q". Shown until closed.
      post("vim.notify", { text: template.textContent || "", sticky: true });
      return () => post("vim.notify", { text: "", sticky: false });
    }
    const prefix = (input.parentElement && input.parentElement.textContent) || ":";
    const s = { callback, options, value: options.value || "", closed: false };
    s.close = (newValue) => {
      if (typeof newValue === "string") {            // the engine replacing the text (history, Ctrl-U)
        s.value = newValue;
        post("vim.prompt.value", { value: newValue });
        return;
      }
      if (s.closed) return;
      s.closed = true;
      if (session === s) session = null;
      post("vim.prompt.close");
      if (options.onClose) options.onClose();
      view.focus();
    };
    if (session) session.close();
    session = s;
    post("vim.prompt.open", { prefix, value: s.value });
    return s.close;
  };

  // Messages ("E492: Not an editor command", "search hit BOTTOM") go to the action bar too.
  cm.openNotification = (template, options = {}) => {
    post("vim.notify", { text: (template && template.textContent) || "", sticky: false });
    return () => {};
  };

  // j and k always land on the next LINE. The engine also measures an on-screen move and, when that
  // goes further, assumes the gap is folded text and steps over it whole. PinTack folds nothing, but
  // Live Preview draws a table as one block and squashes a code fence to 4px, which look folded: j
  // jumped a whole table, and one k from the bottom of a note landed at the top. Measured, then fixed.
  const findPosV = cm.findPosV.bind(cm);
  cm.findPosV = (start, amount, unit, goalColumn) => {
    const pos = findPosV(start, amount, unit, goalColumn);
    if (unit !== "line") return pos;
    const target = Math.max(cm.firstLine(), Math.min(cm.lastLine(), start.line + amount));
    const overshot = amount > 0 ? pos.line > target : pos.line < target;
    return overshot ? { line: target, ch: pos.ch } : pos;
  };

  cm.on("vim-mode-change", (event) => onModeChange(modeName(event)));
  onModeChange("NORMAL");
}

/** A keyboard event the engine's prompt handlers can read, built from what Swift reports. */
function keyEvent(key, value) {
  return {
    key, code: "", keyCode: { Enter: 13, Escape: 27, Backspace: 8, ArrowUp: 38, ArrowDown: 40 }[key] || 0,
    ctrlKey: false, altKey: false, metaKey: false, shiftKey: false,
    target: { value, selectionStart: value.length, selectionEnd: value.length },
    preventDefault() {}, stopPropagation() {},
  };
}

/** Swift's command bar reports its text and keys here. */
export function promptEvent(type, p) {
  const s = session;
  if (!s) return;
  const o = s.options;
  if (type === "vim.prompt.input") {
    s.value = p.text || "";
    if (o.onKeyUp) o.onKeyUp(keyEvent(p.key || "a", s.value), s.value, s.close);
  } else if (type === "vim.prompt.key") {
    const e = keyEvent(p.key, s.value);
    if (o.onKeyDown) o.onKeyDown(e, s.value, s.close);
    // Search walks its history on key UP; commands on key DOWN. Both get both, as in a browser.
    if ((p.key === "ArrowUp" || p.key === "ArrowDown") && o.onKeyUp && !s.closed) o.onKeyUp(e, s.value, s.close);
    if ((p.key === "Escape" || (p.key === "Backspace" && s.value === "")) && !s.closed) s.close();
  } else if (type === "vim.prompt.submit") {
    s.value = p.text || "";
    try {
      if (o.onKeyDown && o.onKeyDown(keyEvent("Enter", s.value), s.value, s.close)) return;
      if (s.callback) s.callback(s.value);
    } catch (error) {
      // A command that throws must not leave the command bar stuck over the action bar.
      console.error("vim command failed", error);
      post("vim.notify", { text: String(error && error.message || error), sticky: false });
    } finally {
      s.close();
    }
  }
}

/** The prompt closes if vim is switched off while it is open. */
export function closePrompt() { if (session) session.close(); }

export function hasPackage() { return !!pkg; }
export function packageForTests() { return pkg; }
