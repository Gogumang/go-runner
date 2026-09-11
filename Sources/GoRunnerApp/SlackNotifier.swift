import AppKit
import ApplicationServices
import Combine
import GoRunnerCore

/// Slack's Dock badge: nothing, a dot ("•", unreads without a count) or a number.
enum SlackBadge: Equatable, Sendable {
    case none, dot, count(Int)

    init(label: String?) {
        let text = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            self = .none
            return
        }
        if let number = Int(text.filter { $0.isASCII && $0.isNumber }) {
            self = number > 0 ? .count(number) : .none
        } else {
            self = .dot
        }
    }

    /// Worth a notification: a badge appeared, a dot became a number, or the count went up.
    static func isIncrease(from old: SlackBadge, to new: SlackBadge) -> Bool {
        switch (old, new) {
        case (.none, .dot), (.none, .count), (.dot, .count): true
        case let (.count(before), .count(after)): after > before
        default: false
        }
    }

    var debugDescription: String {
        switch self {
        case .none: "none"
        case .dot: "dot"
        case .count(let count): "count:\(count)"
        }
    }
}

/// Reads Slack's badge from the Dock's accessibility tree (Dock `AXList` → item "Slack" → `AXStatusLabel`).
/// Needs Accessibility permission; never prompts. Safe to call off the main thread.
enum SlackDockBadgeReader {
    static let slackBundleID = "com.tinyspeck.slackmacgap"
    static let dockBundleID = "com.apple.dock"

    enum Reading: Equatable, Sendable {
        /// Not trusted, Slack not running, or no Slack item in the Dock.
        case unavailable
        case badge(SlackBadge)
    }

    static var isSlackInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: slackBundleID) != nil
    }

    static var isSlackRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: slackBundleID).isEmpty
    }

    static func read() -> Reading {
        guard AXIsProcessTrusted(), isSlackRunning, let item = slackDockItem() else { return .unavailable }
        return .badge(SlackBadge(label: string(item, "AXStatusLabel")))
    }

    static func slackDockItem() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: dockBundleID).first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1.0)
        for list in children(app) where string(list, kAXRoleAttribute) == "AXList" {
            if let item = children(list).first(where: isSlackItem) {
                return item
            }
        }
        return nil
    }

    private static func isSlackItem(_ item: AXUIElement) -> Bool {
        if string(item, kAXTitleAttribute) == "Slack" { return true }
        guard let value = attribute(item, "AXURL"), CFGetTypeID(value) == CFURLGetTypeID() else { return false }
        return ((value as! CFURL) as URL).lastPathComponent == "Slack.app"
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    /// `GoRunner --slack-badge-probe` (debug): headless, read-only, never prompts. Prints one JSON line.
    static func probeCommand() -> Int32 {
        let trusted = AXIsProcessTrusted()
        let item = trusted ? slackDockItem() : nil
        let label = item.flatMap { string($0, "AXStatusLabel") }
        let report: [String: Any] = [
            "accessibilityTrusted": trusted,
            "slackInstalled": isSlackInstalled,
            "slackRunning": isSlackRunning,
            "dockItemFound": item != nil,
            "statusLabel": label ?? NSNull(),
            "badge": item == nil ? NSNull() : SlackBadge(label: label).debugDescription,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return 1 }
        HeadlessRunner.printJSON(data)
        return 0
    }
}

/// Polls Slack's Dock badge every 5 s while Slack is running and reports increases (at most one per 10 s, with the
/// latest count).
/// Handles Accessibility permission: prompts once per launch, re-checks on activation and every 5 s while untrusted,
/// and stops quietly if the grant is revoked (e.g. after an ad-hoc re-sign).
@MainActor
final class SlackNotifier: ObservableObject {
    static let pollInterval: TimeInterval = 5
    static let trustRecheckInterval: TimeInterval = 5
    static let coalesceWindow: TimeInterval = 10
    static let accessibilitySettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var slackInstalled = false

    /// Posts the notification (AgentNotifier.postSlack checks the toggle and notification permission again).
    var postHandler: ((SlackBadge) -> Void)?

