import AppKit

// MARK: - Built-in pixel sprite data (authored in RunnerArt, rendered by RunnerKit)

/// A pixel-art runner defined as text grids.
///
/// Geometry (RunCat convention): every frame is **18 cells tall**; one cell = 2×2 px at @2x,
/// so frames render to **36 px tall** images drawn at **18 pt**. Width 5...50 cells (10...100 px),
/// identical for every frame. `.` is always transparent; every other character must be in `palette`.
public struct PixelSprite: Sendable, Equatable {
    public static let rows = 18
    public static let pixelsPerCell = 2
    public static let widthRange = 5...50

    public var id: String
    /// "ko" and "en" display names.
    public var names: [String: String]
    /// Character → 0xRRGGBBAA. For template sprites use opaque black (0x000000FF); alpha is what matters.
    public var palette: [Character: UInt32]
    /// frames[frame][row] — each row is a String of equal width.
    public var frames: [[String]]
    /// Playback order of frame indices, e.g. [0,1,2,3,2,1]. nil = 0..<frames.count.
    public var frameOrder: [Int]?
    /// true = monochrome template tinted with the menu bar text color.
    public var isTemplate: Bool
    /// Attribution shown in credits, e.g. "Kodee by JetBrains s.r.o., CC BY 4.0 (pixel adaptation)".
    public var credit: String?
    /// SPDX id or "Original".
    public var license: String
    /// true when the character is inspired by a third-party brand.
    public var isBrandInspired: Bool
    public var tags: [String]

    public init(id: String, names: [String: String], palette: [Character: UInt32], frames: [[String]],
                frameOrder: [Int]? = nil, isTemplate: Bool, credit: String? = nil, license: String = "Original",
                isBrandInspired: Bool = false, tags: [String] = []) {
        self.id = id
        self.names = names
        self.palette = palette
        self.frames = frames
        self.frameOrder = frameOrder
        self.isTemplate = isTemplate
        self.credit = credit
        self.license = license
        self.isBrandInspired = isBrandInspired
        self.tags = tags
    }

    public var displayName: String {
        names[Loc.isKorean ? "ko" : "en"] ?? names["en"] ?? id
    }
}

// MARK: - Catalog

public enum RunnerSource: Sendable, Equatable {
    /// Pixel sprite compiled into the app (`RunnerArtCatalog.all`).
    case builtIn
}

public struct RunnerDescriptor: Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var isTemplate: Bool
    public var frameCount: Int
    public var credit: String?
    public var license: String
    public var isBrandInspired: Bool
    public var source: RunnerSource

    public init(id: String, displayName: String, isTemplate: Bool, frameCount: Int, credit: String?, license: String,
                isBrandInspired: Bool, source: RunnerSource) {
        self.id = id
        self.displayName = displayName
        self.isTemplate = isTemplate
        self.frameCount = frameCount
        self.credit = credit
        self.license = license
        self.isBrandInspired = isBrandInspired
        self.source = source
    }
}

/// Rendered frames ready for the animator. Images are 36 px tall; `pointSize` height is 18.
public struct RunnerFrames: @unchecked Sendable {
    public var images: [CGImage]
    public var pointSize: CGSize
    public var isTemplate: Bool
    /// Indices into `images`, in playback order.
    public var order: [Int]

    public init(images: [CGImage], pointSize: CGSize, isTemplate: Bool, order: [Int]) {
        self.images = images
        self.pointSize = pointSize
        self.isTemplate = isTemplate
        self.order = order
    }
}

public protocol RunnerCatalogProviding: AnyObject {
    /// Built-in runners in the order given at init.
    func allRunners() -> [RunnerDescriptor]
    func frames(for id: String) throws -> RunnerFrames
}

// MARK: - Animator

/// Animates frames on a status bar button with a CALayer keyframe animation (no per-frame image swaps).
@MainActor
public protocol RunnerAnimating: AnyObject {
    /// Adds the runner layer to the button. The app sets `button.image` to a clear placeholder of
    /// `frames.pointSize` so AppKit reserves space; the animator overlays the image rect.
    func attach(to button: NSStatusBarButton)
    func setFrames(_ frames: RunnerFrames)
    /// Speed multiplier from `SpeedCurve.speed` (1 = 0.5 s per frame). Phase-continuous.
    func setSpeed(_ speed: Double)
    /// Paused = frozen on the first frame in order ("Stop the runner", Reduce Motion, sleep).
    func setPaused(_ paused: Bool)
    func setFlipped(_ flipped: Bool)
    /// Tint for template frames. nil = menu bar label color for the current appearance.
    func setTint(_ color: NSColor?)
    /// Call after the button layout changes (title text shown/hidden, length changed).
    func relayout()
}
