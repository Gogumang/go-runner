import GoRunnerCore
import XCTest
@testable import RunnerArt

final class RunnerArtCatalogTests: XCTestCase {
    private let sprites = RunnerArtCatalog.all

    func testCatalogContainsTheBuiltInRunnersWithClawdFirst() {
        XCTAssertEqual(sprites.first?.id, "clawd")
        XCTAssertEqual(sprites.count, 7)
        XCTAssertEqual(sprites.map(\.id), [
            "clawd", "codex", "kodee", "gopher", "tux", "kiro", "grok",
        ])
    }

    /// Brand runners added at the user's request (personal build): same flags as Clawd, Critter-size footprint.
    func testRequestedBrandRunnersArePersonalUseAndCritterSize() throws {
        for id in ["codex", "kiro", "grok"] {
            let sprite = try XCTUnwrap(sprites.first(where: { $0.id == id }), id)
            XCTAssertTrue(sprite.isBrandInspired, id)
            XCTAssertFalse(sprite.isTemplate, id)
            XCTAssertEqual(Set(sprite.tags), ["personal-only", "brand-exact"], id)
            XCTAssertFalse(sprite.credit?.isEmpty ?? true, id)
            XCTAssertNotEqual(sprite.license, "Original", id)
            XCTAssertLessThanOrEqual(sprite.frames.first?.first?.count ?? 0, 24, id)
            XCTAssertFalse(sprite.names["ko", default: ""].isEmpty, id)
        }
    }

    func testIdsAreUnique() {
        let ids = sprites.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate ids: \(ids)")
    }

    func testNamesHaveKoreanAndEnglish() {
        for sprite in sprites {
            XCTAssertFalse(sprite.names["ko", default: ""].isEmpty, sprite.id)
            XCTAssertFalse(sprite.names["en", default: ""].isEmpty, sprite.id)
        }
    }

    func testFrameCountIsWithinLimits() {
        for sprite in sprites {
            XCTAssertTrue((2...30).contains(sprite.frames.count), "\(sprite.id): \(sprite.frames.count) frames")
        }
    }

    func testEveryFrameHasEighteenRows() {
        for sprite in sprites {
            for (index, frame) in sprite.frames.enumerated() {
                XCTAssertEqual(frame.count, PixelSprite.rows, "\(sprite.id) frame \(index)")
            }
        }
    }

    func testWidthsAreIdenticalAndInRange() {
        for sprite in sprites {
            guard let width = sprite.frames.first?.first?.count else {
                XCTFail("\(sprite.id) has no rows")
                continue
            }
            XCTAssertTrue(PixelSprite.widthRange.contains(width), "\(sprite.id): width \(width)")
            for (index, frame) in sprite.frames.enumerated() {
                for (row, line) in frame.enumerated() {
                    XCTAssertEqual(line.count, width, "\(sprite.id) frame \(index) row \(row)")
                }
            }
        }
    }

    func testEveryCellIsTransparentOrInPalette() {
        for sprite in sprites {
            XCTAssertNil(sprite.palette["."], "\(sprite.id): '.' is reserved for transparency")
            for (index, frame) in sprite.frames.enumerated() {
                for line in frame {
                    for cell in line where cell != "." {
                        XCTAssertNotNil(sprite.palette[cell], "\(sprite.id) frame \(index): '\(cell)' not in palette")
                    }
                }
            }
        }
    }

    func testTemplateSpritesUseBlackWithAlphaOnly() {
        for sprite in sprites where sprite.isTemplate {
            for (key, value) in sprite.palette {
                XCTAssertEqual(value >> 8, 0, "\(sprite.id): '\(key)' should be black (alpha-only)")
                XCTAssertGreaterThan(value & 0xFF, 0, "\(sprite.id): '\(key)' is fully transparent")
            }
        }
    }

    func testFrameOrderIndicesAreValid() {
        for sprite in sprites {
            guard let order = sprite.frameOrder else { continue }
            XCTAssertFalse(order.isEmpty, sprite.id)
            for index in order {
                XCTAssertTrue(sprite.frames.indices.contains(index), "\(sprite.id): order index \(index)")
            }
        }
    }

