import AppKit
import GoRunnerCore
import XCTest
@testable import RunnerKit

final class SpriteRendererTests: XCTestCase {
    // MARK: render

    func testRenderPixelSizeAndPointSize() throws {
        let frames = try SpriteRenderer.render(Fixtures.sprite(width: 6, frameCount: 3))
        XCTAssertEqual(frames.images.count, 3)
        for image in frames.images {
            XCTAssertEqual(image.width, 12)
            XCTAssertEqual(image.height, 36)
        }
        XCTAssertEqual(frames.pointSize, CGSize(width: 6, height: 18))
        XCTAssertTrue(frames.isTemplate)
        XCTAssertEqual(ImageUtilities.sRGB.name, frames.images[0].colorSpace?.name)
        XCTAssertEqual(frames.images[0].alphaInfo, .premultipliedLast)
    }

    func testFilledAndEmptyCellAlpha() throws {
        let frames = try SpriteRenderer.render(Fixtures.sprite(width: 6, frameCount: 2))
        let image = frames.images[0]
        // Row 0, column 0 is '#': its 2×2 block is opaque.
        for (x, y) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
            XCTAssertEqual(Fixtures.pixel(image, x: x, y: y).a, 255, "(\(x),\(y))")
        }
        // Frame 0 inks column 1 too; column 2 in row 0 and everything in the bottom row are empty.
        XCTAssertEqual(Fixtures.pixel(image, x: 2, y: 0).a, 255)
        XCTAssertEqual(Fixtures.pixel(image, x: 4, y: 0).a, 0)
        XCTAssertEqual(Fixtures.pixel(image, x: 11, y: 35).a, 0)
        XCTAssertEqual(Fixtures.pixel(image, x: 0, y: 2).a, 0)

        // Independent orientation check: NSBitmapImageRep's (0,0) is the top-left pixel.
        let rep = NSBitmapImageRep(cgImage: image)
        XCTAssertEqual(rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(rep.colorAt(x: 0, y: 35)?.alphaComponent ?? 1, 0, accuracy: 0.01)
    }

    func testColorSpriteUsesPaletteWithPremultipliedAlpha() throws {
        var sprite = Fixtures.sprite(isTemplate: false, palette: ["#": 0x3366CCFF])
        var frames = try SpriteRenderer.render(sprite)
        var pixel = Fixtures.pixel(frames.images[0], x: 0, y: 0)
        XCTAssertEqual([pixel.r, pixel.g, pixel.b, pixel.a], [0x33, 0x66, 0xCC, 0xFF])
        XCTAssertFalse(frames.isTemplate)

        sprite.palette = ["#": 0xFF000080]
        frames = try SpriteRenderer.render(sprite)
        pixel = Fixtures.pixel(frames.images[0], x: 0, y: 0)
        XCTAssertEqual(pixel.a, 0x80)
        XCTAssertEqual(Int(pixel.r), 0x80, accuracy: 1) // 255 premultiplied by 128/255
        XCTAssertEqual(pixel.g, 0)
    }

    func testTemplateSpriteDrawsBlackWithPaletteAlpha() throws {
        let sprite = Fixtures.sprite(isTemplate: true, palette: ["#": 0xFF8800CC])
        let frames = try SpriteRenderer.render(sprite)
        let pixel = Fixtures.pixel(frames.images[0], x: 1, y: 1)
        XCTAssertEqual([pixel.r, pixel.g, pixel.b], [0, 0, 0])
        XCTAssertEqual(pixel.a, 0xCC)
    }

    func testFrameOrder() throws {
        let sequential = try SpriteRenderer.render(Fixtures.sprite(frameCount: 3))
        XCTAssertEqual(sequential.order, [0, 1, 2])
        let custom = try SpriteRenderer.render(Fixtures.sprite(frameCount: 3, frameOrder: [0, 1, 2, 1]))
        XCTAssertEqual(custom.order, [0, 1, 2, 1])
        XCTAssertEqual(custom.images.count, 3)
    }

    func testRenderThrowsForInvalidSprite() {
        var sprite = Fixtures.sprite()
        sprite.frames[0].removeLast()
        XCTAssertThrowsError(try SpriteRenderer.render(sprite)) { error in
            guard case RunnerKitError.invalidSprite = error else { return XCTFail("\(error)") }
        }
    }

    func testRendersBuiltInArtCatalogDefault() throws {
        // Not a full RunnerArt audit (another module owns it) — just the default runner.
        let sprite = try XCTUnwrap(RunnerArtTestAccess.first)
        let frames = try SpriteRenderer.render(sprite)
        XCTAssertEqual(frames.images.first?.height, 36)
    }

