import AppKit
import GoRunnerCore
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published var errorMessage: String?

    var isOn: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = Loc.t("변경하지 못했습니다: ", "Couldn't change it: ") + error.localizedDescription
            Log.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    var statusText: String {
        switch status {
        case .enabled: Loc.t("켜짐", "On")
        case .notRegistered: Loc.t("꺼짐", "Off")
        case .requiresApproval: Loc.t("승인 필요 — 시스템 설정 → 일반 → 로그인 항목", "Needs approval — System Settings → General → Login Items")
        case .notFound: Loc.t("찾을 수 없음 (앱 번들에서 실행해야 합니다)", "Not found (run from the app bundle)")
        @unknown default: Loc.t("알 수 없음", "Unknown")
        }
    }
}

struct GeneralSettingsTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var deviceTrust: DeviceTrustController
    @StateObject private var login = LoginItemModel()
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section(Loc.t("시작", "Launch")) {
                Toggle(Loc.t("로그인 시 자동 실행", "Launch at login"),
                       isOn: Binding(get: { login.isOn }, set: { login.setEnabled($0) }))
                LabeledContent(Loc.t("상태", "Status"), value: login.statusText)
                if login.status == .requiresApproval {
                    Button(Loc.t("로그인 항목 설정 열기…", "Open Login Items Settings…")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                if let error = login.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DeviceTrustSettingsSection(store: store, deviceTrust: deviceTrust)

            Section(Loc.t("초기화", "Reset")) {
                Button(Loc.t("설정 초기화…", "Reset Settings…"), role: .destructive) {
                    confirmReset = true
                }
                SettingsCaption(Loc.t("모든 설정을 기본값으로 되돌려요.", "Restores every setting to its default."))
            }
        }
        .formStyle(.grouped)
        .onAppear { login.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
        .alert(Loc.t("설정을 초기화할까요?", "Reset all settings?"), isPresented: $confirmReset) {
            Button(Loc.t("초기화", "Reset"), role: .destructive) {
                var fresh = AppSettings()
                fresh.hasCompletedOnboarding = true
                store.settings = fresh
            }
            Button(Loc.t("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(Loc.t("러너, 시스템 정보, AI 서비스 설정이 모두 기본값으로 돌아갑니다.",
                       "Runner, system info and AI service settings return to their defaults."))
        }
    }
}
