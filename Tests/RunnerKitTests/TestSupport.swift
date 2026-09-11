import AppKit
import GoRunnerCore
import XCTest
@testable import RunnerKit

/// Runtime-built fixtures (no SwiftPM resources).
enum Fixtures {
    // MARK: Sprites

    static let emptyRow = String(repeating: ".", count: 6)

    /// 6×18 cells; frame i has one ink cell at (row 0, column i % 6) and the top-left cell always filled.
    static func sprite(id: String = "test.sprite", names: [String: String]? = nil, width: Int = 6, frameCount: Int = 3,
                       isTemplate: Bool = true, palette: [Character: UInt32] = ["#": 0x000000FF],
                       frameOrder: [Int]? = nil) -> PixelSprite {
        let frames: [[String]] = (0..<frameCount).map { frame in
            (0..<PixelSprite.rows).map { row in
                guard row == 0 else { return String(repeating: ".", count: width) }
                var cells = Array(repeating: Character("."), count: width)
                cells[0] = "#"
                cells[(frame % (width - 1)) + 1] = "#"
                return String(cells)
            }
        }
        return PixelSprite(id: id, names: names ?? ["ko": id, "en": id], palette: palette, frames: frames,
                           frameOrder: frameOrder, isTemplate: isTemplate)
    }

    /// Premultiplied RGBA at pixel (x, y), y = 0 is the top row.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let pixels = ImageUtilities.rgbaPixels(of: image)!
        let offset = (y * image.width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }
}

func XCTAssertNotFound(_ expression: @autoclosure () throws -> some Any, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        guard case RunnerKitError.notFound = error else {
            return XCTFail("expected notFound, got \(error)", file: file, line: line)
        }
    }
}
