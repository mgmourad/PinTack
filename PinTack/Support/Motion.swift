import AppKit

/// The app's movement, in one place so it stays consistent and can be switched off.
///
/// Every animation here is short and small on purpose: a sticky note that bounces around is
/// tiring by the tenth one of the day. They exist to say where something came from, not to
/// entertain. Anyone who has asked macOS to reduce motion gets none of them.
enum Motion {

    /// System → Accessibility → Display → Reduce motion. Checked live rather than cached, because
    /// it can be turned on while the app is running.
    static var enabled: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Something appearing.
    static let appear: TimeInterval = 0.17
    /// Something going away, always quicker than it arrived: waiting to dismiss feels slow.
    static let dismiss: TimeInterval = 0.12

    /// Fades a window in, with the given view growing very slightly into place behind it.
    static func appear(window: NSWindow, content: NSView?, to alpha: CGFloat) {
        guard enabled else { window.alphaValue = alpha; return }
        window.alphaValue = 0
        if let layer = content?.layer {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.97
            scale.toValue = 1.0
            scale.duration = appear
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(scale, forKey: "pintack.appear")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = appear
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = alpha
        }
    }

    /// Fades a window out and then runs `finished`. The closure ALWAYS runs, motion or not, so
    /// nothing downstream can be left waiting for an animation that never happened.
    static func dismiss(window: NSWindow, then finished: @escaping () -> Void) {
        guard enabled, window.isVisible, window.alphaValue > 0 else { return finished() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = dismiss
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: finished)
    }
}
