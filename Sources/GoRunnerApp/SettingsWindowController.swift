// Settings window in the style of macOS System Settings: a sidebar of colored icons next to grouped forms.

import AppKit
import GoRunnerCore
import SwiftUI

extension SettingsTab {
    var title: String {
        switch self {
        case .general: Loc.t("일반", "General")
        case .runner: Loc.t("러너", "Runner")
        case .system: Loc.t("메뉴 막대", "Menu Bar")
        case .ai: Loc.t("AI 서비스", "AI Services")
        case .notifications: Loc.t("알림", "Notifications")
        case .about: Loc.t("정보", "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .runner: "figure.run"
        case .system: "menubar.rectangle"
        case .ai: "sparkles"
        case .notifications: "bell.badge.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general, .about: .gray
        case .runner: .orange
        case .system: .blue
        case .ai: .purple
        case .notifications: .red
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 780, height: 560)

    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show(tab: SettingsTab?) {
        if let tab { model.settingsTab = tab }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: SettingsRootView(model: model))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        window.setContentSize(Self.defaultSize)
        window.contentMinSize = NSSize(width: 680, height: 420)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = Loc.t("\(AppDisplayName.current) 설정", "\(AppDisplayName.current) Settings")
        window.delegate = self
        window.center()
        return window
    }

    /// Frees the SwiftUI views when the window closes; they are rebuilt on the next open.
    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.window?.contentViewController = nil
                self?.window = nil
            }
        }
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: AppModel

    private var selection: Binding<SettingsTab?> {
        Binding(get: { model.settingsTab }, set: { if let tab = $0 { model.settingsTab = tab } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                AppIdentityRow()
                    .selectionDisabled()
                Section {
                    ForEach(SettingsTab.allCases, id: \.self) { tab in
                        Label {
                            Text(tab.title)
                        } icon: {
                            SettingsIcon(symbol: tab.symbol, tint: tab.tint)
                        }
                        .tag(SettingsTab?.some(tab))
                    }
                }
            }
            // The column width alone is ignored inside an NSHostingController window; the minimum width keeps
            // "go-runner" and the pane titles from truncating.
            .frame(minWidth: 220)
            .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 280)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane(model.settingsTab)
                .id(model.settingsTab)
                .navigationTitle(model.settingsTab.title)
        }
    }

    @ViewBuilder
    private func pane(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsTab(store: model.settingsStore)
        case .runner:
            RunnerSettingsTab(model: model, store: model.settingsStore)
        case .system:
            SystemInfoSettingsTab(store: model.settingsStore)
        case .ai:
            AIServicesSettingsTab(store: model.settingsStore, quota: model.quota)
        case .notifications:
            NotificationSettingsTab(store: model.settingsStore, notifier: model.agentNotifier, slack: model.slackNotifier)
        case .about:
            AboutSettingsTab(model: model)
        }
    }
}

/// App icon, name and version at the top of the sidebar.
private struct AppIdentityRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: AppDisplayName.current)
                    .font(.system(size: 13, weight: .semibold))
                Text(Loc.t("버전 \(AppIdentity.version)", "Version \(AppIdentity.version)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

/// White SF Symbol on a rounded colored square, like the icons in System Settings.
private struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.gradient))
    }
}

/// Explanatory caption under a settings row.
struct SettingsCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
