import Foundation
import GoRunnerCore

/// Everything the fetcher touches, injectable for tests.
struct ClaudeUsageEnvironment: Sendable {
    var installer: ClaudeStatuslineInstaller
    var projectsRoots: [URL]
    var logIndex: ClaudeLogIndex
    var oauthGate: ClaudeOAuthGate
    var oauthClient: ClaudeOAuthClient
    var now: @Sendable () -> Date
    /// Per-source deadline; sources run concurrently so `fetch` finishes within this plus merging.
    var sourceTimeout: TimeInterval = 27
    var calendar: Calendar = .current

    static var live: ClaudeUsageEnvironment {
        ClaudeUsageEnvironment(installer: .standard, projectsRoots: defaultProjectsRoots(), logIndex: .shared,
                               oauthGate: .shared, oauthClient: .live, now: { Date() })
    }

    /// `$CLAUDE_CONFIG_DIR/projects` (comma-separated allowed), `~/.claude/projects`, `~/.config/claude/projects`.
    static func defaultProjectsRoots(environment: [String: String] = ProcessInfo.processInfo.environment,
                                     home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var roots: [URL] = []
        if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
            for part in configured.split(separator: ",") {
                let path = (String(part).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
                if !path.isEmpty { roots.append(URL(fileURLWithPath: path).appendingPathComponent("projects")) }
            }
        }
        roots.append(home.appendingPathComponent(".claude/projects"))
        roots.append(home.appendingPathComponent(".config/claude/projects"))
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }
}

struct ClaudeUsageFetcher: Sendable {
    static let logFileLookback: TimeInterval = 8 * 86400

    let environment: ClaudeUsageEnvironment

    func fetch(settings: QuotaSettings) async -> ProviderReport {
        guard settings.claudeEnabled else {
            return ProviderReport(provider: .claude, snapshot: nil,
                                  error: ProviderError(kind: .notConfigured, message: Loc.t("비활성화됨", "Disabled")),
                                  attempts: [])
        }
        let env = environment
        let now = env.now()

        async let statusline = Self.run(settings.claudeStatuslineSource, timeout: env.sourceTimeout) {
            ClaudeStatuslineSource.read(fileURL: env.installer.statuslineFile, hookInstalled: env.installer.isInstalled, now: now)
        }
        async let oauth = Self.run(settings.claudeOAuthSource, timeout: env.sourceTimeout) {
            await env.oauthGate.fetch(now: now) { await env.oauthClient.fetchUsage(now: now) }
        }
        async let logs = Self.run(settings.claudeLocalLogsSource, timeout: env.sourceTimeout) {
            await Self.localLogs(env: env, now: now)
        }

        var outcomes: [(source: ClaudeSource, outcome: SourceOutcome)] = []
        if let value = await statusline { outcomes.append((.statusline, value)) }
        if let value = await oauth { outcomes.append((.oauth, value)) }
        if let value = await logs { outcomes.append((.localLogs, value)) }

        return ClaudeReportMerger.merge(outcomes, hookInstalled: env.installer.isInstalled,
                                        statuslineEnabled: settings.claudeStatuslineSource, fetchedAt: now)
    }

    static func localLogs(env: ClaudeUsageEnvironment, now: Date) async -> SourceOutcome {
        let snapshot = await env.logIndex.refresh(roots: env.projectsRoots, modifiedSince: now.addingTimeInterval(-logFileLookback))
        guard snapshot.existingRootCount > 0 else {
            return .failure(ProviderError(kind: .notConfigured,
                                          message: Loc.t("Claude Code 로그 폴더(~/.claude/projects)가 없습니다", "No Claude Code log folder (~/.claude/projects)"),
                                          fixHint: Loc.t("Claude Code를 설치하고 한 번 실행하세요", "Install and run Claude Code once")))
        }
        return ClaudeLogSummarizer.summarize(snapshot.entries, now: now, calendar: env.calendar)
    }

    private static func run(_ enabled: Bool, timeout: TimeInterval,
                            _ operation: @escaping @Sendable () async -> SourceOutcome) async -> SourceOutcome? {
        guard enabled else { return nil }
        return await withDeadline(seconds: timeout, operation: operation) {
            .failure(ProviderError(kind: .timeout, message: Loc.t("응답 시간 초과", "Timed out")))
        }
    }
}

enum ClaudeReportMerger {
    private static let order: [ClaudeSource] = [.statusline, .oauth, .localLogs]

