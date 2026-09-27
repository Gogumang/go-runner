// Status item menu. GoRunner first imitated RunCat Classic's dashboard panel; at the user's request it is now a standard
// macOS menu with graph rows (StatusMenuViews.swift) for system and AI usage. The menu uses the system menu material,
// which is Liquid Glass on macOS 26 because the app is built with the macOS 26 SDK.

import AppKit
import GoRunnerCore
import SwiftUI

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()

    private let model: AppModel
    private var hostedItems: [NSMenuItem] = []

    /// Width of the graph rows; the menu takes the width of its widest item.
    static let contentWidth: CGFloat = 300
    private static let iconHeight: CGFloat = 16

    init(model: AppModel) {
        self.model = model
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        rebuild()
        dropHostedViews()
    }

    // MARK: NSMenuDelegate

    /// Rebuilt on every open so the enabled services, the permission row and the runner list are current. The graph
    /// rows observe the model and keep updating while the menu stays open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.quota.refreshIfStale()
    }

    func menuDidClose(_ menu: NSMenu) {
        dropHostedViews()
    }

    // MARK: Items

    /// Removes the graph views while the menu is closed so they stop observing the model; `rebuild` recreates them.
    private func dropHostedViews() {
        for item in hostedItems {
            item.view = nil
        }
        hostedItems = []
    }

    private func rebuild() {
        dropHostedViews()
        menu.removeAllItems()
        let settings = model.settingsStore.settings

        menu.addItem(.sectionHeader(title: Loc.t("시스템", "System")))
        menu.addItem(hostedItem(SystemGaugesView(model: model, store: model.settingsStore,
                                                 onTap: closeMenu { $0.openActivityMonitor() })))
        if model.agentNotifier.needsPermissionHint {
            menu.addItem(makeItem(Loc.t("알림이 꺼져 있어요 · 허용하기…", "Notifications are off · Allow…"),
                                  symbol: "bell.slash", action: #selector(enableNotifications)))
        }

        let providers = ProviderID.allCases.filter { QuotaCoordinator.isEnabled($0, in: settings.quota) }
        if !providers.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: Loc.t("AI 남은 한도", "AI Limits Left")))
            var icons: [ProviderID: NSImage] = [:]
            for id in providers {
                icons[id] = providerImage(id)
            }
            menu.addItem(hostedItem(ProviderGaugesView(quota: model.quota, store: model.settingsStore, icons: icons,
                                                       onTap: closeMenu { $0.openSettings(tab: .ai) })))
        }

        menu.addItem(.separator())
        let runners = makeItem(Loc.t("러너", "Runner"), symbol: "figure.run", action: nil)
        runners.submenu = runnerMenu()
        menu.addItem(runners)
        menu.addItem(makeItem(Loc.t("설정…", "Settings…"), symbol: "gearshape", action: #selector(openSettings), key: ","))
        menu.addItem(makeItem(Loc.t("AI 사용량 새로고침", "Refresh AI Usage"), symbol: "arrow.clockwise",
                              action: #selector(refreshQuota), key: "r"))
        menu.addItem(.separator())
        menu.addItem(makeItem(Loc.t("\(AppDisplayName.current) 종료", "Quit \(AppDisplayName.current)"), symbol: "power",
                              action: #selector(quit), key: "q"))
    }

    private func hostedItem<Content: View>(_ content: Content) -> NSMenuItem {
        let hosting = NSHostingView(rootView: content.frame(width: Self.contentWidth))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        let item = NSMenuItem()
        item.view = hosting
        hostedItems.append(item)
        return item
    }

    /// Tap handler for a graph block: closes the menu, then runs the action.
    private func closeMenu(then action: @escaping @MainActor (AppModel) -> Void) -> () -> Void {
        { [weak self] in
            guard let self else { return }
            self.menu.cancelTracking()
            let model = self.model
            DispatchQueue.main.async {
                MainActor.assumeIsolated { action(model) }
            }
        }
    }

    private func runnerMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let selected = model.settingsStore.settings.runnerID
        for runner in model.runners {
            let item = NSMenuItem(title: runner.displayName, action: #selector(selectRunner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = runner.id
            item.state = runner.id == selected ? .on : .off
            item.image = model.thumbnail(for: runner.id).map { Self.menuImage($0, pixelArt: true) }
            item.toolTip = runner.credit
            submenu.addItem(item)
        }
        if model.runners.isEmpty {
            let empty = NSMenuItem(title: Loc.t("사용 가능한 러너가 없습니다", "No runners available"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        submenu.addItem(.separator())
        submenu.addItem(makeItem(Loc.t("러너 설정…", "Runner Settings…"), symbol: nil, action: #selector(openRunnerSettings)))
        return submenu
    }

    private func makeItem(_ title: String, symbol: String?, action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        return item
    }

    /// Claude: the Clawd runner's first frame. Codex: the logo from the installed Codex app. SF Symbols otherwise.
    private func providerImage(_ id: ProviderID) -> NSImage? {
        switch id {
        case .claude:
            model.thumbnail(for: StatusMenuContent.claudeRunnerID).map { Self.menuImage($0, pixelArt: true) }
                ?? NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)
        case .codex:
            model.codexAppIcon().map { Self.menuImage($0, pixelArt: false) }
                ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        case .bedrock:
            NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)
        }
    }

    /// Scales an image to menu icon height. Sprite art keeps hard pixel edges; template images stay templates.
    static func menuImage(_ source: NSImage, pixelArt: Bool) -> NSImage {
        guard source.size.width > 0, source.size.height > 0 else { return source }
        let scale = min(iconHeight / source.size.height, iconHeight * 1.6 / source.size.width)
        let size = NSSize(width: (source.size.width * scale).rounded(), height: (source.size.height * scale).rounded())
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = pixelArt ? .none : .high
            source.draw(in: rect)
            return true
        }
        image.isTemplate = source.isTemplate
        return image
    }

    // MARK: Actions

    @objc private func enableNotifications() { model.agentNotifier.enableNotifications() }
    @objc private func openRunnerSettings() { model.openSettings(tab: .runner) }
    @objc private func openSettings() { model.openSettings() }
    @objc private func refreshQuota() { model.quota.refresh() }
    @objc private func quit() { model.quit() }

    @objc private func selectRunner(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.selectRunner(id)
    }
}

/// Values behind the menu's graph rows, kept free of views.
enum StatusMenuContent {
    /// RunnerArt sprite used as the Claude icon (menu row and notification image).
    static let claudeRunnerID = "clawd"
    /// RunnerArt sprite used as the Codex notification image.
    static let codexRunnerID = "codex"
    static let cpuGaugeID = "cpu"

    struct SystemGauge: Equatable, Identifiable {
        var id: String
        var symbol: String
        var label: String
        /// Used share, 0...1 (charge left for the battery, see `isChargeLevel`).
        var fraction: Double
        var value: String
        /// True for the battery: a full bar is good, so it is colored by charge left instead of usage.
        var isChargeLevel = false
    }

    struct ProviderGauge: Equatable {
        struct Window: Equatable, Identifiable {
            var id: String
            var label: String
            /// Remaining share, 0...1.
            var remaining: Double
        }

        var name: String
        /// Shown next to the name when there are no limit windows ("불러오는 중…", "한도 정보 없음", …).
        var status: String?
        var windows: [Window]
        var caption: String?
    }

    /// CPU, memory, storage and battery; metrics turned off in Settings are left out. Empty until the first sample.
    static func systemGauges(_ snapshot: SystemSnapshot?, settings: AppSettings) -> [SystemGauge] {
        guard let snapshot else { return [] }
        var gauges = [SystemGauge(id: cpuGaugeID, symbol: "cpu", label: "CPU", fraction: snapshot.cpu.usage,
                                  value: MetricFormat.shortPercent(snapshot.cpu.usage))]
        if settings.monitorMemory, let memory = snapshot.memory {
            gauges.append(SystemGauge(id: "memory", symbol: "memorychip", label: Loc.t("메모리", "Memory"),
                                      fraction: memory.usage, value: MetricFormat.shortPercent(memory.usage)))
        }
        if settings.monitorStorage, let storage = snapshot.storage, storage.totalBytes > 0 {
            gauges.append(SystemGauge(id: "storage", symbol: "internaldrive", label: Loc.t("저장 공간", "Storage"),
                                      fraction: storage.usage, value: MetricFormat.shortPercent(storage.usage)))
        }
        if settings.monitorBattery, let battery = snapshot.battery, battery.isInstalled, let percentage = battery.percentage {
            gauges.append(SystemGauge(id: "battery", symbol: battery.isCharging ? "battery.100percent.bolt" : "battery.75percent",
                                      label: Loc.t("배터리", "Battery"), fraction: percentage,
                                      value: MetricFormat.shortPercent(percentage), isChargeLevel: true))
        }
        return gauges
    }

    /// Remaining share of every limit window, plus the reset time of the tightest window. Token counts and cost
    /// estimates are not shown.
    static func providerGauge(_ id: ProviderID, report: ProviderReport?, isStale: Bool, isRefreshing: Bool,
                              now: Date = Date()) -> ProviderGauge {
        var name = id.displayName
        guard let report else {
            let state = isRefreshing ? Loc.t("불러오는 중…", "Loading…") : Loc.t("대기 중", "Waiting")
            return ProviderGauge(name: name, status: state, windows: [])
        }
        guard let snapshot = report.snapshot else {
            return ProviderGauge(name: name, status: Loc.t("불러오지 못함", "Unavailable"), windows: [],
                                 caption: report.error?.message)
        }
        if let plan = snapshot.planLabel, !plan.isEmpty { name += " \(plan)" }

        let limited = snapshot.windows.filter { $0.usedFraction != nil }
        guard let tightest = limited.max(by: { ($0.usedFraction ?? 0) < ($1.usedFraction ?? 0) }) else {
            return ProviderGauge(name: name, status: Loc.t("한도 정보 없음", "No limit info"), windows: [],
                                 caption: Loc.t("누르면 설정에서 Claude Code를 연결할 수 있어요", "Click to connect Claude Code in Settings"))
        }
        let windows = limited.map {
            ProviderGauge.Window(id: $0.id, label: $0.label, remaining: max(0, 1 - ($0.usedFraction ?? 0)))
        }
        var parts: [String] = []
        if let reset = tightest.resetsAt {
            parts.append(Loc.t("\(tightest.label) 리셋 \(MetricFormat.resetDescription(reset, now: now))",
                               "\(tightest.label) resets \(MetricFormat.resetDescription(reset, now: now))"))
        }
        if isStale { parts.append(Loc.t("이전 값", "cached")) }
        return ProviderGauge(name: name, status: nil, windows: windows,
                             caption: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }
}
