/* Quick open: the /find overlay. SPEC.md §8.
 *
 * A search box over the middle of the note that fuzzy-matches every note as you type. Arrow keys
 * walk the results, Return opens the one you want.
 *
 * The thing that makes it feel right: opening a note does NOT take you there. The caret goes back
 * to exactly where you were typing before you asked, so looking something up never costs you your
 * place. The Swift side opens the other note without focusing it, and this restores the selection
 * it saved on the way in.
 */

let current = null;

/** Subsequence match with a score, so "int prof" finds "Intune profile drift". */
export function fuzzyScore(needle, haystack) {
  const query = needle.toLowerCase().replace(/\s+/g, "");
  if (!query) return 0;
  const text = haystack.toLowerCase();
  let score = 0;
  let at = -1;
  let streak = 0;
  for (const ch of query) {
    const found = text.indexOf(ch, at + 1);
    if (found === -1) return -1;
    if (found === at + 1) { streak += 1; score += 6 + streak * 2; }   // consecutive letters are a strong signal
    else { streak = 0; score += 1; }
    // Matching the start of a word beats matching the middle of one.
    if (found === 0 || /[\s/\-_#]/.test(text[found - 1])) score += 8;
    at = found;
  }
  return score - Math.min(at, 40) * 0.1;      // an early match beats a late one
}

export function openFind({ view, post, notes }) {
  if (current) current.close(false);

  const saved = view.state.selection.main;          // where the caret was before any of this
  const root = document.createElement("div");
  root.className = "cm-find";
  root.innerHTML = `
    <div class="cm-find-box">
      <input class="cm-find-input" type="text" placeholder="Find a note…" spellcheck="false" autocomplete="off">
      <div class="cm-find-results" role="listbox"></div>
      <div class="cm-find-hint">↑↓ to choose · ↵ to open · esc to close</div>
    </div>`;
  document.body.appendChild(root);

  const input = root.querySelector(".cm-find-input");
  const list = root.querySelector(".cm-find-results");
  let matches = [];
  let active = 0;

  const render = () => {
    list.innerHTML = "";
    if (!matches.length) {
      const empty = document.createElement("div");
      empty.className = "cm-find-empty";
      empty.textContent = input.value.trim() ? "No notes match" : "Start typing to search your notes";
      list.appendChild(empty);
      return;
    }
    matches.forEach((note, index) => {
      const row = document.createElement("div");
      row.className = "cm-find-row" + (index === active ? " cm-find-active" : "");
      row.setAttribute("role", "option");
      const title = document.createElement("div");
      title.className = "cm-find-title";
      title.textContent = note.title;
      row.appendChild(title);
      const sub = [note.folder, note.preview].filter(Boolean).join(" · ");
      if (sub) {
        const meta = document.createElement("div");
        meta.className = "cm-find-meta";
        meta.textContent = sub;
        row.appendChild(meta);
      }
      row.addEventListener("mousedown", (e) => { e.preventDefault(); choose(index); });
      list.appendChild(row);
    });
    const activeRow = list.children[active];
    if (activeRow && activeRow.scrollIntoView) activeRow.scrollIntoView({ block: "nearest" });
  };

  const search = () => {
    const query = input.value.trim();
    if (!query) {
      matches = notes.slice(0, 20);
    } else {
      matches = notes
        .map((note) => {
          const onTitle = fuzzyScore(query, note.title);
          const onBody = onTitle >= 0 ? -1 : fuzzyScore(query, note.preview || "");
          // A title match always outranks a body match, however good the body one looks.
          const score = onTitle >= 0 ? onTitle + 100 : onBody;
          return { note, score };
        })
        .filter((m) => m.score >= 0)
        .sort((a, b) => b.score - a.score)
        .slice(0, 50)
        .map((m) => m.note);
    }
    active = 0;
    render();
  };

  const choose = (index) => {
    const note = matches[index];
    if (note) post("note.open", { id: note.id });
    close(true);
  };

  const close = (restore) => {
    document.removeEventListener("keydown", onKey, true);
    root.remove();
    current = null;
    if (restore) {
      // Back to exactly where the search started, never to whatever was just opened.
      view.focus();
      view.dispatch({ selection: { anchor: saved.anchor, head: saved.head }, scrollIntoView: true });
    }
  };

  const onKey = (e) => {
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); close(true); }
    else if (e.key === "ArrowDown") { e.preventDefault(); e.stopPropagation(); active = Math.min(active + 1, matches.length - 1); render(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); e.stopPropagation(); active = Math.max(active - 1, 0); render(); }
    else if (e.key === "Enter") { e.preventDefault(); e.stopPropagation(); choose(active); }
  };

  // Capture phase: the note's editor would otherwise take Return and the arrows first.
  document.addEventListener("keydown", onKey, true);
  input.addEventListener("input", search);
  root.addEventListener("mousedown", (e) => { if (e.target === root) close(true); });

  current = { close };
  search();
  input.focus();
  return current;
}

export function findIsOpen() { return current !== null; }
