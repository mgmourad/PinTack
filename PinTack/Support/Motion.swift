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

    // MARK: - Window animation, on our own clock
    //
    // AppKit's window animator — `window.animator().alphaValue`, `window.animator().setFrame` — does
    // not run at all in an app that is not the active one. Measured 2026-09-21: a 0.3 s fade from
    // 0.2 still read 0.2 a full second later, and never reached its end value either. Notes are
    // non-activating panels, so PinTack is usually NOT the active app while you use them, and one
    // started at login may never have been. Layer animations are unaffected (the system compositor
    // runs those), so only a window's opacity and frame are driven here, by a timer on the main run
    // loop in common modes, which ticks whether or not the app is in front and during a drag.

    private final class Tween {
        let started = CACurrentMediaTime()
        let duration: TimeInterval
        let curve: (Double) -> Double
        let step: (Double) -> Void
        let completion: (() -> Void)?
        var timer: Timer?
        init(duration: TimeInterval, curve: @escaping (Double) -> Double,
             step: @escaping (Double) -> Void, completion: (() -> Void)?) {
            self.duration = duration; self.curve = curve; self.step = step; self.completion = completion
        }
    }

    /// One running tween per window and property, so a new one (the pointer leaving before the
    /// fade in finished) takes over from where the old one had got to instead of fighting it.
    private static var tweens: [ObjectIdentifier: [String: Tween]] = [:]

    private static func tween(_ window: NSWindow, key: String, duration: TimeInterval,
                              curve: @escaping (Double) -> Double, step: @escaping (Double) -> Void,
                              completion: (() -> Void)? = nil) {
        cancel(window, key: key)
        let id = ObjectIdentifier(window)
        let tween = Tween(duration: duration, curve: curve, step: step, completion: completion)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak window] timer in
            guard window != nil else { timer.invalidate(); return }
            let t = min(1, (CACurrentMediaTime() - tween.started) / max(duration, 0.001))
            tween.step(tween.curve(t))
            guard t >= 1 else { return }
            timer.invalidate()
            if tweens[id]?[key] === tween { tweens[id]?[key] = nil }
            tween.completion?()
        }
        tween.timer = timer
        tweens[id, default: [:]][key] = tween
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops a running tween where it is. Its completion still runs: `dismiss` promises that its
    /// closure ALWAYS runs, and a tween taken over by another is not an excuse to break that.
    static func cancel(_ window: NSWindow, key: String) {
        let id = ObjectIdentifier(window)
        guard let old = tweens[id]?[key] else { return }
        tweens[id]?[key] = nil
        old.timer?.invalidate()
        old.completion?()
    }

    /// Fades a window's opacity on our own clock. See the note above on why not `animator()`.
    static func fade(_ window: NSWindow, to alpha: CGFloat, duration: TimeInterval,
                     curve: @escaping (Double) -> Double = Curve.easeInOut, completion: (() -> Void)? = nil) {
        guard enabled, duration > 0 else {
            cancel(window, key: "alpha")
            window.alphaValue = alpha
            completion?()
            return
        }
        let from = Double(window.alphaValue), to = Double(alpha)
        tween(window, key: "alpha", duration: duration, curve: curve,
              step: { window.alphaValue = CGFloat(from + (to - from) * $0) }, completion: completion)
    }

    /// Easing curves for the window tweens: t in 0...1 to progress, which may overshoot 1.
    enum Curve {
        static let easeOut: (Double) -> Double = { 1 - pow(1 - $0, 3) }
        static let easeIn: (Double) -> Double = { $0 * $0 * $0 }
        static let easeInOut: (Double) -> Double = { $0 < 0.5 ? 4 * $0 * $0 * $0 : 1 - pow(-2 * $0 + 2, 3) / 2 }

        /// A CSS-style cubic-bezier, the same curve `CAMediaTimingFunction(controlPoints:)` draws.
        static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> (Double) -> Double {
            func sample(_ a: Double, _ b: Double, _ t: Double) -> Double {
                let u = 1 - t
                return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
            }
            return { x in
                guard x > 0 else { return 0 }
                guard x < 1 else { return 1 }
                // x(t) is monotonic for any control points inside 0...1, so bisection always lands.
                var lo = 0.0, hi = 1.0, t = x
                for _ in 0..<24 {
                    t = (lo + hi) / 2
                    if sample(x1, x2, t) < x { lo = t } else { hi = t }
                }
                return sample(y1, y2, t)
            }
        }
    }

    /// Grows a window into place with a spring while it fades in.
    static func appear(window: NSWindow, content: NSView?, to alpha: CGFloat) {
        guard enabled else { window.alphaValue = alpha; return }
        window.alphaValue = 0

        if let layer = content?.layer {
            layer.add(arrivalSpring(keyPath: "transform.scale", from: 0.80, to: 1.0), forKey: "pintack.appear.scale")
            // A short drop from above, so a new note reads as landing on the desk.
            layer.add(arrivalSpring(keyPath: "transform.translation.y", from: 22, to: 0), forKey: "pintack.appear.drop")
        }
        // The fade finishes early; the spring carries the rest.
        fade(window, to: alpha, duration: 0.16, curve: Curve.easeOut)
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
        fade(window, to: 0, duration: dismissDuration, curve: Curve.easeIn, completion: finished)
    }

    /// A spring applied to a window's frame, for collapse and expand.
    static func springFrame(_ window: NSWindow, to frame: NSRect) {
        guard enabled else { window.setFrame(frame, display: true); return }
        let from = window.frame
        func mix(_ a: CGFloat, _ b: CGFloat, _ p: Double) -> CGFloat { a + (b - a) * CGFloat(p) }
        // Gentler overshoot than the layer springs get: a window's frame is clamped by minSize,
        // and a collapse targets exactly that, so a big overshoot would hit the clamp and stutter.
        tween(window, key: "frame", duration: 0.32, curve: Curve.bezier(0.22, 1.12, 0.36, 1), step: { p in
            window.setFrame(NSRect(x: mix(from.minX, frame.minX, p), y: mix(from.minY, frame.minY, p),
                                   width: mix(from.width, frame.width, p), height: mix(from.height, frame.height, p)),
                            display: true)
        }, completion: {
            // Land exactly: the curve's last sample is 1, but a rounding error must not leave the
            // persisted geometry (SPEC.md §5.2) a fraction of a point out.
            window.setFrame(frame, display: true)
        })
    }

    /// Springs a popover in. NSPopover's own `animates` is deliberately off (it fades the popover
    /// while it is still being sized), so this animates the finished window instead: the whole
    /// thing, arrow and background included, grows from the control it belongs to.
    static func popover(_ window: NSWindow?) {
        guard enabled, let window, let content = window.contentView else { return }
        content.wantsLayer = true
        guard let layer = content.layer else { return }

        // Grow from the top edge, which is where the arrow meets the button it came from.
        let previousAnchor = layer.anchorPoint
        layer.anchorPoint = CGPoint(x: 0.5, y: 1.0)
        layer.position = CGPoint(x: layer.frame.midX, y: layer.frame.maxY)

        let scale = arrivalSpring(keyPath: "transform.scale", from: 0.90, to: 1.0)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(scale, forKey: "pintack.popover.scale")
        layer.add(fade, forKey: "pintack.popover.fade")

        // Put the anchor back once it has settled, so nothing else that reads the layer is surprised.
        DispatchQueue.main.asyncAfter(deadline: .now() + scale.duration) {
            guard layer.anchorPoint != previousAnchor else { return }
            layer.anchorPoint = previousAnchor
            layer.position = CGPoint(x: layer.frame.midX, y: layer.frame.midY)
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
