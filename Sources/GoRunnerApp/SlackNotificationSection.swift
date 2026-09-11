import GoRunnerCore
import SwiftUI

/// Settings → 알림 → Slack: new-message notifications from Slack's Dock badge.
struct SlackNotificationSection: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var slack: SlackNotifier

    var body: some View {
        Section("Slack") {
            Toggle(Loc.t("Slack 새 메시지가 오면 알림", "Notify on new Slack messages"), isOn: $store.settings.notifyOnSlackMessage)
            if !slack.slackInstalled {
                Label(Loc.t("Slack이 설치돼 있지 않아요", "Slack isn't installed"), systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label(Loc.t("손쉬운 사용 권한: ", "Accessibility permission: ")
                          + (slack.accessibilityTrusted ? Loc.t("허용됨", "Allowed") : Loc.t("필요함", "Required")),
                      systemImage: slack.accessibilityTrusted ? "checkmark.circle.fill" : "hand.raised")
                    .foregroundStyle(slack.accessibilityTrusted ? Color.accentColor : Color.orange)
                Spacer()
                if !slack.accessibilityTrusted {
                    Button(Loc.t("손쉬운 사용 설정 열기", "Open Accessibility Settings")) { slack.openAccessibilitySettings() }
                }
            }
            SettingsCaption(Loc.t("Dock의 Slack 배지 숫자만 읽고 메시지 내용은 읽지 않아요. 손쉬운 사용과 알림 권한이 필요해요.",
                                  "Only the unread count on Slack's Dock badge is read, never message content. Needs Accessibility and notification permission."))
        }
        .onAppear {
            slack.refreshInstalled()
            slack.refreshTrust()
        }
    }
}
