import AppKit
import QuartzCore
import GoRunnerCore
import XCTest
@testable import RunnerKit

@MainActor
final class LayerRunnerAnimatorTests: XCTestCase {
    private func templateFrames(width: Int = 28, order: [Int]? = [0, 1, 2, 1]) throws -> RunnerFrames {
        try SpriteRenderer.render(Fixtures.sprite(width: width, frameCount: 3, isTemplate: true, frameOrder: order))
    }

    private func colorFrames() throws -> RunnerFrames {
        try SpriteRenderer.render(Fixtures.sprite(width: 20, frameCount: 5, isTemplate: false, palette: ["#": 0xCC3300FF]))
    }

    private func makeButton(title: String = "", size: CGSize = CGSize(width: 28, height: 18)) -> NSStatusBarButton {
        let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        button.image = SpriteRenderer.placeholderImage(size: size)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageTrailing
        button.title = title
        return button
    }

    private func keyframeAnimation(on layer: CALayer, file: StaticString = #filePath, line: UInt = #line) throws -> CAKeyframeAnimation {
        try XCTUnwrap(layer.animation(forKey: RunnerLayerEngine.animationKey) as? CAKeyframeAnimation, file: file, line: line)
    }

    // MARK: Smoke on a real status item

    func testStatusItemSmoke() throws {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        guard let button = statusItem.button else { throw XCTSkip("no status item button in this environment") }

        let frames = try templateFrames()
        button.image = SpriteRenderer.placeholderImage(size: frames.pointSize)
        let animator = LayerRunnerAnimator()
        animator.attach(to: button)
        animator.setFrames(frames)
        animator.setSpeed(10)

        XCTAssertTrue(button.wantsLayer)
        XCTAssertTrue(animator.engine.containerLayer.superlayer === button.layer)
        let layer = animator.animationLayer
        XCTAssertTrue(layer === animator.engine.maskLayer, "template frames animate the mask")
        XCTAssertTrue(animator.engine.runnerLayer.mask === layer)
        XCTAssertNotNil(animator.engine.runnerLayer.backgroundColor, "template tint is the runner background")

        let animation = try keyframeAnimation(on: layer)
        XCTAssertEqual(animation.keyPath, "contents")
        XCTAssertEqual(animation.values?.count, frames.order.count)
        XCTAssertEqual(animation.duration, Double(frames.order.count) * 0.5, accuracy: 1e-9)
        XCTAssertEqual(animation.calculationMode, .discrete)
        XCTAssertEqual(animation.repeatCount, .infinity)
        XCTAssertFalse(animation.isRemovedOnCompletion)
        XCTAssertEqual(layer.speed, 10)

        animator.setPaused(true)
        XCTAssertEqual(layer.speed, 0)
        XCTAssertEqual(layer.timeOffset, 0)
        XCTAssertTrue(animator.isPaused)

        animator.setPaused(false)
        XCTAssertEqual(layer.speed, 10)
        animator.detach()
        XCTAssertNil(animator.engine.containerLayer.superlayer)
    }

    // MARK: Plain NSStatusBarButton

    func testColorFramesAnimateRunnerLayerWithoutMask() throws {
        let button = makeButton(size: CGSize(width: 20, height: 18))
        let animator = LayerRunnerAnimator()
        animator.attach(to: button)
        let frames = try colorFrames()
        animator.setFrames(frames)
        animator.setSpeed(3)

        let engine = animator.engine
        XCTAssertTrue(animator.animationLayer === engine.runnerLayer)
        XCTAssertNil(engine.runnerLayer.mask)
        XCTAssertNil(engine.runnerLayer.backgroundColor)
        XCTAssertNil(engine.maskLayer.animation(forKey: RunnerLayerEngine.animationKey))
        let animation = try keyframeAnimation(on: engine.runnerLayer)
        XCTAssertEqual(animation.values?.count, 5)
        XCTAssertEqual(animation.duration, 2.5, accuracy: 1e-9)
        XCTAssertEqual(engine.runnerLayer.speed, 3)
        XCTAssertEqual(engine.runnerLayer.masksToBounds, true)
        // The engine follows the backing scale of the screen the status item is on (1× or 2× monitors).
        let expectedScale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        XCTAssertEqual(engine.runnerLayer.contentsScale, expectedScale)
    }

