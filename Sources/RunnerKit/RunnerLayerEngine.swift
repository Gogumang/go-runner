// CALayer keyframe animation technique adapted from runcat-dev/RunCatNeo
// (`UserInterface/Views/RunnerBar/RunnerLayer.swift`, `RunnerBarView.swift`, `Model/Stores/RunnerBar.swift`),
// Copyright 2026 Kyome22 (Takuto Nakamura), licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0). Modified for GoRunner: pause support, flip via layer transform,
// appearance-driven tint, image-rect layout on an NSStatusBarButton.
//
// Why: swapping `button.image` each frame makes the menu bar re-snapshot the status item for every display and
// appearance (Neo measured 7–8 % CPU); a `CAKeyframeAnimation` on `contents` runs in the render server (~0.1 %).

import AppKit
import QuartzCore
import GoRunnerCore

@MainActor
final class RunnerLayerEngine {
    static let animationKey = "gorunner.runner.contents"
    static let secondsPerFrame = 0.5
    /// Explicit animation begin time (layer-local). Paused layers sit at local time 0, i.e. just before this,
    /// where `fillMode = .backwards` shows the first frame in order.
    static let animationBeginTime: CFTimeInterval = 1e-6

    nonisolated(unsafe) let containerLayer = CALayer()
    let runnerLayer = CALayer()
    let maskLayer = CALayer()

    private(set) weak var button: NSStatusBarButton?
    private(set) var frames: RunnerFrames?
    private(set) var speed: Double = 1
    private(set) var isPaused = false
    private(set) var isFlipped = false
    private(set) var tint: NSColor?

    private var observations: [NSKeyValueObservation] = []
    nonisolated(unsafe) private var notificationTokens: [NSObjectProtocol] = []

    init() {
        containerLayer.name = "GoRunner.runnerContainer"
        runnerLayer.name = "GoRunner.runner"
        maskLayer.name = "GoRunner.runnerMask"
        for layer in [containerLayer, runnerLayer, maskLayer] {
            layer.contentsScale = 2
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        }
        runnerLayer.contentsGravity = .resizeAspect
        runnerLayer.masksToBounds = true
        runnerLayer.magnificationFilter = .nearest
        maskLayer.contentsGravity = .resizeAspect
        maskLayer.magnificationFilter = .nearest
        containerLayer.addSublayer(runnerLayer)
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        let container = containerLayer
        if Thread.isMainThread {
            container.removeFromSuperlayer()
        } else {
            nonisolated(unsafe) let orphan = container
            DispatchQueue.main.async { orphan.removeFromSuperlayer() }
        }
    }

    /// The layer whose `contents` is animated: the mask for template frames, the runner layer for color frames.
    var animationLayer: CALayer {
        (frames?.isTemplate ?? false) ? maskLayer : runnerLayer
    }

    // MARK: Attach / detach

    func attach(to button: NSStatusBarButton) {
        if self.button === button, containerLayer.superlayer != nil, containerLayer.superlayer === button.layer {
            relayout()
            return
        }
        detach()
        self.button = button
        button.wantsLayer = true
        button.postsFrameChangedNotifications = true
        guard let hostLayer = button.layer else {
            Log.runner.error("RunnerLayerEngine: status bar button has no layer")
            return
        }
        withoutActions {
            hostLayer.addSublayer(containerLayer)
        }
        observe(button)
        if frames != nil {
            installAnimation()
        } else {
            relayout()
        }
    }

