import Foundation
import GoRunnerCore

// FACADE — the public API below is a contract used by GoRunnerApp. Keep these signatures; add more if needed.
// (`AWSProfiles` lives in AWSProfiles.swift.)

/// AWS Bedrock usage via the user's `aws` CLI:
/// STS identity → CloudWatch token metrics (per model) + Service Quotas TPM/RPM (+ optional Cost Explorer month to date).
/// See docs/research/04-ai-quota.md §4.
public struct BedrockUsageProvider: UsageProvider {
    public let id = ProviderID.bedrock

    let cacheDirectory: URL
    let now: @Sendable () -> Date
    let calendar: Calendar
    let baseEnvironment: [String: String]?
    /// Whole-fetch budget; each CLI call gets min(20 s, remaining).
    let totalBudget: TimeInterval

    static let maxModels = 70
    static let perCallTimeout: TimeInterval = 20
    static let modelsCacheAge: TimeInterval = 3600
    static let quotasCacheAge: TimeInterval = 24 * 3600
    static let costCacheAge: TimeInterval = 6 * 3600

    public init() {
        self.init(cacheDirectory: AppPaths.cacheDirectory)
    }

    init(cacheDirectory: URL, now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .current,
         baseEnvironment: [String: String]? = nil, totalBudget: TimeInterval = 28) {
        self.cacheDirectory = cacheDirectory
        self.now = now
        self.calendar = calendar
        self.baseEnvironment = baseEnvironment
        self.totalBudget = totalBudget
    }

    public func fetch(settings: QuotaSettings) async -> ProviderReport {
        guard settings.bedrockEnabled else {
            return ProviderReport(provider: .bedrock, snapshot: nil,
                                  error: ProviderError(kind: .notConfigured, message: Loc.t("비활성화됨 — 설정에서 켜세요", "Disabled — enable it in Settings")),
                                  attempts: [])
        }
        let profile = settings.awsProfile.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "default"
        let region = settings.awsRegion.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "us-east-1"
        let startedAt = now()
        let deadline = Date().addingTimeInterval(totalBudget)
        var attempts: [SourceAttempt] = []

        // 1. Locate the CLI.
        guard let executable = ExecutableLocator.locate("aws", override: settings.awsExecutablePath) else {
            let error = AWSErrorMapper.toolNotFound()
            attempts.append(SourceAttempt(source: "aws CLI", trust: .official, succeeded: false, message: error.message))
            return ProviderReport(provider: .bedrock, snapshot: nil, error: error, attempts: attempts)
        }
        attempts.append(SourceAttempt(source: "aws CLI", trust: .official, succeeded: true, message: executable.path))
        let cli = AWSCLI(executable: executable, profile: profile, region: region, baseEnvironment: baseEnvironment)
        let context = FetchContext(cli: cli, profile: profile, region: region, deadline: deadline, now: startedAt,
                                   cache: BedrockFileCache(directory: cacheDirectory), calendar: calendar)

        // 2. Identity (gates everything else; never report the account id or ARN).
        switch await context.call(["sts", "get-caller-identity"], permission: "sts:GetCallerIdentity", maxTimeout: 15) {
        case let .failure(error):
            attempts.append(SourceAttempt(source: "STS GetCallerIdentity", trust: .official, succeeded: false, message: error.message))
            return ProviderReport(provider: .bedrock, snapshot: nil, error: error, attempts: attempts)
        case .success:
            attempts.append(SourceAttempt(source: "STS GetCallerIdentity", trust: .official, succeeded: true, message: "profile \(profile)"))
        }

        // 3–7. Models → metrics, quotas and cost run concurrently.
        let configuredModels = settings.bedrockModelIDs
        let wantCost = settings.bedrockCostExplorer
        var usage = UsageStep()
        var quotas = QuotaStep()
        var cost = CostStep()
        await withTaskGroup(of: StepOutput.self) { group in
            group.addTask { .usage(await context.usageStep(configuredModels: configuredModels)) }
            group.addTask { .quotas(await context.quotaStep()) }
            if wantCost { group.addTask { .cost(await context.costStep()) } }
            for await output in group {
                switch output {
                case let .usage(step): usage = step
                case let .quotas(step): quotas = step
                case let .cost(step): cost = step
                }
            }
        }
        attempts += usage.attempts + quotas.attempts + cost.attempts

        var results = BedrockFetchResults(profile: profile, region: region, models: usage.models, recent: usage.recent,
                                          today: usage.today, quotas: quotas.quotas, monthToDateUSD: cost.amountUSD)
        results.notes = usage.notes + quotas.notes + cost.notes

        if let fatal = usage.error {
            let snapshot = cost.amountUSD == nil ? nil
                : BedrockSnapshotBuilder.build(BedrockFetchResults(profile: profile, region: region, models: [], recent: nil, today: nil,
                                                                   quotas: nil, monthToDateUSD: cost.amountUSD, notes: results.notes), now: startedAt)
            return ProviderReport(provider: .bedrock, snapshot: snapshot, error: fatal, attempts: attempts)
        }
        if usage.models.isEmpty, cost.amountUSD == nil {
            let error = ProviderError(kind: .noRecentData,
                                      message: Loc.t("최근 2주간 \(region)에서 Bedrock 호출 기록이 없습니다", "No Bedrock invocations in \(region) in the last 2 weeks"),
                                      fixHint: Loc.t("설정에서 프로필과 리전을 확인하세요", "Check the profile and region in Settings"))
            return ProviderReport(provider: .bedrock, snapshot: nil, error: error, attempts: attempts)
        }
        let snapshot = BedrockSnapshotBuilder.build(results, now: startedAt)
        return ProviderReport(provider: .bedrock, snapshot: snapshot, error: nil, attempts: attempts)
    }
}

