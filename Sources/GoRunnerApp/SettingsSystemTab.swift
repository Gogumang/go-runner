import GoRunnerCore
import SwiftUI

struct SystemInfoSettingsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section(Loc.t("메뉴 막대", "Menu Bar")) {
                Toggle(isOn: $store.settings.showCPUText) {
                    Text(Loc.t("CPU 사용률 표시", "Show CPU usage"))
                    Text(Loc.t("러너 옆에 CPU 사용률을 숫자로 보여줘요.", "Shows CPU usage as a number next to the runner."))
                }
            }

            Section(Loc.t("메뉴에 표시", "Shown in the Menu")) {
                Toggle(Loc.t("메모리", "Memory"), isOn: $store.settings.monitorMemory)
                Toggle(Loc.t("저장 공간", "Storage"), isOn: $store.settings.monitorStorage)
                Toggle(Loc.t("배터리", "Battery"), isOn: $store.settings.monitorBattery)
                SettingsCaption(Loc.t("CPU는 러너 속도에 쓰여서 항상 측정해요.", "CPU is always measured because it drives the runner."))
            }

            Section(Loc.t("측정", "Sampling")) {
                Picker(selection: $store.settings.updateIntervalSeconds) {
                    ForEach([3, 5, 10], id: \.self) { seconds in
                        Text(Loc.t("\(seconds)초", "\(seconds) s")).tag(seconds)
                    }
                } label: {
                    Text(Loc.t("측정 주기", "Update interval"))
                    Text(Loc.t("길수록 배터리를 덜 써요.", "Longer intervals use less battery."))
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }
}