    func testSwitchingFramesPreservesSpeedAndPause() throws {
        let animator = LayerRunnerAnimator()
        animator.attach(to: makeButton())
        animator.setFrames(try templateFrames())
        animator.setSpeed(4)
        XCTAssertEqual(animator.engine.maskLayer.speed, 4)

        animator.setFrames(try colorFrames())
        XCTAssertEqual(animator.engine.runnerLayer.speed, 4)
        XCTAssertEqual(animator.engine.maskLayer.speed, 1, "the non-carrier layer is reset")
        XCTAssertNil(animator.engine.maskLayer.animation(forKey: RunnerLayerEngine.animationKey))

        animator.setPaused(true)
        animator.setFrames(try templateFrames())
        XCTAssertEqual(animator.engine.maskLayer.speed, 0)
        XCTAssertEqual(animator.engine.runnerLayer.speed, 1)

        animator.setSpeed(12) // remembered while paused
        XCTAssertEqual(animator.engine.maskLayer.speed, 0)
        animator.setPaused(false)
        XCTAssertEqual(animator.engine.maskLayer.speed, 12)
    }

    func testSpeedChangeIsPhaseContinuous() throws {
        let animator = LayerRunnerAnimator()
        animator.attach(to: makeButton())
        animator.setFrames(try templateFrames())
        animator.setSpeed(2)
        let layer = animator.animationLayer
        let before = layer.convertTime(CACurrentMediaTime(), from: nil)
        animator.setSpeed(15)
        let after = layer.convertTime(CACurrentMediaTime(), from: nil)
        XCTAssertEqual(after, before, accuracy: 0.05)
        XCTAssertEqual(layer.speed, 15)
    }

    func testPausedShowsFirstFrameInOrder() throws {
        let animator = LayerRunnerAnimator()
        animator.attach(to: makeButton())
        let frames = try templateFrames(order: [2, 0, 1])
        animator.setFrames(frames)
        animator.setPaused(true)
        let layer = animator.animationLayer
        XCTAssertEqual(layer.convertTime(CACurrentMediaTime(), from: nil), 0)
        let animation = try keyframeAnimation(on: layer)
        XCTAssertGreaterThan(animation.beginTime, 0)
        XCTAssertTrue((animation.values?.first as AnyObject?) === frames.images[2])
        XCTAssertTrue((layer.contents as AnyObject?) === frames.images[2], "model value is the first frame in order")
    }

    func testRelayoutPlacesRunnerOnImageRect() throws {
        let button = makeButton(title: "12.5%")
        let animator = LayerRunnerAnimator()
        animator.attach(to: button)
        animator.setFrames(try templateFrames(width: 28))

        let imageRect = try XCTUnwrap(button.cell?.imageRect(forBounds: button.bounds))
        let frame = animator.engine.containerLayer.frame
        XCTAssertEqual(frame.size, CGSize(width: 28, height: 18))
        XCTAssertEqual(frame.midX, imageRect.midX, accuracy: 0.5)
        XCTAssertEqual(frame.minY, 2, accuracy: 0.01, "18 pt runner centered in a 22 pt bar")
        XCTAssertEqual(animator.engine.runnerLayer.frame, CGRect(x: 0, y: 0, width: 28, height: 18))
        XCTAssertEqual(animator.engine.maskLayer.frame, CGRect(x: 0, y: 0, width: 28, height: 18))

        // Frame change notifications trigger relayout.
        button.frame = NSRect(x: 0, y: 0, width: 120, height: 22)
        let moved = try XCTUnwrap(button.cell?.imageRect(forBounds: button.bounds))
        XCTAssertEqual(animator.engine.containerLayer.frame.midX, moved.midX, accuracy: 0.5)
    }

