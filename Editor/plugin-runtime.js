// PinTack plugin runtime: the public plugin API. SPEC.md §12.
//
// Plugins are plain JavaScript loaded into the note's web view. They get NO filesystem access
// and NO network access (the page's CSP forbids both, and there is no eval). Everything
// privileged goes through `app.host.invoke(...)`, which Swift verifies against the permissions the
// plugin declared and the user accepted.
//
// Honest limits of the isolation: plugins share one JavaScript realm, so a hostile plugin could in
// principle tamper with another's objects. The boundary that actually protects the user is on the
// Swift side: declared permissions, and a native approval sheet (which a plugin cannot answer)
// for anything that runs a command. See SPEC.md §13.4.

export function createRuntime(env) {
  // env: { post(type, payload), getNoteId(), getBody(), insertText(text), requestRefresh() }
  const plugins = new Map();            // id → state
  const codeBlockProcessors = new Map();// lang → { pluginId, fn }
  const postProcessors = [];
  const slashCommands = [];
  const commands = new Map();           // "pluginId:commandId" → { pluginId, spec }
  const events = new Map();             // event name → [{ pluginId, fn }]
  const settingsTabs = new Map();       // pluginId → tab
  const pending = new Map();            // callId → { resolve, reject, onProgress }
  let callSeq = 0;

  const log = (...a) => console.log("[plugin]", ...a);
  const errorOf = (e) => (e && e.message) || String(e);

  // ------------------------------------------------------------------ host bridge

  function invoke(state, method, args = {}, opts = {}) {
    const callId = `${state.id}#${++callSeq}`;
    const promise = new Promise((resolve, reject) => pending.set(callId, { resolve, reject, onProgress: opts.onProgress }));
    // The token was handed to this plugin's own closure by the loader. Swift maps it back to the
    // plugin id; a plugin cannot claim another plugin's identity just by writing a different id.
    env.post("plugin.host", { token: state.token, callId, method, args });
    promise.callId = callId;
    return promise;
  }

  function onResult(p) {
    const call = pending.get(p.callId);
    if (!call) return;
    pending.delete(p.callId);
    if (p.ok) call.resolve(p.value);
    else { const err = new Error(p.error && p.error.message || "host call failed"); err.code = p.error && p.error.code; call.reject(err); }
  }

  function onProgress(p) {
    const call = pending.get(p.callId);
    if (call && call.onProgress) { try { call.onProgress(p.data); } catch (e) { log("progress handler failed", errorOf(e)); } }
  }

  // ------------------------------------------------------------------ the Plugin base class

  function makePluginClass(state) {
    return class Plugin {
      constructor(app, manifest) { this.app = app; this.manifest = manifest; }

      get settings() { return state.settings; }
      async setSetting(key, value) {
        await invoke(state, "settings.set", { key, value });
        state.settings = { ...state.settings, [key]: value };
      }

      async onload() {}
      async onunload() {}

      registerMarkdownCodeBlockProcessor(lang, fn) {
        if (codeBlockProcessors.has(lang)) { log(`${state.id}: "${lang}" blocks are already handled by ${codeBlockProcessors.get(lang).pluginId}`); return; }
        codeBlockProcessors.set(lang, { pluginId: state.id, fn });
      }
      registerMarkdownPostProcessor(fn) { postProcessors.push({ pluginId: state.id, fn }); }
      registerSlashCommand(spec) { slashCommands.push({ pluginId: state.id, ...spec }); }
      registerCommand(spec) { commands.set(`${state.id}:${spec.id}`, { pluginId: state.id, spec }); }
      registerSettingsTab(tab) { settingsTabs.set(state.id, tab); }
      registerEvent(name, fn) {
        if (!events.has(name)) events.set(name, []);
        events.get(name).push({ pluginId: state.id, fn });
      }

      async loadData() { return invoke(state, "storage.load"); }
      async saveData(data) { return invoke(state, "storage.save", { data }); }
    };
  }

  function makeApp(state) {
    return {
      vault: {
        read: (noteId) => invoke(state, "vault.read", { noteId }),
        modify: (noteId, content) => invoke(state, "vault.modify", { noteId, content }),
        create: (path, content) => invoke(state, "vault.create", { path, content }),
        getNotes: (filter = {}) => invoke(state, "vault.getNotes", filter),
        getAttachmentPath: (filename) => invoke(state, "vault.getAttachmentPath", { filename }),
      },
      host: { invoke: (method, args, opts) => invoke(state, method, args, opts) },
      workspace: {
        getActiveNote: () => ({ noteId: env.getNoteId(), getValue: () => env.getBody() }),
      },
      editor: { getValue: () => env.getBody(), insertText: (t) => env.insertText(t) },
    };
  }

  // ------------------------------------------------------------------ loading

  function loadOne(p) {
    return new Promise((resolve) => {
      const state = { id: p.id, token: p.token, manifest: p.manifest, settings: p.settings || {}, instance: null, ready: Promise.resolve() };
      plugins.set(p.id, state);

      if (p.styles) {
        const link = document.createElement("link");
        link.rel = "stylesheet";
        link.href = `plugins/${p.id}/${p.styles}`;
        document.head.appendChild(link);
      }

      // Swift wraps main.js so that it calls window.__pintackBoot() exactly once, synchronously.
      // The function removes itself on first call, so no other script can obtain this plugin's
      // facade (and token) afterwards.
      window.__pintackBoot = () => {
        delete window.__pintackBoot;
        return {
          Plugin: makePluginClass(state),
          __fail: (e) => log(`${p.id}: failed while loading:`, errorOf(e)),
          __done: (exported) => {
            const Cls = exported && (exported.default || exported);
            if (typeof Cls !== "function") { log(`${p.id}: main.js did not export a class`); return; }
            try {
              state.instance = new Cls(makeApp(state), p.manifest);
              state.ready = Promise.resolve(state.instance.onload()).catch((e) => log(`${p.id}: onload failed:`, errorOf(e)));
            } catch (e) { log(`${p.id}: could not start:`, errorOf(e)); }
          },
        };
      };
      const script = document.createElement("script");
      script.src = `plugins/${p.id}/${p.main}`;
      const finish = () => { delete window.__pintackBoot; state.ready.then(resolve); };
      script.onload = finish;
      script.onerror = () => { log(`${p.id}: could not load ${p.main}`); finish(); };
      document.head.appendChild(script);
    });
  }

  async function loadPlugins(list) {
    for (const p of list) await loadOne(p);         // sequential: each script needs its own __pintackBoot
    env.post("plugin.commands", {
      commands: [...commands.entries()].map(([key, c]) => ({
        key, pluginId: c.pluginId, id: c.spec.id, name: c.spec.name || c.spec.id, defaultHotkey: c.spec.defaultHotkey || null,
      })),
    });
    env.requestRefresh();
    if (env.announceOpen !== false) emit("note:open", { noteId: env.getNoteId() });
  }

  // ------------------------------------------------------------------ rendering hooks

  const hasCodeBlockProcessor = (lang) => codeBlockProcessors.has(lang);

  function renderCodeBlock(lang, source, el, ctx) {
    const handler = codeBlockProcessors.get(lang);
    if (!handler) return false;
    try {
      const r = handler.fn(source, el, ctx);
      if (r && typeof r.catch === "function") r.catch((e) => showError(el, e));
    } catch (e) { showError(el, e); }
    runPostProcessors(el, ctx);
    return true;
  }

  // Post-processors only see rendered WIDGETS (tables, images, plugin blocks). The text lines belong
  // to the editor; changing their DOM would look like user edits to CodeMirror.
  function runPostProcessors(el, ctx) {
    for (const p of postProcessors) { try { p.fn(el, ctx); } catch (e) { log(`${p.pluginId}: post-processor failed:`, errorOf(e)); } }
  }

  function showError(el, e) {
    el.textContent = "";
    const box = document.createElement("div");
    box.className = "plugin-error";
    box.textContent = `Plugin error: ${errorOf(e)}`;
    el.appendChild(box);
  }

  // ------------------------------------------------------------------ slash commands, commands, events

  function slashOptions(apply) {
    return slashCommands.map((c, i) => ({
      label: "/" + c.id, detail: c.name || c.id, type: "keyword", boost: 40 - i,
      apply: (view, _completion, from, to) => apply(c, view, from, to),
    }));
  }

  function runCommand(key) {
    const c = commands.get(key);
    if (!c) return;
    try {
      const r = c.spec.callback && c.spec.callback();
      if (r && typeof r.catch === "function") r.catch((e) => log(`${key} failed:`, errorOf(e)));
    } catch (e) { log(`${key} failed:`, errorOf(e)); }
  }

  function emit(name, payload) {
    for (const h of events.get(name) || []) {
      try { const r = h.fn(payload); if (r && r.catch) r.catch((e) => log(`${h.pluginId} ${name} handler failed:`, errorOf(e))); }
      catch (e) { log(`${h.pluginId} ${name} handler failed:`, errorOf(e)); }
    }
  }

  function updateSettings(id, settings) { const s = plugins.get(id); if (s) s.settings = settings; }

  async function displaySettingsTab(id, container) {
    const tab = settingsTabs.get(id);
    if (!tab) return false;
    await tab.display(container);
    return true;
  }

  return {
    loadPlugins, hasCodeBlockProcessor, renderCodeBlock, runPostProcessors,
    slashOptions, runCommand, emit, onResult, onProgress, updateSettings, displaySettingsTab,
    get loaded() { return [...plugins.keys()]; },
  };
}