// MARK: - Steps

private enum StepOutput: Sendable {
    case usage(UsageStep)
    case quotas(QuotaStep)
    case cost(CostStep)
}

struct UsageStep: Sendable {
    var models: [String] = []
    var recent: BedrockMetricData?
    var today: BedrockMetricData?
    var attempts: [SourceAttempt] = []
    var notes: [String] = []
    var error: ProviderError?
}

struct QuotaStep: Sendable {
    var quotas: [BedrockServiceQuota]?
    var attempts: [SourceAttempt] = []
    var notes: [String] = []
}

struct CostStep: Sendable {
    var amountUSD: Double?
    var attempts: [SourceAttempt] = []
    var notes: [String] = []
}

struct FetchContext: Sendable {
    let cli: AWSCLI
    let profile: String
    let region: String
    let deadline: Date
    let now: Date
    let cache: BedrockFileCache
    let calendar: Calendar

    func call(_ args: [String], region: String? = nil, permission: String?,
              maxTimeout: TimeInterval = BedrockUsageProvider.perCallTimeout) async -> Result<Data, ProviderError> {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining >= 2 else {
            return .failure(ProviderError(kind: .timeout, message: Loc.t("시간 예산 초과로 건너뜀", "Skipped: time budget exceeded")))
        }
        return await cli.run(args, region: region, timeout: min(maxTimeout, remaining), permission: permission)
    }

    // MARK: Models + metrics

    func usageStep(configuredModels: [String]) async -> UsageStep {
        var step = UsageStep()
        var models: [String]
        let configured = configuredModels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !configured.isEmpty {
            models = configured.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            step.attempts.append(SourceAttempt(source: "Model list (settings)", trust: .official, succeeded: true, message: "\(models.count)"))
        } else {
            switch await discoverModels() {
            case let .success((found, attempts)):
                models = found
                step.attempts += attempts
            case let .failure(failure):
                step.attempts += failure.attempts
                step.error = failure.error
                return step
            }
        }
        if models.count > BedrockUsageProvider.maxModels {
            step.notes.append(Loc.t("모델이 많아 \(BedrockUsageProvider.maxModels)개만 표시", "Showing the first \(BedrockUsageProvider.maxModels) models"))
            models = Array(models.prefix(BedrockUsageProvider.maxModels))
        }
        step.models = models
        guard !models.isEmpty else { return step }

        let minute = BedrockUsageMath.floorToMinute(now)
        let end = minute.addingTimeInterval(60)
        let recentStart = minute.addingTimeInterval(-3600)
        var todayStart = calendar.startOfDay(for: now)
        if end.timeIntervalSince(todayStart) < 120 { todayStart = end.addingTimeInterval(-120) }

        let queryModels = models
        let dayStart = todayStart
        async let recentResult = metricData(models: queryModels, metrics: BedrockMetric.allCases, period: 60, start: recentStart, end: end)
        async let todayResult = metricData(models: queryModels,
                                           metrics: [.inputTokens, .outputTokens, .cacheReadTokens, .cacheWriteTokens, .invocations],
                                           period: 3600, start: dayStart, end: end)
        let (recent, today) = await (recentResult, todayResult)

        switch recent {
        case let .success(data):
            step.recent = data
            step.attempts.append(SourceAttempt(source: "CloudWatch GetMetricData (1h)", trust: .official, succeeded: true,
                                               message: data.problems.isEmpty ? "\(models.count) models" : data.problems.joined(separator: ", ")))
        case let .failure(error):
            step.attempts.append(SourceAttempt(source: "CloudWatch GetMetricData (1h)", trust: .official, succeeded: false, message: error.message))
        }
        switch today {
        case let .success(data):
            step.today = data
            step.attempts.append(SourceAttempt(source: "CloudWatch GetMetricData (today)", trust: .official, succeeded: true))
        case let .failure(error):
            step.attempts.append(SourceAttempt(source: "CloudWatch GetMetricData (today)", trust: .official, succeeded: false, message: error.message))
        }
        if step.recent == nil, step.today == nil, case let .failure(error) = recent {
            step.error = error
        } else if step.recent == nil {
            step.notes.append(Loc.t("최근 1시간 지표를 읽지 못했습니다", "Could not read last-hour metrics"))
        } else if step.today == nil {
            step.notes.append(Loc.t("오늘 합계를 읽지 못했습니다", "Could not read today's totals"))
        }
        return step
    }

