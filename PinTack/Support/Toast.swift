import AppKit

/// A brief message at the bottom of the screen. Feedback for actions that have no other visible
/// result (pinned, hidden, arranged...). From the prototype.
///
/// Click-through, EXCEPT when it offers an action such as Undo: then it takes the click on its
/// button and stays up long enough to reach it.
enum Toast {

    private static var panel: NSPanel?
    private static var hideTask: DispatchWorkItem?
    private static var action: (() -> Void)?

    /// A button that works on the FIRST click. The toast is a non-activating panel that never
    /// becomes key, and an ordinary button in one spends its first click doing nothing.
    private final class FirstClickButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private final class Target: NSObject {
        @objc func run() {
            let run = Toast.action
            Toast.action = nil
            Toast.hide()
            run?()
        }
    }
    private static let target = Target()

    static func show(_ message: String, action title: String? = nil, seconds: TimeInterval? = nil,
                     perform: (() -> Void)? = nil) {
        // Registered before the no-toast switch, which hides the message, not what it offers.
        action = (title != nil) ? perform : nil
        guard ProcessInfo.processInfo.environment["PINTACK_NO_TOAST"] == nil else { return }

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.sizeToFit()

        var button: NSButton?
        if let title {
            let b = FirstClickButton(title: title, target: target, action: #selector(Target.run))
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .bold), .foregroundColor: Brand.accentNS])
            b.sizeToFit()
            b.setAccessibilityLabel(title)
            button = b
        }
        let buttonRoom = button.map { $0.frame.width + 18 } ?? 0

        let size = NSSize(width: label.frame.width + 34 + buttonRoom, height: 34)
        let panel = self.panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = button == nil
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]

        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        label.frame = NSRect(x: 17, y: (size.height - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        content.addSubview(label)
        if let button {
            button.frame.origin = NSPoint(x: label.frame.maxX + 18, y: (size.height - button.frame.height) / 2)
            content.addSubview(button)
        }
        panel.contentView = content

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 34,
                                  width: size.width, height: size.height), display: true)
        }
        // A toast still fading out would put the window away when its fade is taken over, so
        // finish that first, then bring the window up for this one.
        Motion.cancel(panel, key: "alpha")
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        // Rises the last few points into place rather than just fading up.
        if Motion.enabled, let layer = content.layer {
            let rise = CASpringAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -16
            rise.toValue = 0
            rise.mass = 1; rise.stiffness = 240; rise.damping = 19
            rise.duration = rise.settlingDuration
            layer.add(rise, forKey: "pintack.toast")
        }
        Motion.fade(panel, to: 1, duration: 0.15, curve: Motion.Curve.easeOut)
        self.panel = panel

        hideTask?.cancel()
        let task = DispatchWorkItem {
            Toast.action = nil          // Undo is only on offer while it can be seen
            hide()
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + (seconds ?? 1.5), execute: task)
    }

    private static func hide() {
        hideTask?.cancel()
        guard let panel else { return }
        Motion.fade(panel, to: 0, duration: 0.25, curve: Motion.Curve.easeIn) { panel.orderOut(nil) }
    }

    #if DEBUG
    /// What the self-test can see of the toast, and a way to press its button without a mouse.
    static var debugOffersAction: Bool { action != nil }
    /// nil when toasts are switched off for the run and there is no panel to ask.
    static var debugTakesClicks: Bool? {
        ProcessInfo.processInfo.environment["PINTACK_NO_TOAST"] != nil ? nil : panel?.ignoresMouseEvents == false
    }
    static func debugPerformAction() { target.run() }
    #endif
}
