import AppKit
import Combine
import GoRunnerCore
import RunnerKit
import SystemMetrics

/// Owns the NSStatusItem, the runner animation and the metrics sampling lifecycle.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let monitor: SystemMonitor
    private let animator: LayerRunnerAnimator
    private let statusItem: NSStatusItem

    private var settings: AppSettings
    private var cpuUsage: Double = 0

    private var loadedRunnerID: String?
    private var hasFrames = false
    private var animatorAttached = false

    private var isMonitoring = false
    private var isSystemAsleep = false
    private var screensAsleep = false
    private var reduceMotion = false
    private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var appliedSpeed: Double?
    private var appliedPaused: Bool?
    private var appliedTitleKey: String?
    private var appliedAccessibilityLabel: String?

    private var randomTimer: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    var button: NSStatusBarButton? { statusItem.button }

    init(model: AppModel, monitor: SystemMonitor, animator: LayerRunnerAnimator) {
        self.model = model
        self.monitor = monitor
        self.animator = animator
        settings = model.settingsStore.settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    func start() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        loadRunner()
        observe()
        startMonitoring()
        updateRandomTimer()
        refreshAll()
    }

    /// Clicking the status item opens this menu (AppKit handles the click; the runner layer stays on the button).
    func setMenu(_ menu: NSMenu) {
        statusItem.menu = menu
    }

    /// Opens the status menu from code: second launch, notification click, first run.
    func openMenu() {
        button?.performClick(nil)
    }

    // MARK: Observation

    private func observe() {
        // @Published emits in willSet, so use the emitted value rather than reading the store back.
        model.settingsStore.$settings
            .dropFirst()
            .sink { [weak self] new in self?.settingsChanged(new) }
            .store(in: &cancellables)

        model.$runners
            .dropFirst()
            .sink { [weak self] runners in self?.runnersChanged(runners) }
            .store(in: &cancellables)

        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, center: NotificationCenter = workspace, _ action: @escaping (StatusItemController) -> Void) {
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in if let self { action(self) } }
                .store(in: &cancellables)
        }
        on(NSWorkspace.willSleepNotification) { $0.systemWillSleep() }
        on(NSWorkspace.didWakeNotification) { $0.systemDidWake() }
        // Display asleep: nothing is visible, so stop sampling as well as the animation.
        on(NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true; $0.updatePaused(); $0.stopMonitoring() }
        on(NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false; $0.startMonitoring(); $0.updatePaused() }
        // Low Power Mode: keep the numbers, stop the runner animation.
        on(.NSProcessInfoPowerStateDidChange, center: .default) {
            $0.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            $0.updatePaused()
        }
        on(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            $0.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            $0.updatePaused()
        }
        on(NSColor.systemColorsDidChangeNotification, center: .default) { $0.applyTint() }
    }

    private func settingsChanged(_ new: AppSettings) {
        let old = settings
        settings = new
        if new.runnerID != old.runnerID || !hasFrames {
            loadRunner()
        }
        if hasFrames, new.flipHorizontally != old.flipHorizontally {
            animator.setFlipped(new.flipHorizontally)
        }
        if new.useSystemAccentColor != old.useSystemAccentColor {
            applyTint()
        }
        if isMonitoring, new.metricsOptions != old.metricsOptions {
            monitor.update(options: new.metricsOptions)
        }
        if new.randomRunnerEnabled != old.randomRunnerEnabled {
            updateRandomTimer()
        }
        refreshAll()
    }

    private func runnersChanged(_ runners: [RunnerDescriptor]) {
        let loadedStillExists = runners.contains { $0.id == loadedRunnerID }
        if !hasFrames || !loadedStillExists || settings.runnerID != loadedRunnerID {
            loadRunner(available: runners)
        }
    }

    // MARK: Runner

    private func loadRunner(available: [RunnerDescriptor]? = nil) {
        guard let button else { return }
        let runners = available ?? model.runners
        let requested = settings.runnerID
        var candidates = [requested]
        candidates += runners.map(\.id).filter { $0 != requested }

        for id in candidates.prefix(4) {
            do {
                let frames = try model.catalog.frames(for: id)
                guard !frames.images.isEmpty, frames.pointSize.width > 0, frames.pointSize.height > 0 else { continue }
                if !animatorAttached {
                    animator.attach(to: button)
                    animatorAttached = true
                }
                // RunnerKit contract: the placeholder image must be set before setFrames (layout reads the image rect).
                button.image = SpriteRenderer.placeholderImage(size: frames.pointSize)
                animator.setFrames(frames)
                hasFrames = true
                loadedRunnerID = id
                appliedSpeed = nil
                appliedPaused = nil
                animator.setFlipped(settings.flipHorizontally)
                applyTint()
                if id != requested, !runners.contains(where: { $0.id == requested }) {
                    // The stored runner no longer exists (e.g. removed in a newer build): persist the fallback.
                    DispatchQueue.main.async { [weak self] in self?.model.settingsStore.settings.runnerID = id }
                }
                updateTitle(force: true)
                animator.relayout()
                return
            } catch {
                Log.runner.error("Runner \(id, privacy: .public) failed to render: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Graceful degradation: no renderable runner, show the app name as text.
        if animatorAttached {
            animator.detach()
            animatorAttached = false
        }
        hasFrames = false
        loadedRunnerID = nil
        button.image = nil
        updateTitle(force: true)
    }

    private func applyTint() {
        guard hasFrames else { return }
        // .textColor is opaque and resolves per menu bar appearance (labelColor is 85% alpha).
        animator.setTint(settings.useSystemAccentColor ? .controlAccentColor : .textColor)
    }

    private func updateRandomTimer() {
        randomTimer = nil
        guard settings.randomRunnerEnabled else { return }
        randomTimer = Timer.publish(every: 600, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.pickRandomRunner() }
    }

    private func pickRandomRunner() {
        var pool = model.runners
        if settings.randomRunnerMonochromeOnly {
            pool = pool.filter(\.isTemplate)
        }
        let others = pool.filter { $0.id != settings.runnerID }
        guard let pick = (others.isEmpty ? pool : others).randomElement(), pick.id != settings.runnerID else { return }
        model.settingsStore.settings.runnerID = pick.id
    }

    // MARK: Metrics

    private func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        monitor.start(options: settings.metricsOptions) { @Sendable [weak self] snapshot in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.handle(snapshot) }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handle(snapshot) }
                }
            }
        }
    }

    private func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitor.stop()
    }

    private func handle(_ snapshot: SystemSnapshot) {
        model.record(snapshot)
        cpuUsage = snapshot.cpu.usage
        updateSpeed()
        updateTitle()
    }

    private func systemWillSleep() {
        isSystemAsleep = true
        updatePaused()
        stopMonitoring()
    }

    private func systemDidWake() {
        isSystemAsleep = false
        startMonitoring()
        updatePaused()
    }

    // MARK: Apply state

    private func refreshAll() {
        updateSpeed()
        updatePaused()
        updateTitle()
    }

    private func updateSpeed() {
        guard hasFrames else { return }
        let speed = SpeedCurve.speed(cpuUsage: cpuUsage, invert: settings.invertSpeed, fpsLimit: settings.fpsMaxLimit)
        guard speed != appliedSpeed else { return }
        appliedSpeed = speed
        animator.setSpeed(speed)
    }

    private func updatePaused() {
        guard hasFrames else { return }
        let paused = settings.runnerStopped || reduceMotion || isSystemAsleep || screensAsleep || lowPowerMode
        guard paused != appliedPaused else { return }
        appliedPaused = paused
        animator.setPaused(paused)
    }

    private func updateTitle(force: Bool = false) {
        guard let button else { return }
        var text = ""
        if settings.showCPUText {
            text += MetricFormat.percent(cpuUsage)
        }

        let key = "\(hasFrames)|\(text)"
        if force || key != appliedTitleKey {
            appliedTitleKey = key
            let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            if hasFrames {
                if text.isEmpty {
                    button.attributedTitle = NSAttributedString(string: "")
                    button.imagePosition = .imageOnly
                } else {
                    button.attributedTitle = NSAttributedString(string: text, attributes: [.font: mono])
                    button.imagePosition = .imageTrailing
                }
                animator.relayout()
            } else {
                let title = NSMutableAttributedString(string: AppDisplayName.current,
                                                      attributes: [.font: NSFont.menuBarFont(ofSize: 0)])
                if !text.isEmpty {
                    title.append(NSAttributedString(string: " " + text.trimmingCharacters(in: .whitespaces),
                                                    attributes: [.font: mono]))
                }
                button.attributedTitle = title
                button.imagePosition = .noImage
            }
        }
        updateAccessibility()
    }

    private func updateAccessibility() {
        guard let button else { return }
        var label = "\(AppDisplayName.current), CPU \(MetricFormat.shortPercent(cpuUsage))"
        if settings.runnerStopped {
            label += Loc.t(", 러너 멈춤", ", runner stopped")
        }
        guard label != appliedAccessibilityLabel else { return }
        appliedAccessibilityLabel = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp(Loc.t("클릭하면 메뉴가 열립니다", "Click to open the menu"))
    }
}