    // MARK: image(from:) / placeholder

    func testImageFromTemplateFrames() throws {
        let frames = try SpriteRenderer.render(Fixtures.sprite())
        let plain = SpriteRenderer.image(from: frames)
        XCTAssertTrue(plain.isTemplate)
        XCTAssertEqual(plain.size, CGSize(width: 6, height: 18))

        let tinted = SpriteRenderer.image(from: frames, index: 1, tint: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertFalse(tinted.isTemplate)
        XCTAssertEqual(tinted.size, CGSize(width: 6, height: 18))
        let cg = try XCTUnwrap(tinted.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let pixel = Fixtures.pixel(cg, x: 0, y: 0)
        XCTAssertEqual(pixel.a, 255)
        XCTAssertGreaterThan(pixel.r, 200)
        XCTAssertLessThan(pixel.g, 30)
        XCTAssertEqual(Fixtures.pixel(cg, x: 10, y: 30).a, 0)
    }

    func testImageFromColorFramesAndPlaceholder() throws {
        let frames = try SpriteRenderer.render(Fixtures.sprite(isTemplate: false, palette: ["#": 0x00FF00FF]))
        let image = SpriteRenderer.image(from: frames, index: 99)
        XCTAssertFalse(image.isTemplate)
        XCTAssertEqual(image.size, frames.pointSize)

        let placeholder = SpriteRenderer.placeholderImage(size: CGSize(width: 28, height: 18))
        XCTAssertEqual(placeholder.size, CGSize(width: 28, height: 18))
        XCTAssertTrue(placeholder.isValid)
        let cg = try XCTUnwrap(placeholder.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(Fixtures.pixel(cg, x: cg.width / 2, y: cg.height / 2).a, 0)
    }

    // MARK: validate

    func testValidSpriteHasNoProblems() {
        XCTAssertEqual(SpriteRenderer.validate(Fixtures.sprite()), [])
        XCTAssertEqual(SpriteRenderer.validate(Fixtures.sprite(width: 5)), [])
        XCTAssertEqual(SpriteRenderer.validate(Fixtures.sprite(width: 50, frameCount: 30)), [])
    }

    func testTransparentSpriteMayHaveEmptyPalette() {
        var sprite = Fixtures.sprite(palette: [:])
        sprite.frames = sprite.frames.map { $0.map { String(repeating: ".", count: $0.count) } }
        XCTAssertEqual(SpriteRenderer.validate(sprite), [])
    }

    private func assertSingleProblem(_ sprite: PixelSprite, file: StaticString = #filePath, line: UInt = #line) {
        let problems = SpriteRenderer.validate(sprite)
        XCTAssertEqual(problems.count, 1, "\(problems)", file: file, line: line)
        XCTAssertTrue(problems.allSatisfy { $0.contains(sprite.id) }, file: file, line: line)
    }

    func testRowCountNot18() {
        var sprite = Fixtures.sprite()
        sprite.frames[1].removeLast()
        assertSingleProblem(sprite)
        sprite = Fixtures.sprite()
        sprite.frames[0].append(Fixtures.emptyRow)
        assertSingleProblem(sprite)
    }

    func testUnequalWidths() {
        var sprite = Fixtures.sprite()
        sprite.frames[2][5] = "......."
        assertSingleProblem(sprite)
    }

    func testWidthOutOfRange() {
        assertSingleProblem(Fixtures.sprite(width: 4))
        assertSingleProblem(Fixtures.sprite(width: 51))
    }

    func testUnknownCharacters() {
        var sprite = Fixtures.sprite()
        sprite.frames[0][3] = "..x..."
        assertSingleProblem(sprite)
        XCTAssertTrue(SpriteRenderer.validate(sprite)[0].contains("'x'"))
    }

    func testFrameCountOutOfRange() {
        assertSingleProblem(Fixtures.sprite(frameCount: 1))
        assertSingleProblem(Fixtures.sprite(frameCount: 31))
        var empty = Fixtures.sprite()
        empty.frames = []
        assertSingleProblem(empty)
    }

    func testBadFrameOrder() {
        assertSingleProblem(Fixtures.sprite(frameCount: 3, frameOrder: [0, 1, 3]))
        assertSingleProblem(Fixtures.sprite(frameCount: 3, frameOrder: [-1, 0]))
        assertSingleProblem(Fixtures.sprite(frameCount: 3, frameOrder: []))
    }

    func testEmptyPaletteForNonTransparentSprite() {
        assertSingleProblem(Fixtures.sprite(palette: [:]))
    }
}
