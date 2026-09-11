import GoRunnerCore
import RunnerArt
import XCTest
@testable import RunnerKit

enum RunnerArtTestAccess {
    static var all: [PixelSprite] { RunnerArtCatalog.all }
    static var first: PixelSprite? { RunnerArtCatalog.all.first }
}

final class RunnerCatalogTests: XCTestCase {
    private var testSprites: [PixelSprite] {
        [
            Fixtures.sprite(id: "test.zeta", names: ["ko": "제타", "en": "Zeta"], isTemplate: true),
            Fixtures.sprite(id: "test.alpha", names: ["ko": "알파", "en": "Alpha"], isTemplate: false,
                            palette: ["#": 0x336699FF], frameOrder: [0, 1, 2, 1]),
        ]
    }

    func testBuiltInsListedInGivenOrder() {
        let builtIns = RunnerArtTestAccess.all + testSprites
        let catalog = RunnerCatalog(builtIns: builtIns)
        let runners = catalog.allRunners()
        XCTAssertEqual(runners.map(\.id), builtIns.map(\.id))
        for runner in runners {
            XCTAssertEqual(runner.source, .builtIn)
        }
    }

    func testBuiltInDescriptorFields() throws {
        let catalog = RunnerCatalog(builtIns: testSprites)
        let alpha = try XCTUnwrap(catalog.allRunners().first { $0.id == "test.alpha" })
        XCTAssertEqual(alpha.frameCount, 3)
        XCTAssertFalse(alpha.isTemplate)
        XCTAssertEqual(alpha.license, "Original")
        XCTAssertEqual(alpha.displayName, Loc.isKorean ? "알파" : "Alpha")
    }

    func testDuplicateBuiltInIdsKeepFirst() {
        let catalog = RunnerCatalog(builtIns: testSprites + [Fixtures.sprite(id: "test.zeta")])
        XCTAssertEqual(catalog.allRunners().map(\.id), ["test.zeta", "test.alpha"])
    }

    func testFramesForBuiltInsAreRenderedAndCached() throws {
        let defaultRunner = try XCTUnwrap(RunnerArtTestAccess.first)
        let catalog = RunnerCatalog(builtIns: [defaultRunner] + testSprites)

        let art = try catalog.frames(for: defaultRunner.id)
        XCTAssertEqual(art.images.count, defaultRunner.frames.count)
        XCTAssertEqual(art.images.first?.height, 36)
        XCTAssertEqual(art.isTemplate, defaultRunner.isTemplate)

        let alpha = try catalog.frames(for: "test.alpha")
        XCTAssertEqual(alpha.order, [0, 1, 2, 1])
        XCTAssertEqual(alpha.pointSize, CGSize(width: 6, height: 18))
        XCTAssertFalse(alpha.isTemplate)

        let again = try catalog.frames(for: "test.alpha")
        XCTAssertTrue(again.images[0] === alpha.images[0], "frames should be cached by id")
    }

    func testFramesForUnknownIdThrowsNotFound() {
        let catalog = RunnerCatalog(builtIns: testSprites)
        XCTAssertNotFound(try catalog.frames(for: "nope"))
        XCTAssertNotFound(try catalog.frames(for: "../etc"))
    }

    func testFramesForInvalidBuiltInThrowsInvalidSprite() {
        var broken = Fixtures.sprite(id: "test.broken")
        broken.frames[0].removeLast()
        let catalog = RunnerCatalog(builtIns: [broken])
        XCTAssertEqual(catalog.allRunners().count, 1)
        XCTAssertThrowsError(try catalog.frames(for: "test.broken")) { error in
            guard case RunnerKitError.invalidSprite = error else { return XCTFail("\(error)") }
        }
    }
}
