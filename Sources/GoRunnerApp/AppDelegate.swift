import AppKit
import Combine
import GoRunnerCore
import RunnerArt
import RunnerKit
import SystemMetrics

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settingsStore: SettingsStore
    let monitor: SystemMonitor
    let catalog: RunnerCatalog
    let animator: LayerRunnerAnimator
    let quota: QuotaCoordinator
    let model: AppModel
    let agentNotifier: AgentNotifier
    let slackNotifier: SlackNotifier

    private var agentWatcher: AgentEventWatcher?
    private var statusItemController: StatusItemController?
    private var statusMenu: StatusMenuController?
    private var settingsWindow: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        AppPaths.ensureDirectories()
        settingsStore = SettingsStore()
        monitor = SystemMonitor()
        catalog = RunnerCatalog(builtIns: RunnerArtCatalog.all)
        animator = LayerRunnerAnimator()
        quota = QuotaCoordinator(settingsStore: settingsStore)
        agentNotifier = AgentNotifier(settingsStore: settingsStore)
        slackNotifier = SlackNotifier(settingsStore: settingsStore)
        model = AppModel(settingsStore: settingsStore, catalog: catalog, quota: quota, agentNotifier: agentNotifier,
                         slackNotifier: slackNotifier)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("go-runner \(AppIdentity.version, privacy: .public) launching")
        model.reloadRunners()

        let settingsWindow = SettingsWindowController(model: model)
        let statusItem = StatusItemController(model: model, monitor: monitor, animator: animator)
        let statusMenu = StatusMenuController(model: model)
        statusItem.setMenu(statusMenu.menu)
        self.settingsWindow = settingsWindow
        self.statusMenu = statusMenu
        statusItemController = statusItem

        model.openSettingsHandler = { [weak self] tab in
            self?.settingsWindow?.show(tab: tab)
        }
        model.stopMonitorsHandler = { [weak self] in
            self?.monitor.stop()
            self?.quota.stop()
            self?.agentWatcher?.stop()
            self?.slackNotifier.stop()
        }

        statusItem.start()
        quota.start()
        startAgentNotifications()

        DistributedNotificationCenter.default().publisher(for: .gorunnerShowDashboard)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.openMenu() }
            .store(in: &cancellables)

        if !settingsStore.settings.hasCompletedOnboarding {
            // First launch: open the menu once so the user sees where the app lives.
            settingsStore.settings.hasCompletedOnboarding = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.openMenu() }
        }

        handleDebugArguments()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        quota.stop()
        agentWatcher?.stop()
        slackNotifier.stop()
    }

    /// Claude Code / Codex finish notifications (drop toggles whose hook disappeared, then watch the events file) and
    /// Slack new-message notifications (Dock badge).
    private func startAgentNotifications() {
        AgentHooks.standard.reconcile(settingsStore)
        agentNotifier.decor = NotificationDecor(catalog: catalog)
        agentNotifier.openMenuHandler = { [weak self] in self?.openMenu() }
        agentNotifier.start()
        let watcher = AgentEventWatcher { [weak self] event in
            self?.agentNotifier.handle(event)
        }
        watcher.start()
        agentWatcher = watcher

        slackNotifier.postHandler = { [weak self] badge in self?.agentNotifier.postSlack(badge) }
        slackNotifier.start()
    }

    private func openMenu() {
        statusItemController?.openMenu()
    }

    /// Undocumented helpers for screenshots: `--open-menu`, `--open-settings[=tab]`.
    private func handleDebugArguments() {
        let args = CommandLine.arguments
        if args.contains("--open-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.openMenu() }
        }
        if let arg = args.first(where: { $0.hasPrefix("--open-settings") }) {
            let tab = arg.split(separator: "=").dropFirst().first.flatMap { SettingsTab(rawValue: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.settingsWindow?.show(tab: tab ?? .general)
            }
        }
    }
}
