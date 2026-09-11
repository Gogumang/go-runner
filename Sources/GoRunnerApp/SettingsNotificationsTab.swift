import GoRunnerCore
import SwiftUI

/// Settings → 알림: macOS permission, Claude Code / Codex finish notifications and Slack new-message notifications.
struct NotificationSettingsTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var notifier: AgentNotifier
    @ObservedObject var slack: SlackNotifier

    @State private var hookStatus: [AgentKind: AgentHooks.Status] = [:]
    @State private var hookErrors: [AgentKind: String] = [:]

    var body: some View {
        Form {
            Section(Loc.t("알림 권한", "Permission")) {
                permissionRow
                Button(Loc.t("테스트 알림 보내기", "Send Test Notification")) { notifier.sendTestNotification() }
                    .disabled(notifier.permission == .unavailable)
            }

            Section(Loc.t("작업 완료", "Finished Tasks")) {
                agentToggle(.claude, title: Loc.t("Claude Code 작업이 끝나면 알림", "Notify when Claude Code finishes"))
                agentToggle(.codex, title: Loc.t("Codex 작업이 끝나면 알림", "Notify when Codex finishes"))
                SettingsCaption(Loc.t("기존 훅과 알림 설정은 그대로 두고 \(AppDisplayName.current) 항목만 추가하며, 끄거나 \(AppDisplayName.current)를 제거하면 원래대로 되돌립니다.",
                                      "Your existing hooks and notify settings stay as they are. \(AppDisplayName.current) only adds its own entry and restores the original when you turn this off or uninstall \(AppDisplayName.current)."))
            }

            SlackNotificationSection(store: store, slack: slack)
        }
        .formStyle(.grouped)
        .onAppear {
            refreshHookStatus()
            notifier.refreshPermission()
        }
    }

    @ViewBuilder
    private func agentToggle(_ kind: AgentKind, title: String) -> some View {
        Toggle(isOn: Binding(get: { AgentNotifier.isEnabled(kind, in: store.settings) },
                             set: { setAgentNotification(kind, enabled: $0) })) {
            Text(title)
            hookStatusLabel(kind)
        }
        if let error = hookErrors[kind] {
            Text(error)
                .font(.caption)
                .foregroundStyle(Color.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hookStatusLabel(_ kind: AgentKind) -> some View {
        let text: String
        let symbol: String
        var tint = Color.secondary
        switch hookStatus[kind] {
        case nil:
            text = Loc.t("확인 중…", "Checking…")
            symbol = "ellipsis.circle"
        case let status? where status.installed:
            text = Loc.t("훅 설치됨", "Hook installed")
            symbol = "checkmark.circle.fill"
            tint = .green
        case let status? where !status.present:
            text = Loc.t("\(kind.toolName)를 찾을 수 없음", "\(kind.toolName) not found")
            symbol = "questionmark.circle"
        default:
            text = Loc.t("훅 미설치", "Hook not installed")
            symbol = "circle.dashed"
        }
        return Label(text, systemImage: symbol)
            .foregroundStyle(tint)
    }

    @ViewBuilder
    private var permissionRow: some View {
        if notifier.permission == .unavailable {
            SettingsCaption(Loc.t("앱 번들(.app)로 실행할 때만 알림을 보낼 수 있습니다", "Notifications work only when the app runs from its .app bundle"))
        } else {
            LabeledContent {
                switch notifier.permission {
                case .notDetermined:
                    Button(Loc.t("알림 허용 요청", "Request Permission")) { notifier.requestPermission() }
                        .buttonStyle(.borderedProminent)
                case .denied:
                    Button(Loc.t("시스템 설정에서 허용", "Allow in System Settings")) { notifier.openSystemNotificationSettings() }
                default:
                    EmptyView()
                }
            } label: {
                permissionLabel
            }
        }
    }

    private var permissionLabel: some View {
        let state: String
        let symbol: String
        var tint = Color.secondary
        switch notifier.permission {
        case .authorized:
            state = Loc.t("허용됨", "Allowed")
            symbol = "bell.badge"
            tint = .green
        case .denied:
            state = Loc.t("허용 안 됨", "Not allowed")
            symbol = "bell.slash"
            tint = .orange
        case .notDetermined:
            state = Loc.t("아직 묻지 않음", "Not asked yet")
            symbol = "bell"
        case .unknown, .unavailable:
            state = Loc.t("확인 중…", "Checking…")
            symbol = "bell"
        }
        return Label(Loc.t("macOS 알림: ", "macOS notifications: ") + state, systemImage: symbol)
            .foregroundStyle(tint)
    }

    private func setAgentNotification(_ kind: AgentKind, enabled: Bool) {
        hookErrors[kind] = nil
        let hooks = AgentHooks.standard
        if enabled {
            do {
                try hooks.install(kind)
                AgentHooks.setEnabled(true, for: kind, in: &store.settings)
            } catch {
                AgentHooks.setEnabled(false, for: kind, in: &store.settings)
                hookErrors[kind] = error.localizedDescription
            }
        } else {
            do {
                try hooks.uninstall(kind)
            } catch {
                hookErrors[kind] = Loc.t("훅을 제거하지 못했습니다: ", "Couldn't remove the hook: ") + error.localizedDescription
            }
            AgentHooks.setEnabled(false, for: kind, in: &store.settings)
        }
        refreshHookStatus()
    }

    /// Tool detection may run the login shell, so it happens off the main thread.
    private func refreshHookStatus() {
        Task { @MainActor in
            hookStatus = await Task.detached {
                Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, AgentHooks.standard.status($0)) })
            }.value
        }
    }
}
