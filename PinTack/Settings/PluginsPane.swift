import SwiftUI
import AppKit

/// Settings → Plugins. SPEC.md §9. Installed plugins, an enable switch that shows what a plugin may do
/// before it can do it, each plugin's settings, and the list of commands you have approved.
struct PluginsSettingsPane: View {

    @ObservedObject private var manager = PluginManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var trustRevision = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Plugins add features such as Runner's inline command buttons. They are switched off until you enable them, and each one can only do what it lists under Permissions.")
                    .font(.callout).foregroundStyle(.secondary)

                if manager.installed.isEmpty {
                    Text("No plugins are installed. Drop a plugin's folder into the plugins folder, then choose Rescan.")
                        .foregroundStyle(.secondary).padding(.vertical, 24).frame(maxWidth: .infinity)
                }

                ForEach(manager.installed) { plugin in
                    PluginCard(plugin: plugin, trustRevision: $trustRevision)
                }

                HStack {
                    Button("Open plugins folder") {
                        try? FileManager.default.createDirectory(at: manager.vault.pluginsURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(manager.vault.pluginsURL)
                    }
                    .tip("Open plugins folder", "Show the folder plugins are installed in")
                    Button("Rescan") { manager.reload(); WindowManager.shared.reloadEditors() }
                        .tip("Rescan", "Look for plugins added to or removed from the plugins folder")
                    Spacer()
                }
                Text("To install a plugin, put its folder in the plugins folder and choose Rescan (or restart PinTack). Only install plugins you trust: they run inside your notes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 26).padding(.vertical, 14)
        }
    }
}

private struct PluginCard: View {

    let plugin: InstalledPlugin
    @Binding var trustRevision: Int
    @ObservedObject private var manager = PluginManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var settingsTick = 0

    private var canRunCommands: Bool { plugin.permissions.contains(.processExecute) || plugin.permissions.contains(.shortcutsRun) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(plugin.name).font(.system(size: 14, weight: .semibold))
                    if let m = plugin.manifest {
                        Text("Version \(m.version)" + (m.author.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { plugin.enabled }, set: { setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!plugin.isValid)
    .tip(plugin.enabled ? "Disable" : "Enable", "Turn this plugin on or off in every note")
            }

            if let error = plugin.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            if let d = plugin.manifest?.description { Text(d).font(.callout) }

            if !plugin.permissions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permissions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(plugin.permissions, id: \.self) { p in
                        Label(p.summary, systemImage: "checkmark.shield").font(.caption)
                    }
                }
            }

            if plugin.enabled, let specs = plugin.manifest?.settings, !specs.isEmpty {
                Divider()
                ForEach(specs, id: \.key) { spec in settingRow(spec).tip(spec.label, "A setting this plugin provides") }
                    .id(settingsTick)
            }

            if plugin.enabled {
                Button("Plugin settings…") { PluginSettingsWindows.shared.show(pluginID: plugin.id, title: plugin.name) }
                    .buttonStyle(.link).font(.caption)
                    .tip("Plugin settings", "Open this plugin's own settings")
            }

            if plugin.enabled && canRunCommands { approvals }
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.chromeSurface))
    }

    // MARK: Enable / disable

    private func setEnabled(_ on: Bool) {
        if on {
            let list = plugin.permissions.map { "• " + $0.summary }.joined(separator: "\n")
            let message = (list.isEmpty ? "This plugin asks for no special permissions." : "This plugin will be able to:\n\n\(list)")
                + "\n\nOnly enable plugins you trust."
            guard Prompt.confirm(title: "Enable “\(plugin.name)”?", message: message, button: "Enable") else { return }
        } else {
            PluginBridge.shared.cancelRuns(pluginID: plugin.id)          // switching a plugin off stops what it started
        }
        manager.setEnabled(plugin.id, on)
        WindowManager.shared.reloadEditors()
    }

    // MARK: Manifest-driven settings

    @ViewBuilder private func settingRow(_ spec: PluginSettingSpec) -> some View {
        let values = manager.settingsValues(for: plugin)
        switch spec.type {
        case "boolean":
            Toggle(spec.label, isOn: Binding(get: { values[spec.key] as? Bool ?? false }, set: { save(spec.key, $0) }))
        case "number":
            LabeledContent(spec.label) {
                TextField("", value: Binding(get: { values[spec.key] as? Double ?? 0 }, set: { save(spec.key, $0) }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 90).multilineTextAlignment(.trailing)
            }
        default:
            LabeledContent(spec.label) {
                TextField("", text: Binding(get: { values[spec.key] as? String ?? "" }, set: { save(spec.key, $0) }))
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
        }
    }

    private func save(_ key: String, _ value: Any) {
        settings.setPluginSetting(plugin.id, key: key, value: value)
        NotificationCenter.default.post(name: .pluginSettingsDidChange, object: nil, userInfo: ["id": plugin.id])
        settingsTick += 1
    }

    // MARK: Approved commands (SPEC.md §9, §13.4)

    @ViewBuilder private var approvals: some View {
        let entries = TrustStore.shared.all
        Divider()
        HStack {
            Text("Approved commands (\(entries.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if !entries.isEmpty {
                Button("Revoke all") { TrustStore.shared.revokeAll(); trustRevision += 1 }.buttonStyle(.link).font(.caption)
                    .tip("Revoke all", "Forget every approval; each command asks again")
            }
        }
        if entries.isEmpty {
            Text("Nothing is approved yet. Each new command asks first, showing exactly what it will run.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(entries, id: \.hash) { e in
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.value).font(.system(size: 11.5, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                    Text((e.kind == "shortcut" ? "Shortcut" : e.cwd) + " · approved " + e.approvedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revoke") { TrustStore.shared.revoke(hash: e.hash); trustRevision += 1 }.buttonStyle(.link).font(.caption)
                    .tip("Revoke", "Forget this approval; the command asks again next time")
            }
        }
        .id(trustRevision)
    }
}
