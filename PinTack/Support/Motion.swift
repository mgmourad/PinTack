import AppKit

/// The app's movement, in one place so it stays consistent.
///
/// Springs rather than eased curves: a spring overshoots very slightly and settles, which is what
/// makes iOS feel alive where a linear fade feels like a slideshow. `CASpringAnimation` is real
/// physics — mass, stiffness, damping — so the note keeps moving for exactly as long as a spring
/// of that stiffness would, and nothing has to be hand-timed.
///
/// The one thing that switches it all off is the system's own Reduce Motion setting, which people
/// who get motion sick turn on deliberately. That is an accessibility promise, not a default.
enum Motion {

    /// System Settings → Accessibility → Display → Reduce motion. Read live: it can be turned on
    /// while the app is running.
    static var enabled: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A window arriving. Lively, with a little overshoot at the end.
    private static func arrivalSpring(keyPath: String, from: Any, to: Any) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.fromValue = from
        spring.toValue = to
        spring.mass = 1
        spring.stiffness = 300        // snappy
        spring.damping = 17           // under-damped: a clear overshoot, then settles
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        return spring
    }

    /// Something going away is always quicker than it arrived: waiting to dismiss feels slow.
    static let dismissDuration: TimeInterval = 0.16

    /// Grows a window into place with a spring while it fades in.
    static func appear(window: NSWindow, content: NSView?, to alpha: CGFloat) {
        guard enabled else { window.alphaValue = alpha; return }
        window.alphaValue = 0

        if let layer = content?.layer {
            layer.add(arrivalSpring(keyPath: "transform.scale", from: 0.80, to: 1.0), forKey: "pintack.appear.scale")
            // A short drop from above, so a new note reads as landing on the desk.
            layer.add(arrivalSpring(keyPath: "transform.translation.y", from: 22, to: 0), forKey: "pintack.appear.drop")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16       // the fade finishes early; the spring carries the rest
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = alpha
        }
    }

    /// Shrinks a window away and then runs `finished`. The closure ALWAYS runs, motion or not, so
    /// nothing downstream can be left waiting for an animation that never happened.
    static func dismiss(window: NSWindow, content: NSView? = nil, then finished: @escaping () -> Void) {
        guard enabled, window.isVisible, window.alphaValue > 0 else { return finished() }
        if let layer = content?.layer {
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1.0
            shrink.toValue = 0.90
            shrink.duration = dismissDuration
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "pintack.dismiss.scale")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = dismissDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: finished)
    }

    /// A spring applied to a window's frame, for collapse and expand.
    static func springFrame(_ window: NSWindow, to frame: NSRect) {
        guard enabled else { window.setFrame(frame, display: true); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            // Gentler overshoot than the layer springs get: a window's frame is clamped by minSize,
            // and a collapse targets exactly that, so a big overshoot would hit the clamp and stutter.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.12, 0.36, 1)
            window.animator().setFrame(frame, display: true)
        }
    }

    /// Attention: a quick squash-and-settle on a layer, used when a note is pointed at.
    static func bounce(_ view: NSView?) {
        guard enabled, let layer = view?.layer else { return }
        let spring = arrivalSpring(keyPath: "transform.scale", from: 1.06, to: 1.0)
        spring.stiffness = 220
        spring.damping = 12          // wobblier than an arrival: it is meant to catch the eye
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pintack.bounce")
    }
}
