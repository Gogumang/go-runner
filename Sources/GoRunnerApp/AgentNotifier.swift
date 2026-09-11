import AppKit
import Combine
import GoRunnerCore
import UserNotifications

/// Posts Claude / Codex finish and Slack new-message notifications, and owns notification permission: asks at launch
/// when a notification is already on (install.sh turns them on, then opens the app), asks when one is turned on, and
/// refreshes whenever the app becomes active (e.g. back from System Settings).
@MainActor
final class AgentNotifier: NSObject, ObservableObject {
    enum Permission: Equatable, Sendable {
        case unknown, notDetermined, denied, authorized
        /// No app bundle (e.g. the bare SwiftPM binary): UNUserNotificationCenter can't be used.
        case unavailable
    }

    /// Events from the same provider and project within this window become one notification.
    static let coalesceWindow: TimeInterval = 3
    /// Delay before the launch-time permission request, so the status item is up first.
    static let launchRequestDelay: TimeInterval = 1.0
    /// Set once the "알림이 켜졌어요" confirmation was shown (removed with the defaults domain on uninstall).
    static let confirmationSentKey = "GORUNNER_NOTIFICATION_CONFIRMATION_SENT"

    nonisolated static let agentCategoryID = "gorunner.agent"
    nonisolated static let slackCategoryID = "gorunner.slack"
    nonisolated static let openActionID = "gorunner.open"

    @Published private(set) var permission: Permission = .unknown
    @Published private(set) var slackInstalled = false
    /// Called when the user clicks a Claude / Codex notification.
    var openMenuHandler: (() -> Void)?
    /// Image attachments; nil means text-only notifications.
    var decor: NotificationDecor?

    private let settingsStore: SettingsStore
    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter?
    private var lastPosted: [String: Date] = [:]
    private var cancellables = Set<AnyCancellable>()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    init(settingsStore: SettingsStore, defaults: UserDefaults = .standard) {
        self.settingsStore = settingsStore
        self.defaults = defaults
        // UNUserNotificationCenter.current() raises for processes without a bundle identifier.
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        if center == nil { permission = .unavailable }
    }

