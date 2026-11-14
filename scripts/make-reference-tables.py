#!/usr/bin/env python3
"""Regenerates README.md's shortcut and slash-command tables from the source they document.

    python3 scripts/make-reference-tables.py

Both lists are long and both change often, so a hand-written copy goes stale silently — a README
that lists a key the app no longer has is worse than one that lists none. The tables live between
HTML comment markers in README.md and are rewritten in place; run this after adding a shortcut or a
slash command, and the build is unaffected either way.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
KEY_NAMES = {"Comma": ",", "Period": ".", "Slash": "/", "Equal": "=", "Minus": "-"}


def shortcuts():
    src = (ROOT / "PinTack/Hotkeys/Shortcuts.swift").read_text()

    def section(name):
        body = src.split(f"var {name}: String {{", 1)[1]
        return dict(re.findall(r'case \.(\w+): return "([^"]*)"', body.split("\n    }", 1)[0]))

    titles, groups = section("title"), section("group")
    # `group` lists several cases per line, so fill in the ones the simple pattern missed.
    gbody = src.split("var group: String {", 1)[1].split("\n    }", 1)[0]
    for cases, name in re.findall(r"case ((?:\.\w+,?\s*)+): return \"([^\"]+)\"", gbody):
        for c in re.findall(r"\.(\w+)", cases):
            groups[c] = name

    gl = src.split("var isGlobal: Bool {", 1)[1].split("\n    }", 1)[0]
    global_actions = set(re.findall(r"\.(\w+)", gl.split("return true", 1)[0]))

    combos = {}
    # Stop at the end of the switch: a later property returning `true` for the same case
    # otherwise overwrote the entry, and ⌥Tab came out as "?".
    cbody = src.split("var defaultCombo: KeyCombo {", 1)[1].split("\n    }", 1)[0]
    for action, expr in re.findall(r"case \.(\w+): return (.+)", cbody):
        if expr.startswith(".alt("):
            key = expr[len(".alt(kVK_ANSI_"):].rstrip(")")
            combos[action] = "⌥⌘" + KEY_NAMES.get(key, key)
        elif expr.startswith(".optShift("):
            key = expr[len(".optShift(kVK_ANSI_"):].rstrip(")")
            combos[action] = "⌥⇧" + KEY_NAMES.get(key, key)
        else:
            mods = ""
            if "controlKey" in expr: mods += "⌃"
            if "optionKey" in expr: mods += "⌥"
            if "shiftKey" in expr: mods += "⇧"
            if "cmdKey" in expr: mods += "⌘"
            m = re.search(r"kVK_(?:ANSI_)?(\w+)", expr)
            key = m.group(1) if m else "?"
            combos[action] = mods + KEY_NAMES.get(key, key)

    order, seen = [], set()
    for a in re.findall(r"\.(\w+)", src.split("var title: String {", 1)[1].split("\n    }", 1)[0]):
        if a not in seen:
            seen.add(a); order.append(a)

    out = []
    for group in ["Notes", "Appearance", "Stacks", "Windows", "Data"]:
        rows = [a for a in order if groups.get(a) == group]
        if not rows:
            continue
        out += [f"#### {group}", "", "| Shortcut | Action | Scope |", "|---|---|---|"]
        for a in rows:
            scope = "Global" if a in global_actions else "In PinTack"
            out.append(f"| `{combos.get(a, '—')}` | {titles[a]} | {scope} |")
        out.append("")
    return "\n".join(out)


def slash():
    src = (ROOT / "Editor/editor.js").read_text()
    table = src.split("const commands = [", 1)[1].split("\n];", 1)[0]
    pairs = re.findall(r'^\s*\["([^"]+)", "([^"]+)"', table, re.M)
    colours = re.search(r"const COLORS = \[(.*?)\];", src, re.S).group(1)
    colour_names = re.findall(r'\["(\w+)"', colours)
    langs = re.findall(r'"([a-z]+)"', re.search(r"const LANGS = \[(.*?)\];", src, re.S).group(1))

    native = {"freeze", "find", "stack", "addToStack", "removeFromStack",
              "settings", "allnotes", "destroy", "template", "image", "emoji"}
    text_rows = [(i, d) for i, d in pairs if i not in native]
    native_rows = [(i, d) for i, d in pairs if i in native]

    def table_of(rows):
        return "\n".join(["| Command | What it does |", "|---|---|"]
                         + [f"| `/{i}` | {d} |" for i, d in rows])

    return "\n".join([
        "#### Text and formatting", "", table_of(text_rows), "",
        "#### The note, and the app", "", table_of(native_rows), "",
        "#### Colours and code blocks", "",
        "| Command | What it does |", "|---|---|",
        "| " + ", ".join(f"`/{c}`" for c in colour_names) + " | Coloured text. "
        "The `<span>` tags stay hidden in the editor; <kbd>Tab</kbd> leaves the span. |",
        "| " + ", ".join(f"`/code-{l}`" for l in langs[:6]) + ", … | A fenced code block in that "
        f"language — {len(langs)} of them, each with its logo on the panel. |", "",
    ])


def replace(text, name, body):
    start, end = f"<!-- {name}:start -->", f"<!-- {name}:end -->"
    if start not in text:
        sys.exit(f"README.md has no {start} marker")
    head, rest = text.split(start, 1)
    _, tail = rest.split(end, 1)
    return f"{head}{start}\n{body}\n{end}{tail}"


readme = ROOT / "README.md"
text = readme.read_text()
text = replace(text, "shortcuts", shortcuts())
text = replace(text, "slash", slash())
readme.write_text(text)
print("README.md: shortcut and slash-command tables regenerated")
