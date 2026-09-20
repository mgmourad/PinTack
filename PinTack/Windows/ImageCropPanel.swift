import AppKit

/// Crop and resize an image before it goes into a note. SPEC.md §7.
///
/// Shown when an image is pasted, dropped or picked. "Use original" is the first button so a quick
/// paste is still one keystroke away (Return), and nothing is written into the vault until the
/// sheet is answered: cancelling leaves no attachment behind.
final class ImageCropPanel: NSWindowController {

    /// Keeps the controller alive while its sheet is up.
    private static var active: ImageCropPanel?

    private let original: NSImage
    private let completion: (Data?, String) -> Void
    private let cropView: CropView
    private let sizeSlider = NSSlider()
    private let sizeLabel = NSTextField(labelWithString: "")
    private var scale: CGFloat = 1

    /// Pixel size of the crop the user has chosen, before the resize slider.
    private var croppedPixelSize: NSSize {
        let r = cropView.cropRectInImage
        return NSSize(width: max(1, r.width.rounded()), height: max(1, r.height.rounded()))
    }

    private var outputPixelSize: NSSize {
        let s = croppedPixelSize
        return NSSize(width: max(1, (s.width * scale).rounded()), height: max(1, (s.height * scale).rounded()))
    }

    /// `completion` gets PNG data and its extension, or nil when the user cancelled.
    init(image: NSImage, completion: @escaping (Data?, String) -> Void) {
        self.original = image
        self.completion = completion
        self.cropView = CropView(image: image)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 470))
        let window = NSWindow(contentRect: content.bounds,
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        window.title = "Insert Image"
        super.init(window: window)

        cropView.frame = NSRect(x: 16, y: 96, width: 488, height: 356)
        cropView.autoresizingMask = [.width, .height]
        cropView.onCropChange = { [weak self] in self?.updateLabel() }
        content.addSubview(cropView)

        let hint = NSTextField(labelWithString: "Drag inside the picture to crop it. Drag a corner to adjust.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 16, y: 72, width: 488, height: 16)
        content.addSubview(hint)

        let resizeLabel = NSTextField(labelWithString: "Size")
        resizeLabel.frame = NSRect(x: 16, y: 42, width: 34, height: 18)
        content.addSubview(resizeLabel)

        sizeSlider.minValue = 0.1
        sizeSlider.maxValue = 1.0
        sizeSlider.doubleValue = 1.0
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged)
        sizeSlider.frame = NSRect(x: 54, y: 40, width: 250, height: 22)
        content.addSubview(sizeSlider)

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.frame = NSRect(x: 312, y: 42, width: 192, height: 18)
        content.addSubview(sizeLabel)

        let reset = NSButton(title: "Reset", target: self, action: #selector(resetCrop))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 16, y: 8, width: 74, height: 26)
        content.addSubview(reset)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 240, y: 8, width: 84, height: 26)
        content.addSubview(cancel)

        let originalButton = NSButton(title: "Use Original", target: self, action: #selector(useOriginal))
        originalButton.bezelStyle = .rounded
        originalButton.frame = NSRect(x: 326, y: 8, width: 106, height: 26)
        content.addSubview(originalButton)

        let insert = NSButton(title: "Insert", target: self, action: #selector(insert))
        insert.bezelStyle = .rounded
        insert.keyEquivalent = "\r"
        insert.frame = NSRect(x: 434, y: 8, width: 70, height: 26)
        content.addSubview(insert)

        updateLabel()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Presents as a sheet on `parent`, or as its own window when there is none.
    static func present(image: NSImage, over parent: NSWindow?, completion: @escaping (Data?, String) -> Void) {
        let controller = ImageCropPanel(image: image, completion: completion)
        active = controller
        guard let sheet = controller.window else { return completion(nil, "png") }
        NSApp.activate(ignoringOtherApps: true)
        if let parent, parent.isVisible {
            parent.beginSheet(sheet) { _ in active = nil }
        } else {
            controller.showWindow(nil)
            sheet.center()
            sheet.makeKeyAndOrderFront(nil)
        }
    }

    private func finish(_ data: Data?) {
        let window = self.window
        completion(data, "png")
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        else { close() }
        ImageCropPanel.active = nil
    }

    @objc private func sizeChanged() {
        scale = CGFloat(sizeSlider.doubleValue)
        updateLabel()
    }

    @objc private func resetCrop() {
        cropView.resetCrop()
        sizeSlider.doubleValue = 1
        scale = 1
        updateLabel()
    }

    @objc private func cancel() { finish(nil) }

    @objc private func useOriginal() {
        finish(ImageCropPanel.png(from: original, crop: nil, size: nil))
    }

    @objc private func insert() {
        finish(ImageCropPanel.png(from: original, crop: cropView.cropRectInImage, size: outputPixelSize))
    }

    private func updateLabel() {
        let out = outputPixelSize
        let full = cropView.imagePixelSize
        let cropped = croppedPixelSize
        let cropNote = (cropped.width < full.width - 1 || cropped.height < full.height - 1)
            ? "cropped from \(Int(full.width))×\(Int(full.height)) · " : ""
        sizeLabel.stringValue = "\(cropNote)\(Int(out.width))×\(Int(out.height))"
    }

    /// Renders the chosen rectangle at the chosen size. Always PNG: it is lossless and the one
    /// format every path here can produce, whatever the pasteboard handed us.
    static func png(from image: NSImage, crop: NSRect?, size: NSSize?) -> Data? {
        let pixels = pixelSize(of: image)
        let source = crop ?? NSRect(origin: .zero, size: pixels)
        let target = size ?? source.size
        guard target.width >= 1, target.height >= 1 else { return nil }

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: source, operation: .copy, fraction: 1,
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

// MARK: - The picture with a crop rectangle over it

private final class CropView: NSView {

    private let image: NSImage
    let imagePixelSize: NSSize
    var onCropChange: (() -> Void)?

    /// The crop in IMAGE PIXEL coordinates, origin bottom-left, so it survives a window resize.
    private(set) var cropRectInImage: NSRect

    private enum Handle { case none, body, bottomLeft, bottomRight, topLeft, topRight }
    private var dragging: Handle = .none
    private var dragStart: NSPoint = .zero
    private var rectAtDragStart: NSRect = .zero
    private static let handleSize: CGFloat = 10

    init(image: NSImage) {
        self.image = image
        self.imagePixelSize = ImageCropPanel.pixelSize(of: image)
        self.cropRectInImage = NSRect(origin: .zero, size: imagePixelSize)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func resetCrop() {
        cropRectInImage = NSRect(origin: .zero, size: imagePixelSize)
        needsDisplay = true
        onCropChange?()
    }

    /// Where the picture is actually drawn inside this view, letterboxed to keep its aspect ratio.
    private var imageFrame: NSRect {
        let available = bounds.insetBy(dx: 2, dy: 2)
        guard imagePixelSize.width > 0, imagePixelSize.height > 0 else { return available }
        let scale = min(available.width / imagePixelSize.width, available.height / imagePixelSize.height)
        let size = NSSize(width: imagePixelSize.width * scale, height: imagePixelSize.height * scale)
        return NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private var viewPerPixel: CGFloat {
        imagePixelSize.width > 0 ? imageFrame.width / imagePixelSize.width : 1
    }

    private func toView(_ r: NSRect) -> NSRect {
        let s = viewPerPixel, f = imageFrame
        return NSRect(x: f.minX + r.minX * s, y: f.minY + r.minY * s, width: r.width * s, height: r.height * s)
    }

    private func toImage(_ p: NSPoint) -> NSPoint {
        let s = viewPerPixel, f = imageFrame
        guard s > 0 else { return .zero }
        return NSPoint(x: (p.x - f.minX) / s, y: (p.y - f.minY) / s)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let frame = imageFrame
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)

        let crop = toView(cropRectInImage)
        // Dim everything outside the crop so the kept area reads immediately.
        NSColor.black.withAlphaComponent(0.45).setFill()
        for part in [NSRect(x: frame.minX, y: crop.maxY, width: frame.width, height: frame.maxY - crop.maxY),
                     NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: crop.minY - frame.minY),
                     NSRect(x: frame.minX, y: crop.minY, width: crop.minX - frame.minX, height: crop.height),
                     NSRect(x: crop.maxX, y: crop.minY, width: frame.maxX - crop.maxX, height: crop.height)]
        where part.width > 0 && part.height > 0 {
            part.fill()
        }

        Brand.accentNS.setStroke()
        let outline = NSBezierPath(rect: crop.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1.5
        outline.stroke()

        Brand.accentNS.setFill()
        for corner in corners(of: crop) { NSBezierPath(ovalIn: corner).fill() }
    }

    private func corners(of r: NSRect) -> [NSRect] {
        let h = CropView.handleSize
        return [NSRect(x: r.minX - h / 2, y: r.minY - h / 2, width: h, height: h),
                NSRect(x: r.maxX - h / 2, y: r.minY - h / 2, width: h, height: h),
                NSRect(x: r.minX - h / 2, y: r.maxY - h / 2, width: h, height: h),
                NSRect(x: r.maxX - h / 2, y: r.maxY - h / 2, width: h, height: h)]
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let crop = toView(cropRectInImage)
        let hits: [Handle] = [.bottomLeft, .bottomRight, .topLeft, .topRight]
        dragging = .none
        for (corner, handle) in zip(corners(of: crop), hits) where corner.insetBy(dx: -4, dy: -4).contains(point) {
            dragging = handle
            break
        }
        // Anywhere else inside the picture starts a brand new crop rectangle.
        if dragging == .none {
            guard imageFrame.contains(point) else { return }
            dragging = .bottomRight
            let origin = toImage(point)
            cropRectInImage = NSRect(x: origin.x, y: origin.y, width: 0, height: 0)
        }
        dragStart = point
        rectAtDragStart = cropRectInImage
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging != .none else { return }
        let point = convert(event.locationInWindow, from: nil)
        let now = toImage(point)
        var r = rectAtDragStart

        switch dragging {
        case .bottomLeft:  r = NSRect(x: now.x, y: now.y, width: r.maxX - now.x, height: r.maxY - now.y)
        case .bottomRight: r = NSRect(x: r.minX, y: now.y, width: now.x - r.minX, height: r.maxY - now.y)
        case .topLeft:     r = NSRect(x: now.x, y: r.minY, width: r.maxX - now.x, height: now.y - r.minY)
        case .topRight:    r = NSRect(x: r.minX, y: r.minY, width: now.x - r.minX, height: now.y - r.minY)
        case .body, .none: break
        }
        // A drag past the opposite edge flips the rectangle rather than going negative.
        cropRectInImage = clamp(NSRect(x: min(r.minX, r.maxX), y: min(r.minY, r.maxY),
                                       width: abs(r.width), height: abs(r.height)))
        needsDisplay = true
        onCropChange?()
    }

    override func mouseUp(with event: NSEvent) {
        // A click with no drag means "no crop", not a zero-pixel image.
        if cropRectInImage.width < 4 || cropRectInImage.height < 4 { resetCrop() }
        dragging = .none
        needsDisplay = true
        onCropChange?()
    }

    private func clamp(_ r: NSRect) -> NSRect {
        let bounds = NSRect(origin: .zero, size: imagePixelSize)
        return r.intersection(bounds)
    }
}
