// Dev-only static server for testing the editor in a normal browser without the
// app. The app serves these files through its own pintack-app: scheme; over HTTP
// the CSP has to name 'self' instead, so this rewrites just that token.
// Usage: node scripts/dev-server.mjs [port]
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "Editor");
const port = Number(process.argv[2] || 8765);
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png" };

http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  const file = path.join(root, url.pathname === "/" ? "index.html" : url.pathname);
  if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) { res.writeHead(404); res.end("not found"); return; }
  let body = fs.readFileSync(file);
  if (file.endsWith("index.html")) body = Buffer.from(body.toString().replaceAll("pintack-app:", "'self'"));
  res.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream", "Cache-Control": "no-store" });
  res.end(body);
}).listen(port, () => console.log(`editor dev server on http://localhost:${port}`));
