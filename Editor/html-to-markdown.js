/* Turning pasted rich text into Markdown. SPEC.md §4.
 *
 * Copying out of a browser, Confluence or a mail client puts BOTH text/plain and text/html on the
 * pasteboard. Taking the plain flavour throws away every heading, link and list, which is what
 * PinTack used to do. This reads the HTML flavour instead and writes the Markdown equivalent.
 *
 * The HTML is parsed with DOMParser into a DETACHED document: it is never inserted into the page,
 * so nothing in it runs, and no <script>, <style> or remote resource is ever fetched. Remote
 * <img> tags become ordinary links rather than Markdown images, because the page's CSP forbids
 * loading anything remote and an inline image would only ever render as "image not found".
 *
 * It is deliberately not a complete HTML engine. It covers what people actually paste; anything it
 * does not recognise degrades to its text. Shift-Cmd-V still pastes the plain flavour untouched.
 */

const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "HEAD", "META", "LINK", "TEMPLATE", "SVG", "OBJECT", "IFRAME"]);

/** Escapes the characters that would otherwise start Markdown syntax of their own. */
function escapeText(text) {
  return text.replace(/[\\`*_[\]<>]/g, "\\$&");
}

/** Collapses runs of whitespace the way HTML rendering does. */
function squash(text) {
  return text.replace(/\s+/g, " ");
}

function isBlock(node) {
  if (node.nodeType !== 1) return false;
  return /^(P|DIV|H[1-6]|UL|OL|LI|BLOCKQUOTE|PRE|HR|TABLE|THEAD|TBODY|TR|SECTION|ARTICLE|HEADER|FOOTER|MAIN|ASIDE|FIGURE|FIGCAPTION|DL|DT|DD)$/.test(node.nodeName);
}

/** The text of a node and its children, as inline Markdown. */
function inline(node) {
  let out = "";
  for (const child of node.childNodes) {
    if (child.nodeType === 3) { out += escapeText(squash(child.nodeValue)); continue; }
    if (child.nodeType !== 1 || SKIP.has(child.nodeName)) continue;

    const name = child.nodeName;
    if (name === "BR") { out += "  \n"; continue; }
    if (isBlock(child)) { out += inline(child); continue; }   // a stray block inside a line

    const inner = inline(child);
    if (name === "STRONG" || name === "B") out += inner.trim() ? `**${inner.trim()}**` : "";
    else if (name === "EM" || name === "I") out += inner.trim() ? `*${inner.trim()}*` : "";
    else if (name === "DEL" || name === "S" || name === "STRIKE") out += inner.trim() ? `~~${inner.trim()}~~` : "";
    else if (name === "MARK") out += inner.trim() ? `==${inner.trim()}==` : "";
    else if (name === "CODE" || name === "KBD" || name === "SAMP") {
      // Inside a <pre> the fence handles it; on its own it is an inline code span.
      const raw = child.textContent.replace(/\s+/g, " ").trim();
      out += raw ? "`" + raw.replace(/`/g, "ˋ") + "`" : "";
    } else if (name === "A") {
      const href = (child.getAttribute("href") || "").trim();
      const text = inner.trim() || href;
      out += href && /^(https?:|mailto:)/i.test(href) ? `[${text}](${href})` : text;
    } else if (name === "IMG") {
      const alt = (child.getAttribute("alt") || "").trim();
      const src = (child.getAttribute("src") || "").trim();
      // Never a Markdown image: the CSP refuses remote sources, so it could only render broken.
      if (/^https?:/i.test(src)) out += `[${alt || "image"}](${src})`;
      else if (alt) out += escapeText(alt);
    } else {
      out += inner;
    }
  }
  return out;
}

function listItems(list, ordered, depth) {
  const pad = "  ".repeat(depth);
  let index = Number(list.getAttribute("start") || 1);
  const lines = [];
  for (const item of list.children) {
    if (item.nodeName !== "LI") continue;
    const marker = ordered ? `${index++}. ` : "- ";

    // A checkbox pasted from a task list becomes a real Markdown task.
    const box = item.querySelector(":scope > input[type=checkbox]");
    const task = box ? (box.checked ? "[x] " : "[ ] ") : "";

    // The item's own text, without the nested lists hanging off it.
    const clone = item.cloneNode(true);
    for (const nested of clone.querySelectorAll(":scope > ul, :scope > ol")) nested.remove();
    for (const check of clone.querySelectorAll(":scope > input")) check.remove();
    const text = inline(clone).trim();
    lines.push(pad + marker + task + (text || ""));

    for (const nested of item.children) {
      if (nested.nodeName === "UL" || nested.nodeName === "OL") {
        lines.push(listItems(nested, nested.nodeName === "OL", depth + 1));
      }
    }
  }
  return lines.filter(Boolean).join("\n");
}

function table(node) {
  const rows = [...node.querySelectorAll("tr")].map((tr) =>
    [...tr.children].filter((c) => c.nodeName === "TD" || c.nodeName === "TH")
      .map((cell) => inline(cell).replace(/\n/g, " ").replace(/\|/g, "\\|").trim()));
  if (!rows.length || !rows[0].length) return "";
  const width = Math.max(...rows.map((r) => r.length));
  const pad = (r) => { const c = [...r]; while (c.length < width) c.push(""); return c; };
  const head = pad(rows[0]);
  const body = rows.slice(1).map(pad);
  return [`| ${head.join(" | ")} |`,
          `| ${head.map(() => "---").join(" | ")} |`,
          ...body.map((r) => `| ${r.join(" | ")} |`)].join("\n");
}

function fencedCode(node) {
  const text = node.textContent.replace(/\n+$/, "");
  const classes = (node.getAttribute("class") || "") + " " + ((node.firstElementChild && node.firstElementChild.getAttribute("class")) || "");
  const match = /(?:language|lang|highlight)[-_]([a-z0-9+#]+)/i.exec(classes);
  const fence = text.includes("```") ? "~~~" : "```";
  return `${fence}${match ? match[1].toLowerCase() : ""}\n${text}\n${fence}`;
}

/** Walks the block structure, returning Markdown blocks separated by blank lines. */
function blocks(node) {
  const out = [];
  const flushInline = (buffer) => { const t = buffer.trim(); if (t) out.push(t); };

  let buffer = "";
  for (const child of node.childNodes) {
    if (child.nodeType === 3) { buffer += escapeText(squash(child.nodeValue)); continue; }
    if (child.nodeType !== 1 || SKIP.has(child.nodeName)) continue;

    const name = child.nodeName;
    if (!isBlock(child)) { buffer += inline(child); continue; }
    flushInline(buffer); buffer = "";

    const heading = /^H([1-6])$/.exec(name);
    if (heading) {
      const text = inline(child).trim();
      if (text) out.push("#".repeat(Number(heading[1])) + " " + text);
    } else if (name === "UL" || name === "OL") {
      const list = listItems(child, name === "OL", 0);
      if (list) out.push(list);
    } else if (name === "PRE") {
      out.push(fencedCode(child));
    } else if (name === "BLOCKQUOTE") {
      const quoted = blocks(child).split("\n").map((l) => "> " + l).join("\n");
      if (quoted.trim() !== ">") out.push(quoted);
    } else if (name === "HR") {
      out.push("---");
    } else if (name === "TABLE") {
      const md = table(child);
      if (md) out.push(md);
    } else if (name === "P" || name === "H" || name === "FIGCAPTION" || name === "DT" || name === "DD") {
      const text = inline(child).trim();
      if (text) out.push(text);
    } else {
      // A structural wrapper (div, section, article…): keep walking.
      const inner = blocks(child);
      if (inner) out.push(inner);
    }
  }
  flushInline(buffer);
  return out.join("\n\n");
}

/** Markdown for a pasted HTML fragment, or "" when there is nothing usable in it. */
export function htmlToMarkdown(html) {
  if (!html || !html.trim()) return "";
  let doc;
  try { doc = new DOMParser().parseFromString(html, "text/html"); } catch (_) { return ""; }
  if (!doc || !doc.body) return "";
  for (const junk of doc.body.querySelectorAll([...SKIP].join(","))) junk.remove();
  return blocks(doc.body)
    .replace(/[ \t]+$/gm, "")          // trailing spaces, except the two that mean a line break
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
