// Dev-only static server for testing the editor in a normal browser without the
// app. The app serves these files through its own pintack-app: scheme; over HTTP
// the CSP has to name 'self' instead, so this rewrites just that token.
// Usage: node scripts/dev-server.mjs [port]
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "Editor");
const pluginsRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "Plugins");
const mockHost = path.join(path.dirname(fileURLToPath(import.meta.url)), "mock-host.js");
const port = Number(process.argv[2] || 8765);

// Same wrapper the app applies to a plugin's main.js (PluginFiles.wrap in Swift): the plugin gets its
// facade from a one-shot window.__pintackBoot() and nothing else.
const wrap = (code) =>
  "(function(){var PinTack=window.__pintackBoot&&window.__pintackBoot();if(!PinTack){return;}" +
  "var module={exports:{}};var exports=module.exports;try{\n" + code +
  "\n}catch(e){PinTack.__fail(e);return;}PinTack.__done(module.exports);})();";
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png" };

http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/__mock-host.js") { res.writeHead(200, { "Content-Type": "text/javascript" }); res.end(fs.readFileSync(mockHost)); return; }
  const pm = /^\/plugins\/([a-z0-9-]+)\/([\w.-]+)$/.exec(url.pathname);
  if (pm) {
    const f = path.join(pluginsRoot, pm[1], pm[2]);
    if (!fs.existsSync(f)) { res.writeHead(404); res.end("no such plugin file"); return; }
    let body = fs.readFileSync(f, "utf8");
    if (pm[2] === "main.js") body = wrap(body);
    res.writeHead(200, { "Content-Type": pm[2].endsWith(".css") ? "text/css" : "text/javascript", "Cache-Control": "no-store" });
    res.end(body); return;
  }
  const file = path.join(root, url.pathname === "/" ? "index.html" : url.pathname);
  if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end("not found"); return; }
  let body = fs.readFileSync(file);
  if (file.endsWith("index.html")) body = Buffer.from(body.toString().replaceAll("pintack-app:", "'self'").replace('<script type="module"', '<script src="/__mock-host.js"></script><script type="module"'));
  res.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream", "Cache-Control": "no-store" });
  res.end(body);
}).listen(port, () => console.log(`editor dev server on http://localhost:${port}`));
