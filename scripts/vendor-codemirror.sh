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
# EVERY package is pinned, dependencies of dependencies included, so re-running this reproduces the
# vendored files exactly instead of quietly upgrading dozens of them. Only a deliberate edit to this
# list changes what ships. (Until 2026-09-21 only the core was pinned; adding vim would otherwise
# have pulled the newest of every language package with it.)
#
# The language packages are for fenced code blocks and are NOT loaded with the editor: editor.js
# imports each one only when a note actually contains a block in that language. See
# Editor/languages.js.
#
# @codemirror/search and @replit/codemirror-vim (MIT) are for vim mode, owner-approved 2026-09-21.
npm install --no-audit --no-fund --ignore-scripts --save-exact \
  @codemirror/state@6.7.5 @codemirror/view@6.43.12 @codemirror/language@6.12.4 \
  @codemirror/commands@6.11.1 @codemirror/autocomplete@6.20.3 @codemirror/lint@6.9.7 \
  @codemirror/lang-markdown@6.5.2 @lezer/highlight@1.2.3 @lezer/common@1.5.2 @lezer/lr@1.4.10 \
  @lezer/markdown@1.7.2 @marijn/find-cluster-break@1.0.4 crelt@1.0.7 style-mod@4.1.4 \
  w3c-keyname@2.2.8 \
  @codemirror/search@6.7.2 @replit/codemirror-vim@6.4.0 @replit/codemirror-vim-core@0.1.0 >/dev/null

npm install --no-audit --no-fund --ignore-scripts --save-exact \
  @codemirror/lang-angular@0.1.4 @codemirror/lang-cpp@6.0.3 @codemirror/lang-css@6.3.1 \
  @codemirror/lang-go@6.0.1 @codemirror/lang-html@6.4.12 @codemirror/lang-java@6.0.2 \
  @codemirror/lang-javascript@6.2.5 @codemirror/lang-json@6.0.2 @codemirror/lang-less@6.0.2 \
  @codemirror/lang-liquid@6.3.2 @codemirror/lang-php@6.0.2 @codemirror/lang-python@6.2.1 \
  @codemirror/lang-rust@6.0.2 @codemirror/lang-sass@6.0.2 @codemirror/lang-sql@6.10.0 \
  @codemirror/lang-vue@0.1.3 @codemirror/lang-wast@6.0.2 @codemirror/lang-xml@6.1.0 \
  @codemirror/lang-yaml@6.1.3 @codemirror/legacy-modes@6.5.4 \
  @lezer/cpp@1.1.6 @lezer/css@1.3.6 @lezer/go@1.0.1 @lezer/html@1.3.13 @lezer/java@1.1.4 \
  @lezer/javascript@1.5.4 @lezer/json@1.0.3 @lezer/php@1.0.6 @lezer/python@1.1.19 \
  @lezer/rust@1.0.2 @lezer/sass@1.1.0 @lezer/xml@1.0.6 @lezer/yaml@1.0.4 >/dev/null

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
  // "import" for most packages; @replit/codemirror-vim-core declares its ES module as "default".
  const entry = (ex && (ex.import || ex.default)) || pkg.module;
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
