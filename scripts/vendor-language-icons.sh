#!/usr/bin/env bash
# Vendors the language logos shown on fenced code blocks into Editor/icons.
#
# Source: Devicon (https://devicon.dev), MIT, which is compatible with this project's GPL-3.0.
# Only the icons actually referenced by Editor/languages.js are copied, a few KB each, so the app
# stays self-contained and never loads anything from the network. The logos themselves remain the
# trademarks of their owners; labelling a code block with one is ordinary nominative use.
#
# Usage: scripts/vendor-language-icons.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
VERSION=2.16.0

cd "$WORK"
npm init -y >/dev/null
npm install --no-audit --no-fund --ignore-scripts --save-exact "devicon@$VERSION" >/dev/null

node - "$ROOT" "$VERSION" <<'EOF'
const fs = require("fs"), path = require("path");
const [root, version] = process.argv.slice(2);
const src = path.join("node_modules", "devicon", "icons");
const out = path.join(root, "Editor", "icons");
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });

// Our name (matching Editor/languages.js) -> Devicon folder.
const WANTED = {
  powershell: "powershell", shell: "bash", python: "python", javascript: "javascript",
  typescript: "typescript", react: "react", json: "json", yaml: "yaml", swift: "swift",
  go: "go", rust: "rust", java: "java", c: "c", cpp: "cplusplus", csharp: "csharp",
  php: "php", ruby: "ruby", html: "html5", css: "css3", sass: "sass", less: "less",
  xml: "xml", markdown: "markdown", docker: "docker", nginx: "nginx", cmake: "cmake",
  perl: "perl", lua: "lua", r: "r", julia: "julia", matlab: "matlab", haskell: "haskell",
  clojure: "clojure", elixir: "elixir", elm: "elm", dart: "dart", groovy: "groovy",
  fortran: "fortran", kotlin: "kotlin", scala: "scala", objectivec: "objectivec",
  graphql: "graphql", vue: "vuejs", angular: "angular", solidity: "solidity",
  crystal: "crystal", erlang: "erlang", coffeescript: "coffeescript", haxe: "haxe",
  latex: "latex", vb: "visualbasic",
};

// A square mark, never a wordmark: the badge has room for a glyph, not a logotype.
const PREFER = ["-original.svg", "-plain.svg", "-line.svg"];
const MAX_BYTES = 24 * 1024;      // anything larger is a traced bitmap, not a logo

const copied = [];
const skipped = [];
for (const [name, folder] of Object.entries(WANTED)) {
  const dir = path.join(src, folder);
  if (!fs.existsSync(dir)) { skipped.push(`${name}: no such devicon folder "${folder}"`); continue; }
  let chosen = null;
  for (const suffix of PREFER) {
    const file = path.join(dir, folder + suffix);
    if (!fs.existsSync(file)) continue;
    if (fs.statSync(file).size > MAX_BYTES) continue;
    chosen = file;
    break;
  }
  if (!chosen) { skipped.push(`${name}: no small square variant in "${folder}"`); continue; }
  fs.copyFileSync(chosen, path.join(out, name + ".svg"));
  copied.push(`${name} (${path.basename(chosen)}, ${fs.statSync(chosen).size}B)`);
}

const licence = fs.readdirSync(path.join("node_modules", "devicon"))
  .find(f => /^licen[cs]e/i.test(f));
fs.writeFileSync(path.join(out, "LICENSE.md"),
  `# Language icons\n\nFrom Devicon ${version} (https://devicon.dev), vendored by ` +
  `scripts/vendor-language-icons.sh.\n\nEach logo remains the trademark of its owner; they are used ` +
  `only to label a code block with the language it is written in.\n\n## Devicon licence\n\n` +
  (licence ? fs.readFileSync(path.join("node_modules", "devicon", licence), "utf8").trim() : "(MIT)") + "\n");

console.log(`copied ${copied.length} icons into Editor/icons`);
if (skipped.length) console.log("skipped:\n  " + skipped.join("\n  "));
EOF