    func testRunnerRectConvertsFlippedCoordinates() {
        let bounds = CGRect(x: 0, y: 0, width: 60, height: 22)
        let imageRect = CGRect(x: 24, y: 0, width: 28, height: 18)
        let same = RunnerLayerEngine.runnerRect(imageRect: imageRect, bounds: bounds, size: CGSize(width: 28, height: 18),
                                                viewIsFlipped: true, layerIsFlipped: true, scale: 2)
        let mismatched = RunnerLayerEngine.runnerRect(imageRect: imageRect, bounds: bounds, size: CGSize(width: 28, height: 18),
                                                      viewIsFlipped: true, layerIsFlipped: false, scale: 2)
        XCTAssertEqual(same, CGRect(x: 24, y: 2, width: 28, height: 18))
        XCTAssertEqual(mismatched, CGRect(x: 24, y: 2, width: 28, height: 18))
        let empty = RunnerLayerEngine.runnerRect(imageRect: .zero, bounds: bounds, size: CGSize(width: 20, height: 18),
                                                 viewIsFlipped: false, layerIsFlipped: false, scale: 2)
        XCTAssertEqual(empty, CGRect(x: 20, y: 2, width: 20, height: 18))
    }

    func testFlipMirrorsContainerAroundItsCenter() throws {
        let animator = LayerRunnerAnimator()
        animator.attach(to: makeButton())
        animator.setFrames(try templateFrames())
        let unflipped = animator.engine.containerLayer.frame
        animator.setFlipped(true)
        let container = animator.engine.containerLayer
        XCTAssertEqual(container.transform.m11, -1)
        XCTAssertEqual(container.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(container.frame, unflipped)
        animator.relayout()
        XCTAssertEqual(container.transform.m11, -1, "relayout keeps the flip")
        animator.setFlipped(false)
        XCTAssertTrue(CATransform3DIsIdentity(container.transform))
    }

    func testTintFollowsAppearanceAndExplicitColor() throws {
        let button = makeButton()
        let animator = LayerRunnerAnimator()
        animator.attach(to: button)
        animator.setFrames(try templateFrames())

        func red() throws -> CGFloat {
            let color = try XCTUnwrap(animator.engine.runnerLayer.backgroundColor)
            let srgb = try XCTUnwrap(color.converted(to: ImageUtilities.sRGB, intent: .defaultIntent, options: nil))
            return try XCTUnwrap(srgb.components?.first)
        }

        button.appearance = NSAppearance(named: .darkAqua)
        animator.setTint(nil)
        XCTAssertGreaterThan(try red(), 0.5, "label color on a dark menu bar is light")

        button.appearance = NSAppearance(named: .aqua) // KVO on effectiveAppearance re-resolves
        XCTAssertLessThan(try red(), 0.5, "label color on a light menu bar is dark")

        animator.setTint(NSColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1))
        XCTAssertEqual(try red(), 0, accuracy: 0.01)

        animator.setFrames(try colorFrames())
        XCTAssertNil(animator.engine.runnerLayer.backgroundColor, "color frames are never tinted")
    }

    func testSetFramesBeforeAttachInstallsOnAttach() throws {
        let animator = LayerRunnerAnimator()
        animator.setFrames(try colorFrames())
        animator.setSpeed(5)
        let button = makeButton(size: CGSize(width: 20, height: 18))
        animator.attach(to: button)
        XCTAssertTrue(animator.engine.containerLayer.superlayer === button.layer)
        XCTAssertEqual(try keyframeAnimation(on: animator.engine.runnerLayer).values?.count, 5)
        XCTAssertEqual(animator.engine.runnerLayer.speed, 5)
        XCTAssertEqual(animator.engine.containerLayer.frame.size, CGSize(width: 20, height: 18))
    }
}
