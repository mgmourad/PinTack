#!/usr/bin/env swift
// The README's banner.
//
//     swift scripts/make-banner.swift
//
// Writes docs/assets/banner.png at 2x. The note cards in it are the REAL tutorial screenshots
// (PinTack/Resources/Tutorial/*.png, taken from the running app by make-tutorial-shots.sh) floated
// on a gradient — they are cut out already, their corners are fully transparent, so nothing has to
// be masked. Re-run this if the app's look changes, after re-running make-tutorial-shots.sh.
import AppKit

let W: CGFloat = 2400, H: CGFloat = 820          // 2x; the README displays it at half this
let root = FileManager.default.currentDirectoryPath

func hex(_ s: String, _ a: CGFloat = 1) -> NSColor {
    var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

// The app's own colours: the dark theme's deep indigo and Brand.accentNS (#FF9F0A).
let indigo = hex("141128"), violet = hex("3B1D6E"), plum = hex("6B2BA8"), accent = hex("FF9F0A")

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let gc = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gc
let ctx = gc.cgContext

// Rounded canvas: the banner has its own corners rather than butting against the page.
let canvas = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: W, height: H), xRadius: 44, yRadius: 44)
canvas.addClip()

// Base gradient, then two soft blooms — the violet one behind the wordmark, the warm one behind the
// cards, so the eye travels left to right.
NSGradient(colors: [hex("120E24"), hex("1B1138"), hex("241048")],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 20)

func bloom(_ c: NSColor, at p: NSPoint, radius: CGFloat, strength: CGFloat) {
    let g = NSGradient(colors: [c.withAlphaComponent(strength), c.withAlphaComponent(0)])!
    g.draw(fromCenter: p, radius: 0, toCenter: p, radius: radius, options: [])
}
bloom(plum,   at: NSPoint(x: 260,  y: H + 120), radius: 900, strength: 0.55)
bloom(violet, at: NSPoint(x: 1180, y: -160),    radius: 860, strength: 0.45)
bloom(accent, at: NSPoint(x: 2120, y: 150),     radius: 820, strength: 0.30)

// A dot grid, barely there: texture rather than decoration.
ctx.saveGState()
hex("FFFFFF", 0.045).setFill()
for x in stride(from: CGFloat(40), to: W, by: 44) {
    for y in stride(from: CGFloat(40), to: H, by: 44) {
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: 2.6, height: 2.6))
    }
}
ctx.restoreGState()

// MARK: The real note cards, floated

func card(_ name: String, width: CGFloat, centre: NSPoint, degrees: CGFloat, shadow: CGFloat) {
    guard let img = NSImage(contentsOfFile: "\(root)/PinTack/Resources/Tutorial/\(name).png") else {
        FileHandle.standardError.write("missing screenshot: \(name)\n".data(using: .utf8)!); return
    }
    let scale = width / img.size.width
    let size = NSSize(width: width, height: img.size.height * scale)
    ctx.saveGState()
    ctx.translateBy(x: centre.x, y: centre.y)
    ctx.rotate(by: degrees * .pi / 180)
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(0.55)
    s.shadowBlurRadius = shadow
    s.shadowOffset = NSSize(width: 0, height: -shadow / 3)
    s.set()
    img.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
             from: .zero, operation: .sourceOver, fraction: 1)
    ctx.restoreGState()
}

// Back to front, so the nearest card overlaps the others. Sized and placed to sit WHOLLY inside
// the canvas: a card clipped by the banner's own edge reads as a mistake rather than as depth.
card("code",         width: 500, centre: NSPoint(x: 2040, y: 500), degrees: 6,  shadow: 50)
card("todo",         width: 470, centre: NSPoint(x: 1530, y: 360), degrees: -7, shadow: 50)
card("live-preview", width: 540, centre: NSPoint(x: 1800, y: 410), degrees: -1, shadow: 80)

// MARK: Words

func draw(_ text: String, font: NSFont, colour: NSColor, at p: NSPoint, tracking: CGFloat = 0) -> NSSize {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .kern: tracking]
    let a = NSAttributedString(string: text, attributes: attrs)
    a.draw(at: p)
    return a.size()
}

let bold = NSFont.systemFont(ofSize: 132, weight: .bold)
// The slogan is the app's own hand — Comic Sans, the default note font (Brand.sloganFont).
let comic = NSFont(name: "Comic Sans MS", size: 46) ?? NSFont.systemFont(ofSize: 46, weight: .medium)

_ = draw("PinTack", font: bold, colour: .white, at: NSPoint(x: 150, y: 470), tracking: -3)
_ = draw("Stick it. Stack it. Ship it.", font: comic, colour: accent, at: NSPoint(x: 158, y: 396))
_ = draw("Sticky notes for macOS, backed by plain Markdown files.",
         font: NSFont.systemFont(ofSize: 38, weight: .regular),
         colour: hex("FFFFFF", 0.72), at: NSPoint(x: 158, y: 316))

// Chips: the three things somebody skimming needs to know.
func chip(_ text: String, at x: CGFloat, y: CGFloat) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 30, weight: .semibold)
    let size = NSAttributedString(string: text, attributes: [.font: font]).size()
    let w = size.width + 56, h: CGFloat = 70
    let r = NSRect(x: x, y: y, width: w, height: h)
    let path = NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2)
    hex("FFFFFF", 0.07).setFill(); path.fill()
    hex("FFFFFF", 0.16).setStroke(); path.lineWidth = 2; path.stroke()
    _ = draw(text, font: font, colour: hex("FFFFFF", 0.88),
             at: NSPoint(x: x + 28, y: y + (h - size.height) / 2 + 1))
    return x + w + 20
}
var cx: CGFloat = 158
for label in ["Live Preview", "Stacks", "Todos & reminders", "Plugins"] { cx = chip(label, at: cx, y: 196) }

// A hairline of light along the top edge, the way a pane catches it.
ctx.saveGState()
NSGradient(colors: [hex("FFFFFF", 0), hex("FFFFFF", 0.30), hex("FFFFFF", 0)])!
    .draw(in: NSRect(x: 0, y: H - 3, width: W, height: 3), angle: 0)
ctx.restoreGState()

// A fine inner border keeps the banner from dissolving into a dark README background.
hex("FFFFFF", 0.10).setStroke()
let edge = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: W - 2, height: H - 2), xRadius: 43, yRadius: 43)
edge.lineWidth = 2
edge.stroke()

NSGraphicsContext.restoreGraphicsState()

let out = URL(fileURLWithPath: "\(root)/docs/assets/banner.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("docs/assets/banner.png: \(Int(W))×\(Int(H))")
