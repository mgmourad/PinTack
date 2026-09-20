import AppKit

/// A brief, click-through message at the bottom of the screen. Feedback for actions
/// that have no other visible result (pinned, hidden, arranged...). From the prototype.
enum Toast {

    private static var panel: NSPanel?
    private static var hideTask: DispatchWorkItem?

    static func show(_ message: String) {
        guard ProcessInfo.processInfo.environment["PINTACK_NO_TOAST"] == nil else { return }

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.sizeToFit()

        let size = NSSize(width: label.frame.width + 34, height: 34)
        let panel = self.panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
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
        panel.contentView = content

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.minY + 34,
                                  width: size.width, height: size.height), display: true)
        }
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
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel

        hideTask?.cancel()
        let task = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: task)
    }
}
