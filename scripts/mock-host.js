// Dev-only stand-in for the Swift host, so plugins can be exercised in a normal browser.
// It mimics the RESULT SHAPES of PluginBridge.swift; it is not a security model. In particular the
// real approval sheet is native and unanswerable from JavaScript; here window.__mockApprove stands in.
(function () {
  const trusted = new Set();
  const runs = new Map();
  const store = {};
  window.__mock = { trusted, runs, log: [], approve: false, asked: [] };
  const reply = (noteId, callId, ok, value, error) =>
    window.__pintack.receive({ type: "plugin.result", noteId, payload: { callId, ok, value, error } });
  const progress = (noteId, callId, data) => window.__pintack.receive({ type: "plugin.progress", noteId, payload: { callId, data } });

  function handle(msg) {
    const { noteId } = msg, { token, callId, method, args } = msg.payload;
    window.__mock.log.push({ method, args });
    const ok = (v) => setTimeout(() => reply(noteId, callId, true, v), 5);
    const fail = (code, message) => setTimeout(() => reply(noteId, callId, false, null, { code, message }), 5);
    switch (method) {
      case "process.info": return ok({ shell: "/bin/zsh", home: "/Users/test" });
      case "trust.status": return ok({ trusted: trusted.has((args.cwd || "") + "\0" + (args.command || "shortcut:" + args.shortcut)) });
      case "storage.load": return ok(store[token] || null);
      case "storage.save": store[token] = args.data; return ok(true);
      case "settings.set": return ok(true);
      case "url.open": case "path.reveal": return ok(true);
      case "process.stop": { const r = runs.get(args.callId); if (r) r.stop(); return ok(true); }
      case "process.execute": {
        const key = (args.cwd || "") + "\0" + args.command;
        if (!trusted.has(key)) {
          window.__mock.asked.push({ command: args.command, cwd: args.cwd });
          if (!window.__mock.approve) return fail("denied", "The command was not approved.");
          trusted.add(key);
        }
        const started = Date.now();
        let stopped = false, timer = null;
        const finish = (code, extra) => { clearInterval(timer); runs.delete(callId); reply(noteId, callId, true, Object.assign({ exitCode: code, elapsedMs: Date.now() - started, timedOut: false, stopped: false, truncated: false }, extra)); };
        runs.set(callId, { stop() { stopped = true; finish(143, { stopped: true }); } });
        const cmd = args.command;
        if (cmd.startsWith("echo ")) { setTimeout(() => { progress(noteId, callId, { stream: "stdout", text: cmd.slice(5) + "\n" }); finish(0); }, 20); }
        else if (cmd === "fail") { setTimeout(() => { progress(noteId, callId, { stream: "stderr", text: "boom\n" }); finish(1); }, 20); }
        else if (cmd === "slow") { let i = 0; timer = setInterval(() => { if (stopped) return; progress(noteId, callId, { stream: i % 3 === 2 ? "stderr" : "stdout", text: "line " + (++i) + "\n" }); if (i >= 40) finish(0); }, 60); }
        else { setTimeout(() => finish(0), 20); }
        return;
      }
      default: return fail("unknown_method", "Unknown host method " + method);
    }
  }
  window.webkit = { messageHandlers: { pintack: { postMessage(msg) {
    if (msg.type === "plugin.host") handle(msg);
    else (window.__mock.messages = window.__mock.messages || []).push(msg);
  } } } };
})();
