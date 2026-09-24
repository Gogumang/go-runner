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
                      prompt: Text(verbatim: DeviceTrustSettings.defaultAdminBaseURL))
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
            LabeledContent(Loc.t("기기 등록", "Registration")) {
                Button(Loc.t("이 Mac 등록 요청", "Request Registration")) { deviceTrust.requestEnrollment() }
                    .controlSize(.small)
                    .disabled(deviceTrust.isRequestingEnrollment)
            }
            if let message = deviceTrust.enrollmentMessage {
                SettingsCaption(message)
            }
            SettingsCaption(Loc.t("thumbprint는 이 Mac의 Secure Enclave 키 지문이에요. 등록을 요청한 뒤, 이미 등록된 Mac에서 어드민 → 관리 → 기기를 열어 thumbprint가 같은지 확인하고 승인하세요.",
                                  "The thumbprint is this Mac's Secure Enclave key fingerprint. After requesting, approve it from an already registered Mac (Admin > 관리 > 기기), checking the thumbprint matches."))
        }
        .onAppear { deviceTrust.loadThumbprint() }
    }
}
