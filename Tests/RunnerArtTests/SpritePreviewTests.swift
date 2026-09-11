import CoreGraphics
import CoreText
import Foundation
import ImageIO
import GoRunnerCore
import UniformTypeIdentifiers
import XCTest
@testable import RunnerArt

/// Renders a PNG contact sheet per built-in sprite for visual review (CoreGraphics only, no RunnerKit).
///
/// Opt-in: `GORUNNER_PREVIEW=1 swift test --filter SpritePreviewTests`
/// Output: `build/sprite-previews/<id>.png` and `build/sprite-previews/_overview.png`.
final class SpritePreviewTests: XCTestCase {
    func testRenderContactSheets() throws {
        guard ProcessInfo.processInfo.environment["GORUNNER_PREVIEW"] == "1" else {
            throw XCTSkip("Set GORUNNER_PREVIEW=1 to render sprite previews into build/sprite-previews/")
        }
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let outputDirectory = ProcessInfo.processInfo.environment["GORUNNER_PREVIEW_DIR"].map { URL(fileURLWithPath: $0) }
            ?? packageRoot.appendingPathComponent("build/sprite-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for sprite in RunnerArtCatalog.all {
            let sheet = try XCTUnwrap(ContactSheet.render(sprite), sprite.id)
            try ContactSheet.writePNG(sheet, to: outputDirectory.appendingPathComponent("\(sprite.id).png"))
        }
        let overview = try XCTUnwrap(ContactSheet.renderOverview(RunnerArtCatalog.all))
        try ContactSheet.writePNG(overview, to: outputDirectory.appendingPathComponent("_overview.png"))
    }
}

/// Shared with per-sprite preview tests: `ContactSheet.render(sprite)`, `.renderOverview`, `.writePNG`.
enum ContactSheet {
    struct WriteError: Error { let url: URL }

    static let light: UInt32 = 0xECECECFF
    static let dark: UInt32 = 0x1E1E1EFF
    static let page: UInt32 = 0xFAFAFAFF
    static let margin: CGFloat = 16
    static let gap: CGFloat = 12
    static let label: CGFloat = 22

    // MARK: Sheets

    /// (a) frames at 10× on light, (b) on dark, (c) actual 2× pixel size on both, (d) frameOrder strip at 4×.
    static func render(_ sprite: PixelSprite) -> CGImage? {
        guard let width = sprite.frames.first?.first?.count else { return nil }
        let rows = CGFloat(PixelSprite.rows)
        let count = sprite.frames.count
        let order = sprite.frameOrder ?? Array(sprite.frames.indices)

        let big: CGFloat = 10, stripCell: CGFloat = 4, actual = CGFloat(PixelSprite.pixelsPerCell)
        let bigW = CGFloat(width) * big
        let rowA = CGFloat(count) * (bigW + gap) - gap
        let menuBar: CGFloat = 44 // 22 pt menu bar at @2x
        let actualStrip = CGFloat(count) * (CGFloat(width) * actual + 8) + 8
        let rowC = actualStrip * 2 + gap
        let stripW = CGFloat(width) * stripCell
        let rowD = CGFloat(order.count) * (stripW + 4) - 4
        let contentW = max(rowA, rowC, rowD, 520)
        let totalW = margin * 2 + contentW
        let totalH = margin + label + (label + rows * big + gap) * 2 + (label + menuBar + gap)
            + (label + (rows * stripCell) * 2 + 4 + gap) + margin

        guard let ctx = makeContext(width: Int(totalW), height: Int(totalH)) else { return nil }
        fill(ctx, CGRect(x: 0, y: 0, width: totalW, height: totalH), color(page))

        var y = margin
        let mode = sprite.isTemplate ? "template" : "color"
        text(ctx, "\(sprite.id) — \(sprite.names["en"] ?? "") · \(mode) · \(count) frames · \(width)×18 · order \(order)",
             x: margin, baseline: y + 14, size: 13)
        y += label

        for isDark in [false, true] {
            text(ctx, isDark ? "(b) 10× on dark #1E1E1E" : "(a) 10× on light #ECECEC", x: margin, baseline: y + 14)
            for index in 0..<count {
                let x = margin + CGFloat(index) * (bigW + gap)
                text(ctx, "f\(index)", x: x + bigW - 22, baseline: y + 14, size: 11)
                drawFrame(ctx, sprite, sprite.frames[index], at: CGPoint(x: x, y: y + label), cell: big,
                          dark: isDark, grid: true)
            }
            y += label + rows * big + gap
        }

        text(ctx, "(c) actual size (2 px per cell, 36 px tall) in a 44 px menu bar", x: margin, baseline: y + 14)
        for (strip, isDark) in [false, true].enumerated() {
            let originX = margin + CGFloat(strip) * (actualStrip + gap)
            fill(ctx, CGRect(x: originX, y: y + label, width: actualStrip, height: menuBar), color(isDark ? dark : light))
            for index in 0..<count {
                let x = originX + 8 + CGFloat(index) * (CGFloat(width) * actual + 8)
                drawFrame(ctx, sprite, sprite.frames[index], at: CGPoint(x: x, y: y + label + 4), cell: actual,
                          dark: isDark, grid: false, background: false)
            }
        }
        y += label + menuBar + gap

        text(ctx, "(d) animation strip in playback order at 4×", x: margin, baseline: y + 14)
        for (line, isDark) in [false, true].enumerated() {
            let lineY = y + label + CGFloat(line) * (rows * stripCell + 4)
            for (position, index) in order.enumerated() {
                let x = margin + CGFloat(position) * (stripW + 4)
                drawFrame(ctx, sprite, sprite.frames[index], at: CGPoint(x: x, y: lineY), cell: stripCell,
                          dark: isDark, grid: false)
            }
        }
        return ctx.makeImage()
    }

