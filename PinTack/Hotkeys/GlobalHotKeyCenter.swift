import AppKit
import Carbon.HIToolbox

/// Carbon `RegisterEventHotKey` wrapper. SPEC.md §10.1.
///
/// Still the only way to get a true system-wide hotkey on macOS without
/// Accessibility permission, so v1 shows no permission prompt.
///
/// Every status code is logged. The first draft of this file failed silently and
/// the hotkey never fired; there was no way to tell registration from delivery.
final class GlobalHotKeyCenter {

    static let shared = GlobalHotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x50544B59   // 'PTKY'

    private init() {}

    /// Result of the last registration pass, for the self-test and Settings UI.
    private(set) var lastStatus: [ShortcutAction: OSStatus] = [:]
    private var actionForID: [UInt32: ShortcutAction] = [:]

    /// Re-registers every global action from the current bindings.
    func reload() {
        unregisterAll()
        guard installHandlerIfNeeded() else { return }
        for action in ShortcutAction.allCases where action.isGlobal {
            let combo = ShortcutStore.shared.combo(for: action)
            let id = nextID; nextID += 1
            let hotKeyID = EventHotKeyID(signature: signature, id: id)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            lastStatus[action] = status
            if status == noErr, let ref {
                refs[id] = ref
                actionForID[id] = action
                handlers[id] = { ActionRouter.perform(action) }
                NSLog("PinTack: hotkey \(combo.display) registered for \(action.rawValue)")
            } else {
                NSLog("PinTack: hotkey \(combo.display) FAILED for \(action.rawValue), OSStatus \(status)")
            }
        }
    }

    func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll(); handlers.removeAll(); actionForID.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }

    /// Sends a hotkey-pressed event through the same Carbon path a real key press
    /// takes after the OS matches it. Proves the handler is wired; it cannot prove
    /// that the OS delivers physical key presses (registration status covers that).
    @discardableResult
    func simulatePress(of action: ShortcutAction) -> Bool {
        guard let id = actionForID.first(where: { $0.value == action })?.key else { return false }
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr,
              let event else { return false }
        defer { ReleaseEvent(event) }
        var hotKeyID = EventHotKeyID(signature: signature, id: id)
        guard SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                MemoryLayout<EventHotKeyID>.size, &hotKeyID) == noErr else { return false }
        return SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr
    }

    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        // A C function pointer: it cannot capture context, so it reaches the
        // singleton through the static. Keep it capture-free. SPEC.md §13 notes.
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { GlobalHotKeyCenter.shared.fire(id: id) }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        if status != noErr {
            NSLog("PinTack: InstallEventHandler FAILED, OSStatus \(status)")
            handlerRef = nil
            return false
        }
        return true
    }
}
