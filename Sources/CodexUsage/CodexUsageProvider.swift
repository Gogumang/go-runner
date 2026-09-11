import Foundation
import GoRunnerCore

// FACADE — the public API below is a contract used by GoRunnerApp. Keep these signatures; add more if needed.

/// Codex (ChatGPT plan) usage.
/// 1. `codex app-server` JSON-RPC `account/rateLimits/read` — live, trust `.openInterface`.
/// 2. `~/.codex/sessions/**/rollout-*.jsonl` `token_count` events — as of the last turn, trust `.heuristic`.
/// App-server windows win. Session logs are read only when app-server gives no limit windows, so a normal refresh
/// doesn't scan up to 128 MB of logs for token totals the menu no longer shows.
public struct CodexUsageProvider: UsageProvider {
    public let id = ProviderID.codex

    private let makeAppServerClient: @Sendable (QuotaSettings) -> CodexAppServerClient
    private let sessionLogReader: CodexSessionLogReader
    private let now: @Sendable () -> Date

    public init() {
        self.init(appServerClient: { CodexAppServerClient(executableOverride: $0.codexExecutablePath) },
                  sessionLogReader: CodexSessionLogReader())
    }

    init(appServerClient: @escaping @Sendable (QuotaSettings) -> CodexAppServerClient,
         sessionLogReader: CodexSessionLogReader,
         now: @escaping @Sendable () -> Date = { Date() }) {
        makeAppServerClient = appServerClient
        self.sessionLogReader = sessionLogReader
        self.now = now
    }

    public func fetch(settings: QuotaSettings) async -> ProviderReport {
        guard settings.codexEnabled else {
            return ProviderReport(provider: .codex, snapshot: nil,
                                  error: ProviderError(kind: .notConfigured,
                                                       message: Loc.t("Codex 사용량 모니터링이 꺼져 있습니다", "Codex usage monitoring is off")),
                                  attempts: [])
        }
        guard settings.codexAppServerSource || settings.codexSessionLogsSource else {
            return ProviderReport(provider: .codex, snapshot: nil,
                                  error: ProviderError(kind: .notConfigured,
                                                       message: Loc.t("Codex 데이터 소스가 모두 꺼져 있습니다", "All Codex data sources are off")),
                                  attempts: [])
        }
        let fetchedAt = now()
        let appServer = await Self.runAppServer(enabled: settings.codexAppServerSource, client: makeAppServerClient(settings))
        var sessionLogs: Result<CodexSessionLogResult, ProviderError>?
        if case .success(let result)? = appServer,
           !CodexSnapshotBuilder.appServerSnapshot(result, now: fetchedAt).windows.isEmpty {
            sessionLogs = nil
        } else {
            sessionLogs = await Self.runSessionLogs(enabled: settings.codexSessionLogsSource, reader: sessionLogReader, now: fetchedAt)
        }
        return Self.merge(appServer: appServer, sessionLogs: sessionLogs, now: fetchedAt)
    }

    private static func runAppServer(enabled: Bool, client: CodexAppServerClient) async -> Result<CodexAppServerResult, ProviderError>? {
        guard enabled else { return nil }
        return await client.fetch()
    }

    private static func runSessionLogs(enabled: Bool, reader: CodexSessionLogReader,
                                       now: Date) async -> Result<CodexSessionLogResult, ProviderError>? {
        guard enabled else { return nil }
        return await Task.detached(priority: .utility) { reader.read(now: now) }.value
    }

    static func merge(appServer: Result<CodexAppServerResult, ProviderError>?,
                      sessionLogs: Result<CodexSessionLogResult, ProviderError>?,
                      now: Date) -> ProviderReport {
        var attempts: [SourceAttempt] = []
        var appSnapshot: QuotaSnapshot?
        var appError: ProviderError?
        var logSnapshot: QuotaSnapshot?
        var logError: ProviderError?

        switch appServer {
        case let .success(result)?:
            let snapshot = CodexSnapshotBuilder.appServerSnapshot(result, now: now)
            appSnapshot = snapshot
            attempts.append(SourceAttempt(source: CodexSnapshotBuilder.appServerSourceName, trust: .openInterface,
                                          succeeded: true, message: summary(of: snapshot)))
        case let .failure(error)?:
            appError = error
            attempts.append(SourceAttempt(source: CodexSnapshotBuilder.appServerSourceName, trust: .openInterface,
                                          succeeded: false, message: error.message))
        case nil:
            break
        }

        switch sessionLogs {
        case let .success(result)?:
            let snapshot = CodexSnapshotBuilder.sessionLogSnapshot(result, now: now)
            logSnapshot = snapshot
            attempts.append(SourceAttempt(source: CodexSnapshotBuilder.sessionLogsSourceName, trust: .heuristic,
                                          succeeded: true, message: summary(of: snapshot)))
        case let .failure(error)?:
            logError = error
            attempts.append(SourceAttempt(source: CodexSnapshotBuilder.sessionLogsSourceName, trust: .heuristic,
                                          succeeded: false, message: error.message))
        case nil:
            break
        }

        if var snapshot = appSnapshot, !snapshot.windows.isEmpty || (logSnapshot?.windows.isEmpty ?? true) {
            snapshot.tokens = logSnapshot?.tokens
            return ProviderReport(provider: .codex, snapshot: snapshot, error: nil, attempts: attempts)
        }
        if var snapshot = logSnapshot {
            if snapshot.planLabel == nil { snapshot.planLabel = appSnapshot?.planLabel }
            if let appError {
                snapshot.notes.append(Loc.t("app-server 사용 불가: ", "app-server unavailable: ") + appError.message)
            }
            // Tokens alone are not a quota: keep the actionable app-server error visible.
            let error = snapshot.windows.isEmpty ? appError : nil
            return ProviderReport(provider: .codex, snapshot: snapshot, error: error, attempts: attempts)
        }
        let error = appError ?? logError
            ?? ProviderError(kind: .noRecentData, message: Loc.t("Codex 사용량 데이터가 없습니다", "No Codex usage data"))
        return ProviderReport(provider: .codex, snapshot: nil, error: error, attempts: attempts)
    }

    private static func summary(of snapshot: QuotaSnapshot) -> String {
        var parts = snapshot.windows.map { window in
            "\(window.label) \(window.usedFraction.map(MetricFormat.shortPercent) ?? "–")"
        }
        if let tokens = snapshot.tokens { parts.append(Loc.t("오늘 \(MetricFormat.tokens(tokens.total)) 토큰", "today \(MetricFormat.tokens(tokens.total)) tokens")) }
        return parts.isEmpty ? Loc.t("데이터 없음", "no data") : parts.joined(separator: ", ")
    }
}