    private let settingsStore: SettingsStore
    private let queue = DispatchQueue(label: "dev.gorunner.GoRunner.slack-badge", qos: .utility)
    private var pollTimer: DispatchSourceTimer?
    private var trustTimer: Timer?
    private var started = false
    private var enabled = false
    private var promptedThisLaunch = false
    private var isSystemAsleep = false
    private var screensAsleep = false
    /// Last badge read; the first read after (re)starting is only a baseline, so existing unreads never notify.
    private var baseline: SlackBadge?
    private var lastPostedAt: Date?
    private var pendingPost: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func start() {
        guard !started else { return }
        started = true
        enabled = settingsStore.settings.notifyOnSlackMessage
        refreshInstalled()
        if enabled, slackInstalled {
            promptForAccessibilityIfNeeded()
        }

        // @Published emits in willSet: use the emitted value, not the store.
        settingsStore.$settings
            .map(\.notifyOnSlackMessage)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in self?.enabledChanged(enabled) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshInstalled()
                self?.refreshTrust()
            }
            .store(in: &cancellables)
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ name: Notification.Name, _ action: @escaping (SlackNotifier) -> Void) {
            workspace.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    action(self)
                    self.updatePolling()
                }
                .store(in: &cancellables)
        }
        on(NSWorkspace.willSleepNotification) { $0.isSystemAsleep = true }
        on(NSWorkspace.didWakeNotification) { $0.isSystemAsleep = false }
        on(NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        on(NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }

        refreshTrust()
    }

    func stop() {
        started = false
        cancellables.removeAll()
        pendingPost?.cancel()
        pendingPost = nil
        stopPolling()
        trustTimer?.invalidate()
        trustTimer = nil
    }

    // MARK: Permission and state

    func refreshInstalled() {
        let installed = SlackDockBadgeReader.isSlackInstalled
        if installed != slackInstalled { slackInstalled = installed }
    }

    func refreshTrust() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
            Log.app.notice("Accessibility trusted=\(trusted)")
            if !trusted { baseline = nil }
        }
        updatePolling()
    }

    /// System prompt linking to Privacy & Security → Accessibility. At most once per launch.
    func promptForAccessibilityIfNeeded() {
        guard !promptedThisLaunch, !AXIsProcessTrusted() else { return }
        promptedThisLaunch = true
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: Self.accessibilitySettingsURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func enabledChanged(_ value: Bool) {
        enabled = value
        if value {
            refreshInstalled()
            promptForAccessibilityIfNeeded()
        } else {
            baseline = nil
            pendingPost?.cancel()
            pendingPost = nil
        }
        refreshTrust()
    }

    private func updatePolling() {
        if started, enabled, !accessibilityTrusted {
            if trustTimer == nil {
                let timer = Timer(timeInterval: Self.trustRecheckInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshTrust() }
                }
                RunLoop.main.add(timer, forMode: .common)
                trustTimer = timer
            }
        } else {
            trustTimer?.invalidate()
            trustTimer = nil
        }

        if started, enabled, accessibilityTrusted, slackInstalled, !isSystemAsleep, !screensAsleep {
            startPolling()
        } else {
            stopPolling()
        }
    }

    // MARK: Polling

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // A generous leeway lets macOS coalesce this wake-up with others.
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            // No Dock query while Slack isn't running (there is no badge to read).
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: SlackDockBadgeReader.slackBundleID).isEmpty
            else { return }
            let reading = SlackDockBadgeReader.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(reading) }
            }
        }
        pollTimer = timer
        timer.resume()
    }

    private func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func handle(_ reading: SlackDockBadgeReader.Reading) {
        guard pollTimer != nil else { return }
        guard case .badge(let badge) = reading else {
            // Revoked grant: show 필요함 and wait for the 5 s re-check instead of polling blindly.
            if !AXIsProcessTrusted() { refreshTrust() }
            return
        }
        let previous = baseline
        baseline = badge
        guard let previous, SlackBadge.isIncrease(from: previous, to: badge) else { return }
        schedulePost()
    }

    private func schedulePost() {
        let now = Date()
        guard let last = lastPostedAt, now.timeIntervalSince(last) < Self.coalesceWindow else {
            post()
            return
        }
        guard pendingPost == nil else { return } // The pending post reads the latest badge when it fires.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingPost = nil
                self?.post()
            }
        }
        pendingPost = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.coalesceWindow - now.timeIntervalSince(last)), execute: work)
    }

    private func post() {
        guard enabled, let badge = baseline, badge != .none else { return } // Read in the meantime: nothing to say.
        lastPostedAt = Date()
        postHandler?(badge)
    }
}
