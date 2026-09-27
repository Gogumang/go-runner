import AppKit
import Combine
import GoRunnerCore
import RunnerKit

enum SettingsTab: String, CaseIterable {
    case general, runner, system, ai, notifications, about
}

/// Shared state and actions for the status menu and the settings window.
@MainActor
final class AppModel: ObservableObject {
    let settingsStore: SettingsStore
    let catalog: RunnerCatalog
    let quota: QuotaCoordinator
    let agentNotifier: AgentNotifier
    let slackNotifier: SlackNotifier

    /// Samples kept for the menu's CPU graph (RunCat Neo keeps 61).
    static let historyLength = 61

    @Published private(set) var snapshot: SystemSnapshot?
    /// CPU usage percentages (0...100), oldest first.
    @Published private(set) var cpuHistory = Array(repeating: 0.0, count: AppModel.historyLength)
    @Published private(set) var runners: [RunnerDescriptor] = []
    @Published var settingsTab: SettingsTab = .general

    /// Routing hooks installed by AppDelegate.
    var openSettingsHandler: ((SettingsTab?) -> Void)?
    var stopMonitorsHandler: (() -> Void)?

    private var thumbnailCache: [String: NSImage] = [:]
    private var thumbnailFailures: Set<String> = []

    init(settingsStore: SettingsStore, catalog: RunnerCatalog, quota: QuotaCoordinator, agentNotifier: AgentNotifier,
         slackNotifier: SlackNotifier) {
        self.settingsStore = settingsStore
        self.catalog = catalog
        self.quota = quota
        self.agentNotifier = agentNotifier
        self.slackNotifier = slackNotifier
    }

    // MARK: Metrics

    /// Stores the latest snapshot and appends CPU usage (0...100) to the graph history.
    func record(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        cpuHistory = Self.appending(snapshot.cpu.usage * 100, to: cpuHistory)
    }

    private static func appending(_ value: Double, to history: [Double]) -> [Double] {
        var next = history
        next.append(max(0, min(100, value)))
        if next.count > historyLength {
            next.removeFirst(next.count - historyLength)
        }
        return next
    }

    // MARK: Runners

    func reloadRunners() {
        thumbnailCache.removeAll()
        thumbnailFailures.removeAll()
        runners = catalog.allRunners()
    }

    var currentRunner: RunnerDescriptor? {
        runners.first { $0.id == settingsStore.settings.runnerID }
    }

    /// First frame of a runner, rendered once and cached. nil when the runner can't be rendered.
    func thumbnail(for id: String) -> NSImage? {
        if let cached = thumbnailCache[id] { return cached }
        if thumbnailFailures.contains(id) { return nil }
        do {
            let frames = try catalog.frames(for: id)
            guard !frames.images.isEmpty, frames.pointSize.width > 0 else {
                thumbnailFailures.insert(id)
                return nil
            }
            let image = SpriteRenderer.image(from: frames, index: frames.order.first ?? 0)
            image.isTemplate = frames.isTemplate
            thumbnailCache[id] = image
            return image
        } catch {
            thumbnailFailures.insert(id)
            return nil
        }
    }

    func selectRunner(_ id: String) {
        settingsStore.settings.runnerID = id
    }

    // MARK: Navigation and system actions

    func openSettings(tab: SettingsTab? = nil) {
        openSettingsHandler?(tab)
    }

    func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                Log.app.error("Activity Monitor failed to open: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Uninstall

    func confirmAndUninstall() {
        let items = UninstallService.plan()
        let alert = NSAlert()
        alert.alertStyle = .warning
        let name = AppDisplayName.current
        alert.messageText = Loc.t("\(name)를 제거할까요?", "Uninstall \(name)?")
        var info = Loc.t("다음 항목을 삭제하거나 원래대로 되돌린 뒤 앱을 종료합니다:", "\(name) will remove or restore the following, then quit:")
        info += "\n\n" + (items.isEmpty ? Loc.t("• (지울 항목 없음)", "• (nothing to remove)") : items.map { "• \($0)" }.joined(separator: "\n"))
        if !UninstallService.isBundleInApplicationsFolder {
            info += "\n\n" + Loc.t("앱 번들이 응용 프로그램 폴더 밖에 있어 그대로 둡니다:\n\(Bundle.main.bundleURL.path)",
                                   "The app bundle is outside an Applications folder and is left in place:\n\(Bundle.main.bundleURL.path)")
        }
        alert.informativeText = info
        alert.addButton(withTitle: Loc.t("\(name) 제거", "Uninstall \(name)"))
        alert.addButton(withTitle: Loc.t("취소", "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let service = UninstallService(stopMonitors: stopMonitorsHandler)
        Task { @MainActor in
            _ = await service.perform(removeAppBundle: true, terminate: true)
        }
    }
}
