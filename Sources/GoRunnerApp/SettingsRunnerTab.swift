import GoRunnerCore
import SwiftUI

/// Settings → 러너: pick the menu bar character.
struct RunnerSettingsTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                if model.runners.isEmpty {
                    Text(Loc.t("사용 가능한 러너가 없어요. 메뉴 막대에는 \"\(AppDisplayName.current)\" 글자가 표시돼요.",
                               "No runners available. The menu bar shows the text \"\(AppDisplayName.current)\"."))
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                        ForEach(model.runners) { runner in
                            cell(runner)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } footer: {
                SettingsCaption(Loc.t("고른 러너가 메뉴 막대에서 CPU 사용량에 맞춰 달려요.",
                                      "The runner you pick runs in the menu bar at a pace set by CPU usage."))
            }
        }
        .formStyle(.grouped)
    }

    private func cell(_ runner: RunnerDescriptor) -> some View {
        let selected = runner.id == store.settings.runnerID
        return Button {
            model.selectRunner(runner.id)
        } label: {
            // The checkmark is a sibling, not an overlay on the card: anything layered onto a view that
            // carries `.glassEffect` is composited into the material and comes back out blurred.
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 6) {
                    RunnerThumbnail(image: model.thumbnail(for: runner.id), isTemplate: runner.isTemplate, height: 28)
                        .frame(height: 36)
                    Text(runner.displayName)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
                .glassCard(selected: selected)

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(runner.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
