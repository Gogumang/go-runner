import DeviceTrust
import GoRunnerCore
import SwiftUI

/// Collector / admin addresses and this Mac's device thumbprint (General tab).
struct DeviceTrustSettingsSection: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var deviceTrust: DeviceTrustController

    var body: some View {
        Section(Loc.t("기기 신뢰", "Device Trust")) {
            TextField(Loc.t("collector 주소", "Collector address"), text: $store.settings.deviceTrust.collectorBaseURL,
                      prompt: Text(verbatim: DeviceTrustSettings.defaultCollectorBaseURL))
            TextField(Loc.t("어드민 주소", "Admin address"), text: $store.settings.deviceTrust.adminBaseURL,
                      prompt: Text(verbatim: "https://admin.example.com"))
            LabeledContent(Loc.t("기기 thumbprint", "Device thumbprint")) {
                if let thumbprint = deviceTrust.thumbprint {
                    HStack(spacing: 6) {
                        Text(verbatim: thumbprint)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(Loc.t("복사", "Copy")) { deviceTrust.copyThumbprint() }
                            .controlSize(.small)
                    }
                } else if let error = deviceTrust.thumbprintError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            SettingsCaption(Loc.t("이 Mac의 Secure Enclave 키 지문이에요. collector의 COLLECTOR_DEVICE_KEYS에 쉼표로 추가해야 메뉴의 '어드민 열기'가 동작해요.",
                                  "This Mac's Secure Enclave key fingerprint. Add it (comma-separated) to the collector's COLLECTOR_DEVICE_KEYS so 'Open Admin' in the menu works."))
        }
        .onAppear { deviceTrust.loadThumbprint() }
    }
}
