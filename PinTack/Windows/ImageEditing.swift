import AppKit

/// Cropping and resizing the pixels of an image. The UI for it lives in the note itself
/// (Editor/editor.js): click an image and it gets corner handles, a crop tool and a bin. There is
/// deliberately no separate window and nothing to type — this is a sticky-note app.
///
/// Swift only does the pixel work: the editor sends a rectangle, this writes a NEW attachment and
/// the note's link is pointed at it, so the original file is never overwritten.
enum ImageEditing {

    /// Renders the chosen rectangle at the chosen size. Always PNG: it is lossless and the one
    /// format every path here can produce, whatever the pasteboard handed us.
    static func png(from image: NSImage, crop: NSRect?, size: NSSize?) -> Data? {
        let pixels = pixelSize(of: image)
        let source = crop ?? NSRect(origin: .zero, size: pixels)
        let target = size ?? source.size
        guard target.width >= 1, target.height >= 1, pixels.width >= 1, pixels.height >= 1 else { return nil }

        // `draw(in:from:…)` reads `from` in the image's own coordinate space, which is POINTS, while
        // every rectangle here is in pixels so that a 2x screenshot keeps its resolution. On a Retina
        // image the two differ by the backing scale, and passing pixels straight through silently
        // drew the wrong part of the picture (a crop came out black).
        let toPoints = NSSize(width: image.size.width / pixels.width, height: image.size.height / pixels.height)
        let sourceInPoints = NSRect(x: source.minX * toPoints.width, y: source.minY * toPoints.height,
                                    width: source.width * toPoints.width, height: source.height * toPoints.height)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: sourceInPoints, operation: .copy, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// An NSImage's `size` is in points; a Retina screenshot is twice that in pixels, and cropping
    /// in points would silently halve a pasted screenshot.
    static func pixelSize(of image: NSImage) -> NSSize {
        var best = image.size
        for rep in image.representations where rep.pixelsWide > 0 {
            let candidate = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            if candidate.width > best.width { best = candidate }
        }
        return best
    }
}
