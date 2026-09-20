// Loads ONE plugin into the settings page and shows its registered settings tab.
// Same runtime, same bridge, same permission checks as the note editor. SPEC.md §12.3.
import { createRuntime } from "./plugin-runtime.js";

function post(type, payload = {}) {
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.pintack;
  const msg = { type, noteId: null, payload };
  if (handler) handler.postMessage(msg); else console.log("[bridge → swift]", JSON.stringify(msg).slice(0, 200));
}

const runtime = createRuntime({
  post, announceOpen: false,
  getNoteId: () => null, getBody: () => "", insertText: () => {}, requestRefresh: () => {},
});

async function start(plugin) {
  const box = document.getElementById("host");
  try {
    await runtime.loadPlugins([plugin]);
    box.textContent = "";
    const shown = await runtime.displaySettingsTab(plugin.id, box);
    if (!shown) box.textContent = "This plugin has no custom settings page. Its settings are in the Plugins list.";
  } catch (e) {
    box.textContent = "Could not load this plugin's settings: " + ((e && e.message) || e);
  }
}

window.__pintack = {
  receive(msg) {
    const p = msg.payload || {};
    switch (msg.type) {
      case "plugin.settingsHost": start(p.plugin); break;
      case "plugin.result": runtime.onResult(p); break;
      case "plugin.progress": runtime.onProgress(p); break;
      case "plugin.settings": runtime.updateSettings(p.id, p.settings); break;
      default: break;
    }
  },
};

post("ready");
