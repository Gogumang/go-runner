import AppKit
import GoRunnerCore

// FACADE — the public API below is a contract used by GoRunnerApp. Keep these signatures; add more if needed.
// Implementations: SpriteRasterizer.swift, RunnerLayerEngine.swift.

public enum RunnerKitError: Error, Equatable, LocalizedError {
    case notImplemented
    case invalidSprite(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented: "Not implemented"
        case .invalidSprite(let reason): reason
        case .notFound(let id): Loc.t("러너를 찾을 수 없습니다: \(id)", "Runner not found: \(id)")
        }
    }
}

public enum SpriteRenderer {
    /// Renders a pixel sprite into 36 px tall frames (2×2 px per cell).
    /// `pointSize` is `(width cells, 18)`; `order` is `frameOrder ?? 0..<frames.count`. Throws `invalidSprite`.
    public static func render(_ sprite: PixelSprite) throws -> RunnerFrames {
        try SpriteRasterizer.render(sprite)
    }

    /// Returns human-readable problems (empty = valid).
    public static func validate(_ sprite: PixelSprite) -> [String] {
        SpriteRasterizer.problems(in: sprite)
    }

    /// One frame (`index` into `frames.images`, clamped) as an NSImage sized in points (18 pt tall).
    /// Template frames: `isTemplate = true` when `tint` is nil, otherwise filled with `tint`. Color frames: as-is.
    public static func image(from frames: RunnerFrames, index: Int = 0, tint: NSColor? = nil) -> NSImage {
        SpriteRasterizer.image(from: frames, index: index, tint: tint)
    }

    /// Transparent image used as `button.image` so AppKit reserves room for the runner layer.
    public static func placeholderImage(size: CGSize) -> NSImage {
        SpriteRasterizer.placeholderImage(size: size)
    }
}

/// Built-in pixel sprites (`RunnerArtCatalog.all`), rendered on demand.
public final class RunnerCatalog: RunnerCatalogProviding {
    private let builtIns: [PixelSprite]
    private let builtInIndex: [String: Int]
    private let lock = NSLock()
    private var cache: [String: RunnerFrames] = [:]

    /// Duplicate ids keep the first sprite.
    public init(builtIns: [PixelSprite]) {
        var unique: [PixelSprite] = []
        var index: [String: Int] = [:]
        for sprite in builtIns where index[sprite.id] == nil {
            index[sprite.id] = unique.count
            unique.append(sprite)
        }
        self.builtIns = unique
        self.builtInIndex = index
    }

    /// Built-ins in init order.
    public func allRunners() -> [RunnerDescriptor] {
        builtIns.map { sprite in
            RunnerDescriptor(id: sprite.id, displayName: sprite.displayName, isTemplate: sprite.isTemplate,
                             frameCount: sprite.frames.count, credit: sprite.credit, license: sprite.license,
                             isBrandInspired: sprite.isBrandInspired, source: .builtIn)
        }
    }

    /// Rendered frames, cached by id. Throws `notFound` for unknown ids and `invalidSprite` for broken sprites.
    public func frames(for id: String) throws -> RunnerFrames {
        if let cached = lock.withLock({ cache[id] }) { return cached }
        guard let index = builtInIndex[id] else { throw RunnerKitError.notFound(id) }
        let frames = try SpriteRasterizer.render(builtIns[index])
        lock.withLock { cache[id] = frames }
        return frames
    }
}

/// Energy-efficient runner animation: a `CAKeyframeAnimation` on a layer inside the status bar button
/// (RunCat Neo technique) instead of per-frame `button.image` swaps.
///
/// Integration order: `attach(to:)` → `setFrames(_:)` (after setting `button.image` to
/// `SpriteRenderer.placeholderImage(size: frames.pointSize)`) → `setSpeed(_:)` on every sample.
/// Call `relayout()` after changing the button's title, `imagePosition` or length.
@MainActor
public final class LayerRunnerAnimator: RunnerAnimating {
    let engine = RunnerLayerEngine()

    public init() {}

    public func attach(to button: NSStatusBarButton) { engine.attach(to: button) }
    public func setFrames(_ frames: RunnerFrames) { engine.setFrames(frames) }
    public func setSpeed(_ speed: Double) { engine.setSpeed(speed) }
    public func setPaused(_ paused: Bool) { engine.setPaused(paused) }
    public func setFlipped(_ flipped: Bool) { engine.setFlipped(flipped) }
    public func setTint(_ color: NSColor?) { engine.setTint(color) }
    public func relayout() { engine.relayout() }

    /// Removes the runner layer and observers from the button (also happens on deinit).
    public func detach() { engine.detach() }

    /// Current state, for settings UI and diagnostics.
    public var speed: Double { engine.speed }
    public var isPaused: Bool { engine.isPaused }
    public var isFlipped: Bool { engine.isFlipped }

    /// The layer carrying the keyframe animation (mask for template frames, runner layer for color frames).
    var animationLayer: CALayer { engine.animationLayer }
}
