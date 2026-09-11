import CoreGraphics
import CoreText
import Foundation
import ImageIO
import XCTest

/// Regenerates the go-runner app icon from `Resources/AppIconSource.png`. Opt-in:
///
///     GORUNNER_MAKE_ICON=1 swift test --filter AppIconGeneratorTests
///     iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
///
/// Writes `build/AppIcon.iconset/icon_*.png` and `build/sprite-previews/_app-icon.png`
/// (1024/256/128/64/32/16 px on light and dark, plus the small sizes magnified).
final class AppIconGeneratorTests: XCTestCase {
    func testGenerateAppIconset() throws {
        guard ProcessInfo.processInfo.environment["GORUNNER_MAKE_ICON"] == "1" else {
            throw XCTSkip("Set GORUNNER_MAKE_ICON=1 to regenerate build/AppIcon.iconset")
        }
        // GORUNNER_ICON_ROOT lets the generator run from a partial checkout while other targets are mid-edit.
        let root = ProcessInfo.processInfo.environment["GORUNNER_ICON_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try AppIconArt.Source(url: root.appendingPathComponent("Resources/AppIconSource.png"))
        XCTAssertEqual(source.bands.count, 2, "expected the runner figure above the reference wordmark")
        XCTAssertNotNil(CTFontCreateWithName(AppIconArt.wordmarkFont as CFString, 12, nil))
        XCTAssertEqual(CTFontCopyPostScriptName(CTFontCreateWithName(AppIconArt.wordmarkFont as CFString, 12, nil)) as String,
                       AppIconArt.wordmarkFont, "wordmark font missing; CoreText substituted another face")

        let iconset = root.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)
        let previews = root.appendingPathComponent("build/sprite-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)

        for (name, pixels) in AppIconArt.iconsetEntries {
            let image = try XCTUnwrap(AppIconArt.render(source, pixels: pixels), name)
            XCTAssertEqual(image.width, pixels, name)
            try ContactSheet.writePNG(image, to: iconset.appendingPathComponent("\(name).png"))
        }
        XCTAssertTrue(AppIconArt.showsWordmark(pixels: 64))
        XCTAssertFalse(AppIconArt.showsWordmark(pixels: 32))
        let preview = try XCTUnwrap(AppIconArt.preview(source))
        try ContactSheet.writePNG(preview, to: previews.appendingPathComponent("_app-icon.png"))
    }
}

/// Interpark Tour runner figure on blue, with "GO" set where the reference says "TOUR", re-rendered on the macOS
/// icon tile. Personal use only; see THIRD_PARTY_NOTICES.md.
enum AppIconArt {
    static let blue: UInt32 = 0x1769FFFF  // background of the reference mark
    static let wordmark = "GO"
    /// Closest system face to the reference "TOUR" lettering (geometric O, stems about a fifth of the cap height).
    static let wordmarkFont = "AvenirNext-DemiBold"

    static let iconsetEntries: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    // MARK: Source

    /// White coverage of the square reference image (0...255 per pixel, row 0 at the top).
    struct Source {
        let size: Int
        let coverage: [UInt8]
        /// Pixel bounds of each horizontal band of artwork, top to bottom (figure, then wordmark).
        let bands: [CGRect]

        init(url: URL) throws {
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  image.width == image.height,
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
            }
            let size = image.width
            var rgba = [UInt8](repeating: 0, count: size * size * 4)
            rgba.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                    bytesPerRow: size * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            }
            // White has full red, the blue ground almost none: red above the corner's red is coverage.
            let groundRed = Int(rgba[0])
            let coverage = (0..<(size * size)).map { index -> UInt8 in
                let lifted = (Int(rgba[index * 4]) - groundRed) * 255 / max(1, 255 - groundRed)
                return UInt8(min(255, max(0, lifted)))
            }

            var bands: [CGRect] = []
            var band: (top: Int, bottom: Int, left: Int, right: Int)?
            for y in 0..<size {
                let columns = (0..<size).filter { coverage[y * size + $0] > 16 }
                if let left = columns.first, let right = columns.last {
                    if let open = band {
                        band = (open.top, y, min(open.left, left), max(open.right, right))
                    } else {
                        band = (y, y, left, right)
                    }
                } else if let open = band {
                    bands.append(Self.padded(open, size: size))
                    band = nil
                }
            }
            if let open = band { bands.append(Self.padded(open, size: size)) }
            self.init(size: size, coverage: coverage, bands: bands)
        }

        private init(size: Int, coverage: [UInt8], bands: [CGRect]) {
            self.size = size
            self.coverage = coverage
            self.bands = bands
        }

        /// The same image with every band below the figure cleared (the wordmark is redrawn as text).
        func figureOnly() -> Source {
            var cleared = coverage
            for band in bands.dropFirst() {
                for y in Int(band.minY)..<Int(band.maxY) {
                    for x in Int(band.minX)..<Int(band.maxX) { cleared[y * size + x] = 0 }
                }
            }
            return Source(size: size, coverage: cleared, bands: Array(bands.prefix(1)))
        }