    struct DiscoveryFailure: Error {
        var error: ProviderError
        var attempts: [SourceAttempt]
    }

    func discoverModels() async -> Result<([String], [SourceAttempt]), DiscoveryFailure> {
        var attempts: [SourceAttempt] = []
        let base = ["cloudwatch", "list-metrics", "--namespace", "AWS/Bedrock", "--metric-name", "InputTokenCount"]
        switch await call(base + ["--recently-active", "PT3H"], permission: "cloudwatch:ListMetrics") {
        case let .failure(error):
            attempts.append(SourceAttempt(source: "CloudWatch ListMetrics (3h)", trust: .official, succeeded: false, message: error.message))
            return .failure(DiscoveryFailure(error: error, attempts: attempts))
        case let .success(data):
            let ids = (try? BedrockParsing.parseModelIDs(data)) ?? []
            attempts.append(SourceAttempt(source: "CloudWatch ListMetrics (3h)", trust: .official, succeeded: true, message: "\(ids.count) models"))
            if !ids.isEmpty { return .success((ids, attempts)) }
        }
        let cacheURL = cache.url("bedrock-models", profile: profile, region: region)
        if let cached = cache.load([String].self, from: cacheURL, maxAge: BedrockUsageProvider.modelsCacheAge, now: now) {
            attempts.append(SourceAttempt(source: "CloudWatch ListMetrics (cache)", trust: .official, succeeded: true, message: "\(cached.count) models"))
            return .success((cached, attempts))
        }
        switch await call(base, permission: "cloudwatch:ListMetrics") {
        case let .failure(error):
            attempts.append(SourceAttempt(source: "CloudWatch ListMetrics (2w)", trust: .official, succeeded: false, message: error.message))
            return .failure(DiscoveryFailure(error: error, attempts: attempts))
        case let .success(data):
            do {
                let ids = try BedrockParsing.parseModelIDs(data)
                cache.save(ids, to: cacheURL, now: now)
                attempts.append(SourceAttempt(source: "CloudWatch ListMetrics (2w)", trust: .official, succeeded: true, message: "\(ids.count) models"))
                return .success((ids, attempts))
            } catch {
                let providerError = ProviderError(kind: .schemaChanged, message: "list-metrics: \(error)")
                attempts.append(SourceAttempt(source: "CloudWatch ListMetrics (2w)", trust: .official, succeeded: false, message: providerError.message))
                return .failure(DiscoveryFailure(error: providerError, attempts: attempts))
            }
        }
    }

    func metricData(models: [String], metrics: [BedrockMetric], period: Int, start: Date, end: Date) async -> Result<BedrockMetricData, ProviderError> {
        let queries = BedrockParsing.metricQueries(models: models, metrics: metrics, period: period)
        guard let json = try? JSONSerialization.data(withJSONObject: queries) else {
            return .failure(ProviderError(kind: .other, message: "metric query encoding failed"))
        }
        // Process arguments bypass the shell, so inline JSON needs no quoting.
        let args = ["cloudwatch", "get-metric-data", "--metric-data-queries", String(decoding: json, as: UTF8.self),
                    "--start-time", BedrockParsing.isoString(start), "--end-time", BedrockParsing.isoString(end)]
        switch await call(args, permission: "cloudwatch:GetMetricData") {
        case let .failure(error):
            return .failure(error)
        case let .success(data):
            do {
                return .success(try BedrockParsing.parseMetricData(data, models: models))
            } catch {
                return .failure(ProviderError(kind: .schemaChanged, message: "get-metric-data: \(error)"))
            }
        }
    }

