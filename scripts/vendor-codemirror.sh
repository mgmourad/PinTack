#!/usr/bin/env bash
# Vendors CodeMirror 6 (pre-approved in CLAUDE.md) into Editor/vendor and
# regenerates Editor/index.html from Editor/index.template.html.
#
# Why no bundler: every CM6 package ships as a single ES module, so a browser
# import map resolves the bare specifiers ("@codemirror/state" etc.) directly.
# That keeps esbuild/rollup out of the project, which CLAUDE.md forbids adding
# without approval. This script is dev-time only; the app never touches npm and
# never uses the network. SPEC.md §2.1, §4.4.
#
# Usage: scripts/vendor-codemirror.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$WORK"
npm init -y >/dev/null
npm install --no-audit --no-fund --ignore-scripts --save-exact \
  @codemirror/state@6.7.5 @codemirror/view@6.43.12 @codemirror/language@6.12.4 \
  @codemirror/commands@6.11.1 @codemirror/autocomplete@6.20.3 \
  @codemirror/lang-markdown@6.5.2 @lezer/highlight@1.2.3 >/dev/null

# Every language CodeMirror ships, for fenced code blocks. These are NOT loaded with the editor:
# editor.js imports each one only when a note actually contains a block in that language, so a
# note with no code still parses one markdown module. See LANGUAGES in Editor/editor.js.
npm install --no-audit --no-fund --ignore-scripts --save-exact \
  @codemirror/lang-angular @codemirror/lang-cpp @codemirror/lang-css @codemirror/lang-go \
  @codemirror/lang-html @codemirror/lang-java @codemirror/lang-javascript @codemirror/lang-json \
  @codemirror/lang-less @codemirror/lang-liquid @codemirror/lang-php @codemirror/lang-python \
  @codemirror/lang-rust @codemirror/lang-sass @codemirror/lang-sql @codemirror/lang-vue \
  @codemirror/lang-wast @codemirror/lang-xml @codemirror/lang-yaml \
  @codemirror/legacy-modes >/dev/null

node - "$ROOT" <<'EOF'
const fs = require("fs"), path = require("path"), crypto = require("crypto");
const root = process.argv[2];
const vendor = path.join(root, "Editor", "vendor");
fs.rmSync(vendor, { recursive: true, force: true });
fs.mkdirSync(vendor, { recursive: true });

function packages(dir, out = []) {
  for (const n of fs.readdirSync(dir)) {
    const p = path.join(dir, n);
    if (n.startsWith("@")) { packages(p, out); continue; }
    if (fs.existsSync(path.join(p, "package.json"))) out.push(p);
  }
  return out;
}

const imports = {};
const licenses = [];
for (const dir of packages("node_modules")) {
  const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json")));

  // @codemirror/legacy-modes has no single entry: it publishes one module per mode
  // ("@codemirror/legacy-modes/mode/powershell"). Vendor the whole mode folder and map each one.
  if (pkg.name === "@codemirror/legacy-modes") {
    const outDir = path.join(vendor, "legacy-modes");
    fs.mkdirSync(outDir, { recursive: true });
    for (const f of fs.readdirSync(path.join(dir, "mode")).filter(f => f.endsWith(".js"))) {
      fs.copyFileSync(path.join(dir, "mode", f), path.join(outDir, f));
      imports[`${pkg.name}/mode/${f.replace(/\.js$/, "")}`] = "./vendor/legacy-modes/" + f;
    }
    const legacyLic = fs.readdirSync(dir).find(f => /^licen[cs]e/i.test(f));
    licenses.push(`## ${pkg.name} ${pkg.version} (${pkg.license})\n\n` +
      (legacyLic ? fs.readFileSync(path.join(dir, legacyLic), "utf8").trim() : "(no license file shipped)") + "\n");
    continue;
  }

  const ex = pkg.exports && (pkg.exports["."] || pkg.exports);
  const entry = (ex && ex.import) || pkg.module;
  if (!entry) throw new Error(pkg.name + " has no ESM entry");
  const flat = pkg.name.replace(/^@/, "").replace("/", "-") + ".js";
  fs.copyFileSync(path.join(dir, entry), path.join(vendor, flat));
  imports[pkg.name] = "./vendor/" + flat;

  const lic = fs.readdirSync(dir).find(f => /^licen[cs]e/i.test(f));
  licenses.push(`## ${pkg.name} ${pkg.version} (${pkg.license})\n\n` +
    (lic ? fs.readFileSync(path.join(dir, lic), "utf8").trim() : "(no license file shipped)") + "\n");
}
fs.writeFileSync(path.join(vendor, "LICENSES.md"),
  "# Third-party licenses\n\nVendored by scripts/vendor-codemirror.sh. All MIT.\n\n" + licenses.join("\n"));

const importmap = JSON.stringify({ imports }, null, 2);
// CSP allows this one inline script by hash instead of enabling 'unsafe-inline'.
const hash = "sha256-" + crypto.createHash("sha256").update(importmap).digest("base64");

const tpl = fs.readFileSync(path.join(root, "Editor", "index.template.html"), "utf8");
fs.writeFileSync(path.join(root, "Editor", "index.html"),
  tpl.replace("%%IMPORTMAP%%", importmap).replace("%%IMPORTMAP_HASH%%", hash));
console.log("vendored " + Object.keys(imports).length + " packages, importmap " + hash);
EOF