    func testEachFrameIsAtLeastEightPercentFilled() {
        for sprite in sprites {
            for (index, frame) in sprite.frames.enumerated() {
                let total = frame.reduce(0) { $0 + $1.count }
                let filled = frame.reduce(0) { $0 + $1.filter { $0 != "." }.count }
                XCTAssertGreaterThanOrEqual(Double(filled) / Double(max(total, 1)), 0.08,
                                            "\(sprite.id) frame \(index): \(filled)/\(total) cells filled")
            }
        }
    }

    func testBottomRowIsReachedInSomeFrame() {
        for sprite in sprites {
            let touches = sprite.frames.contains { frame in
                frame.last?.contains { $0 != "." } ?? false
            }
            XCTAssertTrue(touches, "\(sprite.id): no frame touches the ground row")
        }
    }

    func testConsecutiveFramesDiffer() {
        for sprite in sprites {
            for index in sprite.frames.indices.dropLast() {
                XCTAssertNotEqual(sprite.frames[index], sprite.frames[index + 1], "\(sprite.id) frames \(index)/\(index + 1)")
            }
            let order = sprite.frameOrder ?? Array(sprite.frames.indices)
            for (position, index) in order.enumerated() {
                let next = order[(position + 1) % order.count]
                if order.count > 1 {
                    XCTAssertNotEqual(sprite.frames[index], sprite.frames[next], "\(sprite.id) playback \(index)→\(next)")
                }
            }
        }
    }

    func testAdaptationsCarryCreditAndLicense() {
        let expected = ["kodee": "CC-BY-4.0", "gopher": "CC-BY-4.0", "tux": "Tux-permissive"]
        for (id, license) in expected {
            guard let sprite = sprites.first(where: { $0.id == id }) else {
                XCTFail("missing \(id)")
                continue
            }
            XCTAssertFalse(sprite.credit?.isEmpty ?? true, "\(id) needs a credit")
            XCTAssertFalse(sprite.license.isEmpty, "\(id) needs a license")
            XCTAssertEqual(sprite.license, license, id)
            XCTAssertFalse(sprite.isBrandInspired, id)
        }
    }

    func testClawdIsFlaggedAsPersonalUseBrandArt() throws {
        let clawd = try XCTUnwrap(sprites.first(where: { $0.id == "clawd" }))
        XCTAssertTrue(clawd.isBrandInspired)
        XCTAssertFalse(clawd.isTemplate)
        XCTAssertFalse(clawd.credit?.isEmpty ?? true)
        XCTAssertFalse(clawd.license.isEmpty)
        XCTAssertNotEqual(clawd.license, "Original")
        XCTAssertEqual(Set(clawd.tags), ["personal-only", "brand-exact"])
        XCTAssertEqual(clawd.names["ko"], "클로드")
        XCTAssertEqual(clawd.names["en"], "Clawd")
    }

    /// The user asked for Clawd between the flat and the tall drafts: slightly wider than tall, a foot on the ground.
    func testClawdIsSlightlyWiderThanTallAndKeepsAFootDown() throws {
        let clawd = try XCTUnwrap(sprites.first(where: { $0.id == "clawd" }))
        let width = clawd.frames.first?.first?.count ?? 0
        XCTAssertTrue((18...20).contains(width), "clawd canvas width \(width)")
        for (index, frame) in clawd.frames.enumerated() {
            let occupied = frame.indices.filter { row in frame[row].contains { $0 != "." } }
            let columns = (0..<width).filter { column in
                frame.contains { row in row[row.index(row.startIndex, offsetBy: column)] != "." }
            }
            guard let top = occupied.first, let bottom = occupied.last,
                  let left = columns.first, let right = columns.last else {
                XCTFail("clawd frame \(index) is empty")
                continue
            }
            let height = bottom - top + 1
            XCTAssertTrue((12...14).contains(height), "clawd frame \(index): character height \(height)")
            XCTAssertGreaterThanOrEqual(right - left + 1, height, "clawd frame \(index) should be at least as wide as tall")
            XCTAssertEqual(bottom, PixelSprite.rows - 1, "clawd frame \(index): walking keeps a foot on the ground")
        }
    }

    /// The Terminal runner (the only template sprite) was removed at the user's request; every built-in keeps its colors.
    func testTemplateFlags() {
        let templates = Set(sprites.filter(\.isTemplate).map(\.id))
        XCTAssertEqual(templates, [])
    }
}
