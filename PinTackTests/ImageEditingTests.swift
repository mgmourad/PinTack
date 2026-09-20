import XCTest
import AppKit
@testable import PinTack

/// The crop/resize step rewrites the user's picture before it is filed in the vault, so the maths
/// has to be right: a wrong rectangle silently keeps the wrong part of a screenshot.
final class ImageEditingTests: XCTestCase {

    /// A 100×60 image: left half red, right half blue, with a green 10×10 patch at the bottom-left.
    private func sampleImage(scale: Int = 1) -> NSImage {
        let w = 100 * scale, h = 60 * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill();   NSRect(x: 0, y: 0, width: w / 2, height: h).fill()
        NSColor.blue.setFill();  NSRect(x: w / 2, y: 0, width: w / 2, height: h).fill()
        NSColor.green.setFill(); NSRect(x: 0, y: 0, width: 10 * scale, height: 10 * scale).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: 100, height: 60))    // points stay 100×60
        image.addRepresentation(rep)
        return image
    }

    private func pixels(_ data: Data) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(data as Data?)))
    }

    private func colorName(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> String {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return "none" }
        if c.redComponent > 0.5 && c.greenComponent < 0.4 && c.blueComponent < 0.4 { return "red" }
        if c.blueComponent > 0.5 && c.redComponent < 0.4 { return "blue" }
        if c.greenComponent > 0.5 && c.redComponent < 0.4 { return "green" }
        return "other"
    }

    // MARK: Sizes

    func testPixelSizeUsesRealPixelsNotPoints() {
        // A Retina screenshot reports 100×60 points but holds 200×120 pixels. Cropping in points
        // would quietly throw away half the resolution.
        XCTAssertEqual(ImageEditing.pixelSize(of: sampleImage()), NSSize(width: 100, height: 60))
        XCTAssertEqual(ImageEditing.pixelSize(of: sampleImage(scale: 2)), NSSize(width: 200, height: 120))
    }

    func testNoCropAndNoResizeKeepsEveryPixel() throws {
        let data = try XCTUnwrap(ImageEditing.png(from: sampleImage(), crop: nil, size: nil))
        let rep = try pixels(data)
        XCTAssertEqual(rep.pixelsWide, 100)
        XCTAssertEqual(rep.pixelsHigh, 60)
    }

    func testRetinaImageKeepsItsFullResolution() throws {
        let data = try XCTUnwrap(ImageEditing.png(from: sampleImage(scale: 2), crop: nil, size: nil))
        let rep = try pixels(data)
        XCTAssertEqual(rep.pixelsWide, 200, "a 2x screenshot must not be halved on the way in")
        XCTAssertEqual(rep.pixelsHigh, 120)
    }

    func testResizeProducesTheRequestedPixelSize() throws {
        let data = try XCTUnwrap(ImageEditing.png(from: sampleImage(), crop: nil, size: NSSize(width: 50, height: 30)))
        let rep = try pixels(data)
        XCTAssertEqual(rep.pixelsWide, 50)
        XCTAssertEqual(rep.pixelsHigh, 30)
    }

    func testCropProducesTheCropsOwnSize() throws {
        let crop = NSRect(x: 10, y: 5, width: 40, height: 20)
        let data = try XCTUnwrap(ImageEditing.png(from: sampleImage(), crop: crop, size: crop.size))
        let rep = try pixels(data)
        XCTAssertEqual(rep.pixelsWide, 40)
        XCTAssertEqual(rep.pixelsHigh, 20)
    }

    // MARK: The right part of the picture

    func testCroppingTheRightHalfKeepsTheBlueHalf() throws {
        let crop = NSRect(x: 50, y: 0, width: 50, height: 60)
        let data = try XCTUnwrap(ImageEditing.png(from: sampleImage(), crop: crop, size: crop.size))
        let rep = try pixels(data)
        XCTAssertEqual(colorName(rep, 5, 30), "blue")
        XCTAssertEqual(colorName(rep, 45, 30), "blue", "no red may survive a crop of the blue half")
    }

    func testCroppingTheLeftHalfKeepsTheRedHalf() throws {
        let crop = NSRect(x: 0, y: 0, width: 50, height: 60)
        let data = try XCTUnwrap(ImageEditing.png(from: sampleImage(), crop: crop, size: crop.size))
        let rep = try pixels(data)
        XCTAssertEqual(colorName(rep, 45, 30), "red")
    }

    /// The crop rect has its origin at the BOTTOM left (AppKit), while a bitmap is read from the
    /// top. Getting that backwards keeps the wrong band of the picture, which is the easiest
    /// mistake to make here and impossible to see in the numbers alone.
    func testCropOriginIsTheBottomLeftCorner() throws {
        let crop = NSRect(x: 0, y: 0, width: 10, height: 10)          // the green patch
        let data = try XCTUnwrap(ImageEditing.png(from: sampleImage(), crop: crop, size: crop.size))
        let rep = try pixels(data)
        XCTAssertEqual(colorName(rep, 5, 5), "green", "y:0 must mean the bottom of the picture")
    }

    /// NoteEditorView decides whether the user actually changed anything by re-rendering the
    /// untouched image and comparing bytes. If a full-size crop did not match, every quick paste
    /// of a JPEG would be re-encoded as a much larger PNG.
    func testAFullCropAtFullSizeIsByteIdenticalToNoCropAtAll() throws {
        let image = sampleImage(scale: 2)
        let full = NSRect(origin: .zero, size: ImageEditing.pixelSize(of: image))
        let untouched = try XCTUnwrap(ImageEditing.png(from: image, crop: nil, size: nil))
        let explicit = try XCTUnwrap(ImageEditing.png(from: image, crop: full, size: full.size))
        XCTAssertEqual(untouched, explicit)
    }

    // MARK: Retina: the gap that let a real bug through

    /// These used to check only the OUTPUT DIMENSIONS at 2x, never the pixels, so a crop of a
    /// Retina image could come out black and every test still passed. `draw(in:from:)` reads
    /// `from` in the image's POINT space while every rect here is in pixels; on a 2x image the
    /// two differ and the wrong region was read.
    func testCroppingARetinaImageKeepsTheRIGHTPixelsNotJustTheRightSize() throws {
        let image = sampleImage(scale: 2)                 // 100x60 points, 200x120 pixels
        let full = try XCTUnwrap(ImageEditing.png(from: image, crop: nil, size: nil))
        let whole = try pixels(full)
        XCTAssertEqual(colorName(whole, 30, 60), "red", "the left half of a 2x image must still be red")
        XCTAssertEqual(colorName(whole, 170, 60), "blue", "the right half of a 2x image must still be blue")

        // Crop the right (blue) half, in pixels.
        let crop = NSRect(x: 100, y: 0, width: 100, height: 120)
        let data = try XCTUnwrap(ImageEditing.png(from: image, crop: crop, size: crop.size))
        let rep = try pixels(data)
        XCTAssertEqual(rep.pixelsWide, 100)
        XCTAssertEqual(rep.pixelsHigh, 120)
        for x in [5, 50, 95] {
            XCTAssertEqual(colorName(rep, x, 60), "blue", "x=\(x) of a 2x right-half crop must be blue, not black")
        }
    }

    func testRetinaCropKeepsTheBottomLeftOriginToo() throws {
        let image = sampleImage(scale: 2)
        let crop = NSRect(x: 0, y: 0, width: 20, height: 20)      // the green patch, in pixels
        let data = try XCTUnwrap(ImageEditing.png(from: image, crop: crop, size: crop.size))
        XCTAssertEqual(colorName(try pixels(data), 10, 10), "green")
    }

    func testDegenerateCropIsRefusedRatherThanWritingAnEmptyFile() {
        XCTAssertNil(ImageEditing.png(from: sampleImage(), crop: .zero, size: NSSize(width: 0, height: 0)))
    }
}
