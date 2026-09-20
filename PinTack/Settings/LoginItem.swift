import ServiceManagement

/// "Open PinTack at login", through Apple's SMAppService (macOS 13+, so fine for the macOS 14
/// target). The entry then shows up in System Settings → Login Items, where the user can also
/// remove it, so it never becomes a hidden persistence mechanism.
enum LoginItem {

    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    /// True when macOS wants the user to approve the item in System Settings first.
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on {
            if status != .enabled { try SMAppService.mainApp.register() }
        } else if status == .enabled || status == .requiresApproval {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
