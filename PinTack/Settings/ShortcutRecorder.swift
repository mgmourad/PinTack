import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A button that records the next key combination. SPEC.md §10.2.
///
/// Requires a modifier (a bare letter would make typing impossible for any global
/// binding). Esc cancels, Delete resets to the default. Conflicts are reported
/// at bind time, not silently accepted.
struct ShortcutRecorder: NSViewRepresentable {

    let action: ShortcutAction
    /// Returns an error message to show, or nil when accepted.
    let onRecord: (KeyCombo?) -> String?
    let current: KeyCombo

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.bezelStyle = .rounded
        b.onRecord = onRecord
        return b
    }

    func updateNSView(_ b: RecorderButton, context: Context) {
        b.onRecord = onRecord
        b.combo = current
    }

    final class RecorderButton: NSButton {

        var onRecord: ((KeyCombo?) -> String?)?
        var combo = KeyCombo(keyCode: 0, modifiers: 0) { didSet { refresh() } }
        private var recording = false { didSet { refresh() } }
        private var message: String?

        override init(frame: NSRect) {
            super.init(frame: frame)
            target = self
            action = #selector(begin)
            setButtonType(.momentaryPushIn)
        }
        required init?(coder: NSCoder) { fatalError("not used") }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 118, height: 24) }

        @objc private func begin() {
            recording = true
            message = nil
            window?.makeFirstResponder(self)
        }

        private func refresh() {
            title = recording ? "Press keys…" : (message ?? combo.display)
            contentTintColor = message != nil ? .systemRed : nil
        }

        override func resignFirstResponder() -> Bool { recording = false; return super.resignFirstResponder() }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            switch Int(event.keyCode) {
            case kVK_Escape:
                recording = false
            case kVK_Delete, kVK_ForwardDelete:
                message = onRecord?(nil)
                recording = false
            default:
                let c = KeyCombo(event: event)
                let hasModifier = c.modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
                guard hasModifier else { NSSound.beep(); return }
                message = onRecord?(c)
                recording = false
            }
            refresh()
        }
    }
}