    static func merge(_ outcomes: [(source: ClaudeSource, outcome: SourceOutcome)], hookInstalled: Bool,
                      statuslineEnabled: Bool, fetchedAt: Date) -> ProviderReport {
        let attempts = outcomes.map { item in
            SourceAttempt(source: item.source.attemptName, trust: item.source.trust,
                          succeeded: item.outcome.result != nil,
                          message: item.outcome.result?.message ?? item.outcome.error?.message)
        }

        var successes: [ClaudeSource: SourceResult] = [:]
        for item in outcomes {
            if let result = item.outcome.result { successes[item.source] = result }
        }
        guard !successes.isEmpty else {
            let failures = outcomes.compactMap { item in item.outcome.error.map { (item.source, $0) } }
            return ProviderReport(provider: .claude, snapshot: nil,
                                  error: bestError(failures, hookInstalled: hookInstalled, statuslineEnabled: statuslineEnabled),
                                  attempts: attempts)
        }

        var used: [ClaudeSource] = []
        var windows: [QuotaWindow] = []
        var dataAsOf: Date?

        // Windows from the highest-trust source that has any; OAuth adds its extra windows (Opus/Sonnet weekly…).
        if let primary = order.first(where: { !(successes[$0]?.windows.isEmpty ?? true) }), let result = successes[primary] {
            windows = result.windows
            dataAsOf = result.dataAsOf
            used.append(primary)
            if primary == .statusline, let oauth = successes[.oauth] {
                let extra = oauth.windows.filter { candidate in !windows.contains { $0.id == candidate.id } }
                if !extra.isEmpty {
                    windows += extra
                    used.append(.oauth)
                }
            }
        }

        let planLabel = successes[.oauth]?.planLabel
        if planLabel != nil, !used.contains(.oauth) { used.append(.oauth) }

        var tokens: TokenSummary?
        var spend: [SpendLine] = []
        if let logs = successes[.localLogs] {
            tokens = logs.tokens
            spend = logs.spend
            if !used.contains(.localLogs) { used.append(.localLogs) }
            if dataAsOf == nil { dataAsOf = logs.dataAsOf }
        }

        used.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        var notes = used.flatMap { successes[$0]?.notes ?? [] }
        let hasLimitWindows = windows.contains { $0.usedFraction != nil }
        if !hasLimitWindows, statuslineEnabled,
           outcomes.first(where: { $0.source == .statusline })?.outcome.error?.kind == .notConfigured {
            notes.append(Loc.t("statusline 훅을 설치하면 실제 5시간·주간 한도(%)를 볼 수 있습니다",
                               "Install the statusline hook to see the real 5-hour and weekly limits (%)"))
        }

        let snapshot = QuotaSnapshot(provider: .claude, planLabel: planLabel, windows: windows, spend: spend, tokens: tokens,
                                     sourceName: used.map(\.displayName).joined(separator: " + "),
                                     trust: used.map(\.trust).max() ?? .heuristic,
                                     fetchedAt: fetchedAt, dataAsOf: dataAsOf, notes: notes)
        return ProviderReport(provider: .claude, snapshot: snapshot, error: nil, attempts: attempts)
    }

    static func bestError(_ failures: [(ClaudeSource, ProviderError)], hookInstalled: Bool, statuslineEnabled: Bool) -> ProviderError {
        guard !failures.isEmpty else {
            return ProviderError(kind: .notConfigured,
                                 message: Loc.t("켜진 Claude 데이터 소스가 없습니다", "No Claude data source is enabled"),
                                 fixHint: Loc.t("설정 → AI 서비스에서 소스를 켜세요", "Enable a source in Settings → AI Services"))
        }
        let actionable: [ProviderError.Kind] = [.authExpired, .authMissing, .permissionDenied, .rateLimited]
        if let oauth = failures.first(where: { $0.0 == .oauth })?.1, actionable.contains(oauth.kind) {
            return oauth
        }
        let logsKind = failures.first(where: { $0.0 == .localLogs })?.1.kind
        let logsHaveNoData = logsKind == nil || logsKind == .noRecentData || logsKind == .notConfigured
        if statuslineEnabled, !hookInstalled, logsHaveNoData {
            return ProviderError(kind: .notConfigured,
                                 message: Loc.t("Claude 사용량 데이터가 없습니다", "No Claude usage data"),
                                 fixHint: ClaudeHints.installHook)
        }
        let rank: [ProviderError.Kind] = [.authExpired, .authMissing, .permissionDenied, .rateLimited, .timeout, .network,
                                          .schemaChanged, .toolNotFound, .other, .noRecentData, .notConfigured]
        func position(_ error: ProviderError) -> Int { rank.firstIndex(of: error.kind) ?? rank.count }
        return failures.map(\.1).min { position($0) < position($1) } ?? failures[0].1
    }
}