    /// Every runner's first frames at actual size and 4×, on light and dark bars, to compare scale and weight.
    static func renderOverview(_ sprites: [PixelSprite]) -> CGImage? {
        let actual = CGFloat(PixelSprite.pixelsPerCell), cell: CGFloat = 4, rows = CGFloat(PixelSprite.rows)
        let rowH = rows * cell + 16
        let widest = CGFloat(sprites.compactMap { $0.frames.first?.first?.count }.max() ?? 28)
        let totalW = 150 + 2 * (widest * actual * 3 + 44) + 2 * (widest * cell + 8) + margin
        let totalH = margin * 2 + CGFloat(sprites.count) * rowH
        guard let ctx = makeContext(width: Int(totalW), height: Int(totalH)) else { return nil }
        fill(ctx, CGRect(x: 0, y: 0, width: totalW, height: totalH), color(page))
        for (line, sprite) in sprites.enumerated() {
            guard let width = sprite.frames.first?.first?.count else { continue }
            let y = margin + CGFloat(line) * rowH
            text(ctx, sprite.names["en"] ?? sprite.id, x: margin, baseline: y + 14, size: 12)
            var x: CGFloat = 150
            for isDark in [false, true] {
                fill(ctx, CGRect(x: x, y: y, width: CGFloat(width) * actual * 3 + 32, height: rows * cell),
                     color(isDark ? dark : light))
                for index in 0..<min(3, sprite.frames.count) {
                    drawFrame(ctx, sprite, sprite.frames[index],
                              at: CGPoint(x: x + 8 + CGFloat(index) * (CGFloat(width) * actual + 8), y: y + 18),
                              cell: actual, dark: isDark, grid: false, background: false)
                }
                x += CGFloat(width) * actual * 3 + 44
            }
            for isDark in [false, true] {
                drawFrame(ctx, sprite, sprite.frames[0], at: CGPoint(x: x, y: y), cell: cell, dark: isDark, grid: false)
                x += CGFloat(width) * cell + 8
            }
        }
        return ctx.makeImage()
    }

    // MARK: Drawing

    static func drawFrame(_ ctx: CGContext, _ sprite: PixelSprite, _ frame: [String], at origin: CGPoint, cell: CGFloat,
                          dark isDark: Bool, grid: Bool, background: Bool = true) {
        let width = frame.first?.count ?? 0
        let size = CGSize(width: CGFloat(width) * cell, height: CGFloat(PixelSprite.rows) * cell)
        if background {
            fill(ctx, CGRect(origin: origin, size: size), color(isDark ? dark : light))
        }
        for (row, line) in frame.enumerated() {
            for (column, character) in line.enumerated() {
                guard let cellColor = color(for: character, in: sprite, dark: isDark) else { continue }
                fill(ctx, CGRect(x: origin.x + CGFloat(column) * cell, y: origin.y + CGFloat(row) * cell,
                                 width: cell, height: cell), cellColor)
            }
        }
        guard grid else { return }
        let gridColor = CGColor(gray: isDark ? 1 : 0, alpha: 0.09)
        for column in 0...width {
            fill(ctx, CGRect(x: origin.x + CGFloat(column) * cell, y: origin.y, width: 1, height: size.height), gridColor)
        }
        for row in 0...PixelSprite.rows {
            fill(ctx, CGRect(x: origin.x, y: origin.y + CGFloat(row) * cell, width: size.width, height: 1), gridColor)
        }
        // Ground line under row 17 and the horizontal center, to check contact and anchoring.
        fill(ctx, CGRect(x: origin.x, y: origin.y + size.height - 1, width: size.width, height: 2),
             CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 0.6))
        fill(ctx, CGRect(x: origin.x + (size.width / 2).rounded(.down), y: origin.y, width: 1, height: size.height),
             CGColor(srgbRed: 0.2, green: 0.5, blue: 1, alpha: 0.35))
    }

    static func color(for character: Character, in sprite: PixelSprite, dark isDark: Bool) -> CGColor? {
        guard character != "." else { return nil }
        guard let value = sprite.palette[character] else { return CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1) }
        if sprite.isTemplate {
            // Template images are tinted with the menu bar text color: black on light, white on dark.
            return CGColor(gray: isDark ? 1 : 0, alpha: CGFloat(value & 0xFF) / 255)
        }
        return color(value)
    }

    static func color(_ rgba: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }

    static func fill(_ ctx: CGContext, _ rect: CGRect, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.fill(rect)
    }

    static func text(_ ctx: CGContext, _ string: String, x: CGFloat, baseline: CGFloat, size: CGFloat = 12) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        ctx.saveGState()
        ctx.translateBy(x: x, y: baseline)
        ctx.scaleBy(x: 1, y: -1) // the context is flipped (y down); flip text back upright
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// A y-down sRGB bitmap context.
    static func makeContext(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        return ctx
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw WriteError(url: url) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WriteError(url: url) }
    }
}