    func detach() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        withoutActions {
            containerLayer.removeFromSuperlayer()
        }
        button = nil
    }

    private func observe(_ button: NSStatusBarButton) {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.relayout() }
        })
        notificationTokens.append(center.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: nil, queue: .main) {
            [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.button?.window else { return }
                self.relayout()
            }
        })
        notificationTokens.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main) {
            [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let window = note.object as? NSWindow, window === self.button?.window else { return }
                self.relayout()
            }
        })
        // Accent color / increased contrast changes re-resolve dynamic colors.
        notificationTokens.append(center.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.applyTint() }
        })

        // The menu bar's light/dark appearance follows the wallpaper, not the app: watch the button (and its window).
        observations.append(button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            let engine = self
            Self.onMain { engine?.applyTint() }
        })
        if let window = button.window {
            observations.append(window.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                let engine = self
                Self.onMain { engine?.applyTint() }
            })
        }
    }

    private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { body() }
        }
    }

    // MARK: Frames and timing

    func setFrames(_ frames: RunnerFrames) {
        self.frames = frames
        installAnimation()
    }

    private func installAnimation() {
        guard let frames else { return }
        let ordered = frames.order.compactMap { frames.images.indices.contains($0) ? frames.images[$0] : nil }
        let values = ordered.isEmpty ? frames.images : ordered

        withoutActions {
            for layer in [runnerLayer, maskLayer] {
                layer.removeAnimation(forKey: Self.animationKey)
                layer.speed = 1
                layer.timeOffset = 0
                layer.beginTime = 0
            }
            let first = values.first
            if frames.isTemplate {
                runnerLayer.contents = nil
                maskLayer.contents = first
                runnerLayer.mask = maskLayer
            } else {
                runnerLayer.mask = nil
                maskLayer.contents = nil
                runnerLayer.contents = first
            }
            relayout()
            applyTint()

            guard !values.isEmpty else { return }
            let carrier = animationLayer
            carrier.beginTime = CACurrentMediaTime()
            carrier.timeOffset = 0
            carrier.speed = isPaused ? 0 : Float(speed)
            carrier.add(Self.makeAnimation(values), forKey: Self.animationKey)
        }
    }

    static func makeAnimation(_ images: [CGImage]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = images
        animation.calculationMode = .discrete
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.fillMode = .backwards
        animation.beginTime = animationBeginTime
        animation.duration = Double(images.count) * secondsPerFrame
        return animation
    }

    /// Phase-continuous speed change (RunCat Neo): rebase the layer's local time so the current frame doesn't jump.
    func setSpeed(_ newSpeed: Double) {
        let clamped = newSpeed.isFinite ? min(max(newSpeed, 0), 1_000) : 1
        let changed = clamped != speed
        speed = clamped
        guard !isPaused, frames != nil else { return }
        let layer = animationLayer
        guard changed || layer.speed != Float(clamped) else { return }
        withoutActions {
            let now = CACurrentMediaTime()
            layer.timeOffset = layer.convertTime(now, from: nil)
            layer.beginTime = now
            layer.speed = Float(clamped)
        }
    }

    /// Paused = speed 0 at local time 0 → the first frame in order. Unpausing restarts from it at the remembered speed.
    func setPaused(_ paused: Bool) {
        isPaused = paused
        guard frames != nil else { return }
        let layer = animationLayer
        withoutActions {
            if paused {
                layer.speed = 0
                layer.timeOffset = 0
            } else if layer.speed == 0 {
                layer.beginTime = CACurrentMediaTime()
                layer.timeOffset = 0
                layer.speed = Float(speed)
            }
        }
    }

    // MARK: Appearance and geometry

    func setFlipped(_ flipped: Bool) {
        isFlipped = flipped
        withoutActions {
            containerLayer.transform = flipped ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        }
    }

    func setTint(_ color: NSColor?) {
        tint = color
        applyTint()
    }

    /// nil tint = `labelColor` resolved in the status bar button's appearance (light/dark menu bar).
    func resolvedTintColor() -> CGColor {
        let color = tint ?? .labelColor
        var resolved = color.cgColor
        let appearance = button?.effectiveAppearance ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            resolved = (color.usingColorSpace(.sRGB) ?? color).cgColor
        }
        return resolved
    }

    func applyTint() {
        let isTemplate = frames?.isTemplate ?? false
        let color = isTemplate ? resolvedTintColor() : nil
        withoutActions {
            runnerLayer.backgroundColor = color
        }
    }

    func relayout() {
        let size = frames?.pointSize ?? .zero
        guard let button else { return }
        let bounds = button.bounds
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let imageRect = button.cell?.imageRect(forBounds: bounds) ?? .zero
        let rect = Self.runnerRect(imageRect: imageRect, bounds: bounds, size: size, viewIsFlipped: button.isFlipped,
                                   layerIsFlipped: button.layer?.isGeometryFlipped ?? false, scale: scale)
        withoutActions {
            for layer in [containerLayer, runnerLayer, maskLayer] {
                layer.contentsScale = scale
            }
            // Set bounds/position (not frame) because the container may carry a flip transform.
            containerLayer.bounds = CGRect(origin: .zero, size: rect.size)
            containerLayer.position = CGPoint(x: rect.midX, y: rect.midY)
            containerLayer.transform = isFlipped ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
            runnerLayer.frame = containerLayer.bounds
            maskLayer.frame = runnerLayer.bounds
        }
    }

    /// Runner frame in the host layer's coordinate space.
    /// - x: centered on the cell's image rect (the placeholder image's slot); flipping doesn't affect x.
    /// - y: the image rect is converted from view space (`isFlipped`) into layer space (`isGeometryFlipped`),
    ///   then the runner is vertically centered in the bar (`bounds`, 22 pt on most displays).
    nonisolated static func runnerRect(imageRect: CGRect, bounds: CGRect, size: CGSize, viewIsFlipped: Bool,
                                       layerIsFlipped: Bool, scale: CGFloat) -> CGRect {
        var slot = (imageRect.isNull || imageRect.isEmpty) ? bounds : imageRect
        if viewIsFlipped != layerIsFlipped {
            slot.origin.y = bounds.height - slot.maxY
        }
        let pixel = max(scale, 1)
        let x = ((slot.midX - size.width / 2) * pixel).rounded() / pixel
        let y = ((bounds.midY - size.height / 2) * pixel).rounded() / pixel
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
