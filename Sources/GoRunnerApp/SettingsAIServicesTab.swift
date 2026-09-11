import BedrockUsage
import ClaudeUsage
import GoRunnerCore
import SwiftUI

struct AIServicesSettingsTab: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var quota: QuotaCoordinator

    @State private var confirmOAuth = false
    @State private var statuslineInstalled = ClaudeStatuslineInstaller.standard.isInstalled
    @State private var statuslineMessage: String?
    @State private var statuslineMessageIsError = false
    @State private var awsProfiles: [String] = []
    @State private var modelIDsText = ""

    var body: some View {
        Form {
            claudeSection
            codexSection
            bedrockSection
            refreshSection
        }
        .formStyle(.grouped)
        .onAppear {
            statuslineInstalled = ClaudeStatuslineInstaller.standard.isInstalled
            awsProfiles = AWSProfiles.list()
            modelIDsText = store.settings.quota.bedrockModelIDs.joined(separator: ", ")
        }
        .alert(Loc.t("Claude OAuth 사용량 API를 켤까요?", "Turn on the Claude OAuth usage API?"), isPresented: $confirmOAuth) {
            Button(Loc.t("켜기", "Turn On")) { store.settings.quota.claudeOAuthSource = true }
            Button(Loc.t("취소", "Cancel"), role: .cancel) {}
        } message: {
            Text(Loc.t("""
                • 문서화되지 않은 비공개 API입니다. 예고 없이 바뀌거나 막힐 수 있습니다.
                • Anthropic 약관은 Claude.ai 토큰의 서드파티 사용을 제한합니다. 본인 책임으로 사용하세요.
                • Claude Code의 토큰을 키체인에서 읽기만 하며, 저장하거나 갱신하지 않습니다.
                • macOS 키체인이 접근 허용 여부를 물어볼 수 있습니다.
                """, """
                • This is an undocumented API. It may change or stop working without notice.
                • Anthropic's terms restrict third-party use of Claude.ai tokens. Use at your own risk.
                • Claude Code's token is only read from the Keychain; it is never stored or refreshed.
                • macOS may ask you to allow Keychain access.
                """))
        }
    }

    // MARK: Claude

    private var claudeSection: some View {
        Section {
            Toggle(Loc.t("Claude 사용량 보기", "Show Claude usage"), isOn: $store.settings.quota.claudeEnabled)
            if store.settings.quota.claudeEnabled {
                LabeledContent {
                    if statuslineInstalled {
                        Button(Loc.t("연결 해제", "Disconnect")) { changeStatusline(install: false) }
                    } else {
                        Button(Loc.t("연결하기", "Connect")) { changeStatusline(install: true) }
                            .buttonStyle(.borderedProminent)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Loc.t("Claude Code 연결", "Claude Code connection"))
                        Label(statuslineInstalled ? Loc.t("연결됨 · 5시간 · 주간 남은 한도를 받아요", "Connected · receives 5-hour and weekly limits")
                                                  : Loc.t("연결 안 됨", "Not connected"),
                              systemImage: statuslineInstalled ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.caption)
                            .foregroundStyle(statuslineInstalled ? Color.green : Color.secondary)
                    }
                }
                SettingsCaption(Loc.t("Claude Code의 statusline에서 남은 한도를 받아요. 지금 쓰는 statusline(예: claude-hud)은 그대로 보이고, 연결을 해제하면 원래 설정으로 돌아가요.",
                                      "Limits come from Claude Code's statusline. Your current statusline (e.g. claude-hud) keeps working, and disconnecting restores the original setting."))
                if let statuslineMessage {
                    Text(statuslineMessage)
                        .font(.caption)
                        .foregroundStyle(statuslineMessageIsError ? Color.red : Color.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(Loc.t("고급 데이터 소스", "Advanced data sources")) {
                    Toggle(Loc.t("statusline 기록 읽기", "Read the statusline record"), isOn: $store.settings.quota.claudeStatuslineSource)
                    Toggle(isOn: $store.settings.quota.claudeLocalLogsSource) {
                        Text(Loc.t("로컬 로그 분석", "Local log analysis"))
                        Text(Loc.t("~/.claude/projects에서 토큰 · 비용을 추정해요. 메모리와 배터리를 많이 써요.",
                                   "Estimates tokens and cost from ~/.claude/projects. Uses a lot of memory and battery."))
                    }
                    Toggle(isOn: Binding(
                        get: { store.settings.quota.claudeOAuthSource },
                        set: { newValue in
                            if newValue { confirmOAuth = true } else { store.settings.quota.claudeOAuthSource = false }
                        })) {
                        Text(Loc.t("OAuth 사용량 API", "OAuth usage API"))
                        Text(Loc.t("비공개 API라 선택 사항이에요.", "Undocumented API, opt-in."))
                    }
                }
            }
        } header: {
            ProviderHeader(id: .claude, settings: store.settings.quota, report: quota.reports[.claude])
        }
    }

    private func changeStatusline(install: Bool) {
        do {
            if install {
                try ClaudeStatuslineInstaller.standard.install()
            } else {
                try ClaudeStatuslineInstaller.standard.uninstall()
            }
            statuslineMessageIsError = false
            statuslineMessage = install
                ? Loc.t("연결했어요. Claude Code가 statusline을 갱신하면 몇 초 안에 메뉴에 표시돼요.",
                        "Connected. The menu shows the limits a few seconds after Claude Code updates its statusline.")
                : Loc.t("연결을 해제하고 이전 statusline을 복원했어요.", "Disconnected and restored your previous statusline.")
        } catch {
            statuslineMessageIsError = true
            statuslineMessage = error.localizedDescription
        }
        statuslineInstalled = ClaudeStatuslineInstaller.standard.isInstalled
        quota.refresh([.claude])
    }

    // MARK: Codex

    private var codexSection: some View {
        Section {
            Toggle(Loc.t("Codex 사용량 보기", "Show Codex usage"), isOn: $store.settings.quota.codexEnabled)
            if store.settings.quota.codexEnabled {
                DisclosureGroup(Loc.t("고급 데이터 소스", "Advanced data sources")) {
                    Toggle("codex app-server", isOn: $store.settings.quota.codexAppServerSource)
                    Toggle(isOn: $store.settings.quota.codexSessionLogsSource) {
                        Text(Loc.t("세션 로그", "Session logs"))
                        Text(Loc.t("app-server를 쓸 수 없을 때만 ~/.codex/sessions를 읽어요.",
                                   "Reads ~/.codex/sessions only when app-server is unavailable."))
                    }
                    TextField(Loc.t("codex 경로", "codex path"), text: $store.settings.quota.codexExecutablePath,
                              prompt: Text(Loc.t("비워 두면 자동으로 찾아요", "Leave empty to find it automatically")))
                }
            }
        } header: {
            ProviderHeader(id: .codex, settings: store.settings.quota, report: quota.reports[.codex])
        }
    }

    // MARK: Bedrock

    private var profileOptions: [String] {
        var options = awsProfiles
        let current = store.settings.quota.awsProfile
        if !current.isEmpty, !options.contains(current) { options.insert(current, at: 0) }
        return options
    }

    private var regionOptions: [String] {
        var options = AWSProfiles.bedrockRegions
        let current = store.settings.quota.awsRegion
        if !current.isEmpty, !options.contains(current) { options.append(current) }
        return options
    }

    private var bedrockSection: some View {
        Section {
            Toggle(Loc.t("Bedrock 사용량 보기", "Show Bedrock usage"), isOn: $store.settings.quota.bedrockEnabled)
            if store.settings.quota.bedrockEnabled {
                Picker(Loc.t("AWS 프로필", "AWS profile"), selection: $store.settings.quota.awsProfile) {
                    ForEach(profileOptions, id: \.self) { Text($0).tag($0) }
                }
                Picker(Loc.t("리전", "Region"), selection: $store.settings.quota.awsRegion) {
                    ForEach(regionOptions, id: \.self) { Text($0).tag($0) }
                }
                TextField(Loc.t("모델 ID", "Model IDs"), text: $modelIDsText,
                          prompt: Text(Loc.t("쉼표로 구분, 비워 두면 자동", "Comma-separated; empty = auto")))
                    .onChange(of: modelIDsText) { _, text in
                        let ids = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        if ids != store.settings.quota.bedrockModelIDs {
                            store.settings.quota.bedrockModelIDs = ids
                        }
                    }
                DisclosureGroup(Loc.t("고급", "Advanced")) {
                    Toggle(isOn: $store.settings.quota.bedrockCostExplorer) {
                        Text(Loc.t("Cost Explorer 비용", "Cost Explorer spend"))
                        Text(Loc.t("요청당 $0.01, 6시간마다", "$0.01 per request, every 6 hours"))
                    }
                    TextField(Loc.t("aws 경로", "aws path"), text: $store.settings.quota.awsExecutablePath,
                              prompt: Text(Loc.t("비워 두면 자동으로 찾아요", "Leave empty to find it automatically")))
                }
            }
        } header: {
            ProviderHeader(id: .bedrock, settings: store.settings.quota, report: quota.reports[.bedrock])
        }
    }

    // MARK: Refresh

    private var refreshSection: some View {
        Section(Loc.t("새로고침", "Refresh")) {
            SettingsCaption(Loc.t("AI 사용량은 메뉴를 열 때 새로 읽어요. 배터리를 아끼려고 백그라운드에서 주기적으로 읽지 않아요.",
                                  "AI usage is read when you open the menu; it isn't polled in the background, to save battery."))
            HStack {
                Button(Loc.t("지금 새로고침", "Refresh Now")) { quota.refresh() }
                    .disabled(quota.isRefreshing)
                if quota.isRefreshing {
                    ProgressView().controlSize(.small)
                }
            }
            DisclosureGroup(Loc.t("데이터 상태", "Data status")) {
                ForEach(ProviderID.allCases) { id in
                    ProviderResultDisclosure(id: id,
                                             enabled: QuotaCoordinator.isEnabled(id, in: store.settings.quota),
                                             report: quota.reports[id])
                }
            }
        }
    }
}

