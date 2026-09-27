import GoRunnerCore
import SwiftUI

/// grep-admin address for the menu's "어드민 열기" (General tab).
struct AdminSettingsSection: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Section(Loc.t("어드민", "Admin")) {
            TextField(Loc.t("어드민 주소", "Admin address"), text: $store.settings.deviceTrust.adminBaseURL,
                      prompt: Text(verbatim: DeviceTrustSettings.defaultAdminBaseURL))
            SettingsCaption(Loc.t("메뉴의 '어드민 열기'가 이 주소를 브라우저로 열어요. 로그인은 GitHub 계정으로 해요.",
                                  "'Open Admin' in the menu opens this address in the browser. Sign in with GitHub."))
        }
    }
}