    /// Call from applicationDidFinishLaunching, after settings are reconciled with the installed hooks.
    /// Never used by the headless flags, so `--install-agent-hooks` never asks for permission.
    func start() {
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories(Self.categories)
        refreshSlackInstalled()
        refreshPermission()

        if anyToggleOn {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchRequestDelay) { [weak self] in
                self?.requestPermissionIfNotDetermined()
            }
        }
        // A notification turned on later (Settings).
        settingsStore.$settings
            .map { $0.notifyOnClaudeFinish || $0.notifyOnCodexFinish || $0.notifyOnSlackMessage }
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in self?.requestPermissionIfNotDetermined() }
            .store(in: &cancellables)
        // Back from System Settings → Notifications.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshSlackInstalled()
                self?.refreshPermission()
            }
            .store(in: &cancellables)
    }

    /// Slack counts only when it's installed (its toggle defaults to on).
    var anyToggleOn: Bool {
        let settings = settingsStore.settings
        return settings.notifyOnClaudeFinish || settings.notifyOnCodexFinish || (settings.notifyOnSlackMessage && slackInstalled)
    }

    /// Menu hint: a notification is on but macOS won't show it (and the user can do something about it).
    var needsPermissionHint: Bool {
        anyToggleOn && (permission == .notDetermined || permission == .denied)
    }

    private func refreshSlackInstalled() {
        let installed = SlackDockBadgeReader.isSlackInstalled
        if installed != slackInstalled { slackInstalled = installed }
    }

    // MARK: Posting

    static func isEnabled(_ kind: AgentKind, in settings: AppSettings) -> Bool {
        switch kind {
        case .claude: settings.notifyOnClaudeFinish
        case .codex: settings.notifyOnCodexFinish
        }
    }

    static func title(for kind: AgentKind) -> String {
        Loc.t("\(kind.displayName) 작업 완료", "\(kind.displayName) finished")
    }

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    func handle(_ event: AgentEvent) {
        guard Self.isEnabled(event.provider, in: settingsStore.settings) else { return }
        let now = Date()
        let key = "\(event.provider.rawValue)|\(event.project ?? "")"
        lastPosted = lastPosted.filter { now.timeIntervalSince($0.value) < Self.coalesceWindow }
        guard lastPosted[key] == nil else { return }
        lastPosted[key] = now
        let time = Self.clock(event.timestamp)
        post(source: event.provider.notificationSource,
             title: Self.title(for: event.provider),
             subtitle: event.project,
             body: Loc.t("방금 끝났어요 · \(time)", "Just finished · \(time)"),
             category: Self.agentCategoryID)
    }

    /// From SlackNotifier. Only when the Slack toggle is on and notifications are allowed.
    func postSlack(_ badge: SlackBadge) {
        guard settingsStore.settings.notifyOnSlackMessage, permission == .authorized else { return }
        let time = Self.clock(Date())
        let body: String
        switch badge {
        case .count(let count):
            body = Loc.t("안 읽은 메시지 \(count)개 · \(time)", "\(count) unread \(count == 1 ? "message" : "messages") · \(time)")
        case .dot, .none:
            body = Loc.t("새 메시지가 있어요 · \(time)", "You have new messages · \(time)")
        }
        post(source: .slack, title: Loc.t("Slack 새 메시지", "New Slack message"), subtitle: nil, body: body,
             category: Self.slackCategoryID)
    }

    /// Settings → "테스트 알림 보내기". Ignores the toggles and coalescing.
    func sendTestNotification() {
        let send: @MainActor @Sendable (AgentNotifier) -> Void = { notifier in
            let time = Self.clock(Date())
            notifier.post(source: .claude, title: Self.title(for: .claude), subtitle: AppDisplayName.current,
                          body: Loc.t("테스트 알림이에요 · \(time)", "Test notification · \(time)"),
                          category: Self.agentCategoryID)
        }
        if permission == .authorized {
            send(self)
        } else {
            requestPermission { [weak self] in
                guard let self, self.permission == .authorized else { return }
                send(self)
            }
        }
    }

    private func post(source: NotificationSource?, title: String, subtitle: String?, body: String, category: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.categoryIdentifier = category
        if let source {
            content.sound = NotificationDecor.sound(for: source)
            content.threadIdentifier = source.threadIdentifier
            if let attachment = decor?.attachment(for: source) {
                content.attachments = [attachment]
            }
        } else {
            content.sound = .default
            content.threadIdentifier = "gorunner.app"
        }
        let request = UNNotificationRequest(identifier: "gorunner.\(source?.rawValue ?? "app").\(UUID().uuidString)",
                                            content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                Log.app.error("Notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static var categories: Set<UNNotificationCategory> {
        let open = Loc.t("열기", "Open")
        // Claude / Codex bring the app forward to open the menu; Slack's action only activates Slack.
        let agentOpen = UNNotificationAction(identifier: openActionID, title: open, options: [.foreground])
        let slackOpen = UNNotificationAction(identifier: openActionID, title: open, options: [])
        return [
            UNNotificationCategory(identifier: agentCategoryID, actions: [agentOpen], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: slackCategoryID, actions: [slackOpen], intentIdentifiers: [], options: []),
        ]
    }

    static func activateSlack() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SlackDockBadgeReader.slackBundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                Log.app.error("Slack failed to open: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Permission

    /// Menu hint and Settings button: ask when undecided, otherwise send the user to System Settings.
    func enableNotifications() {
        switch permission {
        case .denied: openSystemNotificationSettings()
        case .notDetermined, .unknown: requestPermission()
        case .authorized, .unavailable: break
        }
    }

    func refreshPermission(then completion: (@MainActor @Sendable () -> Void)? = nil) {
        fetchPermission { [weak self] permission in
            self?.apply(permission)
            completion?()
        }
    }

    /// Shows the system prompt only while the user hasn't decided yet.
    func requestPermissionIfNotDetermined() {
        fetchPermission { [weak self] permission in
            guard let self else { return }
            self.apply(permission)
            if permission == .notDetermined {
                self.requestPermission()
            }
        }
    }

    /// Brings the app forward so the system prompt appears in front, then asks.
    func requestPermission(then completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let center else {
            completion?()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if let error {
                Log.app.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
            Log.app.notice("Notification authorization granted=\(granted)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.refreshPermission(then: completion) }
            }
        }
    }

    func openSystemNotificationSettings() {
        let candidates = [
            "x-apple.preferences:com.apple.Notifications-Settings.extension?id=\(AppIdentity.bundleID)",
            "x-apple.preferences:com.apple.preference.notifications",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(AppIdentity.bundleID)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for string in candidates {
            // Only schemes with a registered handler (`x-apple.preferences:` has none on macOS 15).
            guard let url = URL(string: string), NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    private func fetchPermission(_ completion: @escaping @MainActor @Sendable (Permission) -> Void) {
        guard let center else {
            completion(.unavailable)
            return
        }
        center.getNotificationSettings { settings in
            let permission = Self.permission(for: settings.authorizationStatus)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(permission) }
            }
        }
    }

    private func apply(_ new: Permission) {
        let old = permission
        guard new != old else { return }
        permission = new
        // First grant observed by this app (prompt accepted, or allowed in System Settings): confirm once.
        if new == .authorized, old == .notDetermined || old == .denied, !defaults.bool(forKey: Self.confirmationSentKey) {
            defaults.set(true, forKey: Self.confirmationSentKey)
            let name = AppDisplayName.current
            post(source: nil,
                 title: Loc.t("\(name) 알림이 켜졌어요", "\(name) notifications are on"),
                 subtitle: nil,
                 body: Loc.t("Claude Code나 Codex 작업이 끝나거나 Slack 메시지가 오면 여기로 알려드릴게요.",
                             "You'll be notified here when Claude Code or Codex finishes or a Slack message arrives."),
                 category: Self.agentCategoryID)
        }
    }

    private nonisolated static func permission(for status: UNAuthorizationStatus) -> Permission {
        switch status {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }
}

extension AgentNotifier: UNUserNotificationCenterDelegate {
    /// Show banners even while the app is active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Clicking a notification or its "열기" action: Slack activates Slack, everything else opens the menu.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let isSlack = response.notification.request.content.categoryIdentifier == Self.slackCategoryID
        if action == UNNotificationDefaultActionIdentifier || action == Self.openActionID {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if isSlack {
                        AgentNotifier.activateSlack()
                    } else {
                        self?.openMenuHandler?()
                    }
                }
            }
        }
        completionHandler()
    }
}