private struct ProviderHeader: View {
    let id: ProviderID
    let settings: QuotaSettings
    let report: ProviderReport?

    var body: some View {
        HStack {
            Text(id.displayName)
            Spacer()
            if !QuotaCoordinator.isEnabled(id, in: settings) {
                Text(Loc.t("꺼짐", "Off")).foregroundStyle(.secondary)
            } else if let report {
                Text(report.statusSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

private struct ProviderResultDisclosure: View {
    let id: ProviderID
    let enabled: Bool
    let report: ProviderReport?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                if let error = report?.error {
                    Text(error.message).foregroundStyle(.orange)
                    if let hint = error.fixHint { Text(hint).foregroundStyle(.secondary) }
                }
                if let attempts = report?.attempts, !attempts.isEmpty {
                    ForEach(Array(attempts.enumerated()), id: \.offset) { _, attempt in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: attempt.succeeded ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(attempt.succeeded ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(attempt.source) · \(attempt.trust.label)")
                                if let message = attempt.message, !message.isEmpty {
                                    Text(message).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Text(Loc.t("시도 기록 없음", "No attempts recorded")).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(id.displayName)
                Spacer()
                Text(enabled ? (report?.statusSummary ?? Loc.t("아직 없음", "Not yet")) : Loc.t("꺼짐", "Off"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
