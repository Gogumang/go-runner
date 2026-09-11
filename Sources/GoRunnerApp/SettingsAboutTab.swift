import AppKit
import GoRunnerCore
import SwiftUI

struct AboutSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                    Text(verbatim: AppDisplayName.current)
                        .font(.title2.weight(.semibold))
                    Text(Loc.t("버전 \(AppIdentity.version)", "Version \(AppIdentity.version)"))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section(Loc.t("라이선스", "License")) {
                LabeledContent(AppDisplayName.current, value: "Apache License 2.0")
                LabeledContent("Copyright", value: "© 2026 gogumang")
            }

            Section(Loc.t("제거", "Uninstall")) {
                SettingsCaption(Loc.t("\(AppDisplayName.current)가 만든 파일과 설정, 로그인 항목, 키체인 항목을 지우고 Claude Code statusline과 작업 완료 알림 훅을 원래대로 되돌린 뒤 앱을 휴지통으로 옮깁니다. 지우기 전에 목록을 보여줍니다.",
                                      "Removes \(AppDisplayName.current)'s files, settings, login item and Keychain items, restores the Claude Code statusline and the finish-notification hooks, and moves the app to the Trash. You'll see the full list first."))
                Button(Loc.t("\(AppDisplayName.current) 제거…", "Uninstall \(AppDisplayName.current)…"), role: .destructive) {
                    model.confirmAndUninstall()
                }
            }
        }
        .formStyle(.grouped)
    }
}