    // MARK: Service Quotas

    func quotaStep() async -> QuotaStep {
        var step = QuotaStep()
        let cacheURL = cache.url("bedrock-quotas", profile: profile, region: region)
        if let cached = cache.load([BedrockServiceQuota].self, from: cacheURL, maxAge: BedrockUsageProvider.quotasCacheAge, now: now) {
            step.quotas = cached
            step.attempts.append(SourceAttempt(source: "Service Quotas (cache)", trust: .official, succeeded: true, message: "\(cached.count) quotas"))
            return step
        }
        var all: [BedrockServiceQuota] = []
        var token: String?
        for _ in 0..<20 {
            var args = ["service-quotas", "list-service-quotas", "--service-code", "bedrock"]
            if let token { args += ["--starting-token", token] }
            switch await call(args, permission: "servicequotas:ListServiceQuotas") {
            case let .failure(error):
                step.attempts.append(SourceAttempt(source: "Service Quotas", trust: .official, succeeded: false, message: error.message))
                step.notes.append(Loc.t("쿼터를 읽지 못해 % 대신 토큰만 표시: \(error.message)", "Quotas unavailable, showing tokens only: \(error.message)"))
                return step
            case let .success(data):
                guard let page = try? BedrockParsing.parseQuotas(data) else {
                    step.attempts.append(SourceAttempt(source: "Service Quotas", trust: .official, succeeded: false, message: "unexpected JSON"))
                    return step
                }
                all += page
                token = BedrockParsing.nextToken(data)
            }
            if token == nil { break }
        }
        cache.save(all, to: cacheURL, now: now)
        step.quotas = all
        step.attempts.append(SourceAttempt(source: "Service Quotas", trust: .official, succeeded: true, message: "\(all.count) quotas"))
        return step
    }

    // MARK: Cost Explorer

    func costStep() async -> CostStep {
        var step = CostStep()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.calendar = utc
        formatter.timeZone = utc.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let monthStart = utc.date(from: utc.dateComponents([.year, .month], from: now)) ?? now
        let tomorrow = utc.date(byAdding: .day, value: 1, to: utc.startOfDay(for: now)) ?? now
        let startString = formatter.string(from: monthStart)
        let cacheURL = cache.url("bedrock-cost", profile: profile, region: nil)

        if let cached = cache.load(BedrockCostCacheEntry.self, from: cacheURL, maxAge: BedrockUsageProvider.costCacheAge, now: now, key: startString) {
            step.amountUSD = cached.amountUSD
            step.attempts.append(SourceAttempt(source: "Cost Explorer (cache)", trust: .official, succeeded: true))
            return step
        }
        let args = ["ce", "get-cost-and-usage", "--time-period", "Start=\(startString),End=\(formatter.string(from: tomorrow))",
                    "--granularity", "MONTHLY", "--metrics", "UnblendedCost", "--group-by", "Type=DIMENSION,Key=SERVICE"]
        switch await call(args, region: "us-east-1", permission: "ce:GetCostAndUsage") {
        case let .failure(error):
            step.attempts.append(SourceAttempt(source: "Cost Explorer", trust: .official, succeeded: false, message: error.message))
            step.notes.append(Loc.t("Cost Explorer 실패: \(error.message)", "Cost Explorer failed: \(error.message)"))
        case let .success(data):
            if let parsed = try? BedrockParsing.parseBedrockCost(data) {
                cache.save(BedrockCostCacheEntry(amountUSD: parsed.amount, services: parsed.services), to: cacheURL, now: now, key: startString)
                step.amountUSD = parsed.amount
                step.attempts.append(SourceAttempt(source: "Cost Explorer", trust: .official, succeeded: true, message: parsed.services.joined(separator: ", ")))
            } else {
                step.attempts.append(SourceAttempt(source: "Cost Explorer", trust: .official, succeeded: false, message: "unexpected JSON"))
            }
        }
        return step
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