        private static func padded(_ band: (top: Int, bottom: Int, left: Int, right: Int), size: Int) -> CGRect {
            let left = max(0, band.left - 1), top = max(0, band.top - 1)
            let right = min(size - 1, band.right + 1), bottom = min(size - 1, band.bottom + 1)
            return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }
    }

    // MARK: Layout

    /// The wordmark stays wherever its letter strokes are at least about a pixel wide; smaller icons show the figure alone.
    static func showsWordmark(pixels: Int) -> Bool { pixels >= 64 }

    /// macOS 11+ icon grid: an 824×824 tile centred on the 1024×1024 canvas.
    static func tile(pixels: Int) -> CGRect {
        let scale = CGFloat(pixels) / 1024
        return CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    }

    /// Which part of the source to draw and where (whole pixels, y down).
    static func artwork(_ source: Source, pixels: Int) -> (crop: CGRect, rect: CGRect) {
        let tile = tile(pixels: pixels)
        if showsWordmark(pixels: pixels) || source.bands.isEmpty {
            // The reference is a full-bleed square: map it onto the tile unchanged.
            return (CGRect(x: 0, y: 0, width: source.size, height: source.size), tile.integral)
        }
        let figure = source.bands[0]
        let height = (tile.height * 0.72).rounded()
        let width = max(1, (height * figure.width / figure.height).rounded())
        let rect = CGRect(x: (tile.midX - width / 2).rounded(), y: (tile.midY - height / 2).rounded(),
                          width: width, height: height)
        return (figure, rect)
    }

    // MARK: Rendering

    static func render(_ source: Source, pixels: Int) -> CGImage? {
        guard let ctx = ContactSheet.makeContext(width: pixels, height: pixels) else { return nil }
        let scale = CGFloat(pixels) / 1024
        ctx.setShouldAntialias(true)
        ctx.saveGState()
        if pixels >= 64 {
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: CGColor(gray: 0, alpha: 0.3))
        }
        ctx.addPath(squircle(in: tile(pixels: pixels)))
        ctx.setFillColor(ContactSheet.color(blue))
        ctx.fillPath()
        ctx.restoreGState()

        let figure = source.figureOnly()
        let (crop, rect) = artwork(figure, pixels: pixels)
        guard let mask = resampledCoverage(figure, crop: crop, width: Int(rect.width), height: Int(rect.height)) else {
            return nil
        }
        ctx.saveGState()
        // The context is flipped (y down); flip back so the mask stays upright.
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let local = CGRect(origin: .zero, size: rect.size)
        ctx.clip(to: local, mask: mask)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(local)
        ctx.restoreGState()

        if showsWordmark(pixels: pixels) { drawWordmark(ctx, source: source, pixels: pixels) }
        return ctx.makeImage()
    }

    /// "GO" in the reference wordmark's place: same cap height and baseline, centred on the tile.
    static func drawWordmark(_ ctx: CGContext, source: Source, pixels: Int) {
        guard source.bands.count > 1 else { return }
        let tile = tile(pixels: pixels)
        let scale = tile.width / CGFloat(source.size)
        let band = source.bands[1]  // padded by one pixel on each side
        let capHeight = (band.height - 2) * scale
        let baseline = tile.minY + (band.maxY - 1) * scale

        let probe = CTFontCreateWithName(wordmarkFont as CFString, 100, nil)
        let font = CTFontCreateWithName(wordmarkFont as CFString, 100 * capHeight / CTFontGetCapHeight(probe), nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: wordmark, attributes: attributes))
        let glyphs = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        ctx.saveGState()
        ctx.translateBy(x: tile.midX - glyphs.midX, y: baseline)
        ctx.scaleBy(x: 1, y: -1)  // the context is flipped (y down); flip text back upright
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Coverage of `crop` resampled to `width`×`height` as a DeviceGray mask (white paints).
    /// Shrinking averages the source area under each pixel; enlarging uses high-quality interpolation, then
    /// steepens the edge ramp by the scale factor so outlines stay about one pixel soft instead of blurring.
    static func resampledCoverage(_ source: Source, crop: CGRect, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let cropX = Int(crop.minX), cropY = Int(crop.minY), cropWidth = Int(crop.width), cropHeight = Int(crop.height)
        let gray = CGColorSpaceCreateDeviceGray()
        var bytes = [UInt8](repeating: 0, count: width * height)

        if width <= cropWidth {
            let stepX = Double(cropWidth) / Double(width), stepY = Double(cropHeight) / Double(height)
            for y in 0..<height {
                let y0 = Double(y) * stepY, y1 = Double(y + 1) * stepY
                for x in 0..<width {
                    let x0 = Double(x) * stepX, x1 = Double(x + 1) * stepX
                    var sum = 0.0
                    for sy in Int(y0)..<min(cropHeight, Int(y1.rounded(.up))) {
                        let wy = min(Double(sy + 1), y1) - max(Double(sy), y0)
                        let row = (cropY + sy) * source.size + cropX
                        for sx in Int(x0)..<min(cropWidth, Int(x1.rounded(.up))) {
                            let wx = min(Double(sx + 1), x1) - max(Double(sx), x0)
                            sum += Double(source.coverage[row + sx]) * wx * wy
                        }
                    }
                    bytes[y * width + x] = UInt8(min(255, (sum / (stepX * stepY)).rounded()))
                }
            }
        } else {
            var cropped = [UInt8](repeating: 0, count: cropWidth * cropHeight)
            for y in 0..<cropHeight {
                let from = (cropY + y) * source.size + cropX
                cropped.replaceSubrange((y * cropWidth)..<((y + 1) * cropWidth), with: source.coverage[from..<(from + cropWidth)])
            }
            guard let original = grayImage(cropped, width: cropWidth, height: cropHeight, space: gray) else { return nil }
            bytes.withUnsafeMutableBytes { buffer in
                guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                ctx.interpolationQuality = .high
                ctx.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            let gain = Double(width) / Double(cropWidth)
            for index in bytes.indices {
                let steepened = (Double(bytes[index]) / 255 - 0.5) * gain + 0.5
                bytes[index] = UInt8((min(1, max(0, steepened)) * 255).rounded())
            }
        }
        return grayImage(bytes, width: width, height: height, space: gray)
    }

    static func grayImage(_ bytes: [UInt8], width: Int, height: Int, space: CGColorSpace) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Superellipse (n = 5), close to Apple's continuous-corner icon tile.
    static func squircle(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let a = rect.width / 2, b = rect.height / 2, exponent: CGFloat = 2 / 5
        for i in 0..<720 {
            let t = CGFloat(i) / 720 * 2 * .pi
            let cosT = cos(t), sinT = sin(t)
            let point = CGPoint(x: rect.midX + a * (cosT < 0 ? -1 : 1) * pow(abs(cosT), exponent),
                                y: rect.midY + b * (sinT < 0 ? -1 : 1) * pow(abs(sinT), exponent))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    // MARK: Preview

    /// 1024/256/128/64/32/16 px at actual pixels, then 64 px at 4× and 32/16 px at 8×, on light and dark.
    static func preview(_ source: Source) -> CGImage? {
        let native = [1024, 256, 128, 64, 32, 16]
        let magnified = [(64, 4), (32, 8), (16, 8)]
        let margin: CGFloat = 16, gap: CGFloat = 16, label: CGFloat = 24, rowHeight: CGFloat = 1024
        let rowWidth = native.reduce(CGFloat(0)) { $0 + CGFloat($1) + gap }
            + magnified.reduce(CGFloat(0)) { $0 + CGFloat($1.0 * $1.1) + gap }
        let totalWidth = margin * 2 + rowWidth
        let totalHeight = margin * 2 + 2 * (label + rowHeight + gap)
        guard let ctx = ContactSheet.makeContext(width: Int(totalWidth), height: Int(totalHeight)) else { return nil }
        ContactSheet.fill(ctx, CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight), ContactSheet.color(ContactSheet.page))
        let withText = native.filter { showsWordmark(pixels: $0) }.map(String.init).joined(separator: "/")

        var y = margin
        for isDark in [false, true] {
            ContactSheet.text(ctx, "go-runner icon · \(isDark ? "dark" : "light") · 1024/256/128/64/32/16 px "
                              + "(\"\(wordmark)\" at \(withText) px), then 64 px at 4×, 32 and 16 px at 8×",
                              x: margin, baseline: y + 16, size: 13)
            let top = y + label
            ContactSheet.fill(ctx, CGRect(x: 0, y: top, width: totalWidth, height: rowHeight),
                              ContactSheet.color(isDark ? 0x1E1E1EFF : 0xF5F5F7FF))
            var x = margin
            for pixels in native {
                if let image = render(source, pixels: pixels) {
                    draw(image, in: ctx, rect: CGRect(x: x, y: top + (rowHeight - CGFloat(pixels)) / 2,
                                                      width: CGFloat(pixels), height: CGFloat(pixels)))
                }
                x += CGFloat(pixels) + gap
            }
            for (pixels, zoom) in magnified {
                let side = CGFloat(pixels * zoom)
                if let image = render(source, pixels: pixels) {
                    draw(image, in: ctx, rect: CGRect(x: x, y: top + (rowHeight - side) / 2, width: side, height: side))
                }
                x += side + gap
            }
            y += label + rowHeight + gap
        }
        return ctx.makeImage()
    }

    /// Draws an upright image into the y-down preview context, nearest-neighbour.
    static func draw(_ image: CGImage, in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}
