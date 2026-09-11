import Foundation

// MARK: - Provider identity and trust

public enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude, codex, bedrock

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .bedrock: "Bedrock"
        }
    }
}

/// How much a data source can be trusted. Higher wins when several sources report the same window.
public enum SourceTrust: Int, Codable, Sendable, Comparable {
    /// Estimated from local logs (tokens, cost) — no real limit percentage.
    case heuristic = 0
    /// Undocumented endpoint (opt-in only).
    case undocumented = 1
    /// Open-source tool interface, e.g. `codex app-server`.
    case openInterface = 2
    /// Documented API or hook.
    case official = 3

    public static func < (lhs: SourceTrust, rhs: SourceTrust) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .heuristic: Loc.t("추정", "Estimate")
        case .undocumented: Loc.t("비공개 API", "Undocumented")
        case .openInterface: Loc.t("오픈소스 인터페이스", "Open interface")
        case .official: Loc.t("공식", "Official")
        }
    }
}

// MARK: - Snapshot

public struct QuotaWindow: Sendable, Equatable, Identifiable, Codable {
    /// Stable key, e.g. "five_hour", "seven_day", "seven_day_opus", "bedrock_tpm:<modelId>".
    public var id: String
    /// Display label, e.g. "5시간", "주간", "TPM · Opus 5".
    public var label: String
    /// 0...1 (may exceed 1 when over the limit). nil when only tokens/cost are known.
    public var usedFraction: Double?
    public var resetsAt: Date?
    /// Extra line, e.g. "1.2M tokens" or "12,400 / 200,000 TPM".
    public var detail: String?

    public init(id: String, label: String, usedFraction: Double?, resetsAt: Date? = nil, detail: String? = nil) {
        self.id = id
        self.label = label
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.detail = detail
    }
}

public struct SpendLine: Sendable, Equatable, Codable {
    public var label: String
    public var amountUSD: Double
    public var isEstimate: Bool

    public init(label: String, amountUSD: Double, isEstimate: Bool) {
        self.label = label
        self.amountUSD = amountUSD
        self.isEstimate = isEstimate
    }
}

public struct TokenSummary: Sendable, Equatable, Codable {
    public var input: Int
    public var output: Int
    public var cacheCreation: Int
    public var cacheRead: Int
    public var estimatedCostUSD: Double?

    public init(input: Int = 0, output: Int = 0, cacheCreation: Int = 0, cacheRead: Int = 0, estimatedCostUSD: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.estimatedCostUSD = estimatedCostUSD
    }

    public var total: Int { input + output + cacheCreation + cacheRead }
}

public struct QuotaSnapshot: Sendable, Equatable, Codable {
    public var provider: ProviderID
    /// e.g. "Max", "Pro", "us-east-1".
    public var planLabel: String?
    public var windows: [QuotaWindow]
    public var spend: [SpendLine]
    public var tokens: TokenSummary?
    /// Human readable source, e.g. "Claude Code statusline".
    public var sourceName: String
    public var trust: SourceTrust
    /// When GoRunner fetched it.
    public var fetchedAt: Date
    /// When the underlying data was produced (e.g. last Claude Code session), if known.
    public var dataAsOf: Date?
    public var notes: [String]

    public init(provider: ProviderID, planLabel: String? = nil, windows: [QuotaWindow] = [], spend: [SpendLine] = [],
                tokens: TokenSummary? = nil, sourceName: String, trust: SourceTrust, fetchedAt: Date = Date(),
                dataAsOf: Date? = nil, notes: [String] = []) {
        self.provider = provider
        self.planLabel = planLabel
        self.windows = windows
        self.spend = spend
        self.tokens = tokens
        self.sourceName = sourceName
        self.trust = trust
        self.fetchedAt = fetchedAt
        self.dataAsOf = dataAsOf
        self.notes = notes
    }

    /// Highest used fraction across windows — used for the menu bar badge.
    public var peakUsedFraction: Double? {
        windows.compactMap(\.usedFraction).max()
    }
}

// MARK: - Errors and reports

public struct ProviderError: Error, Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case notConfigured, authMissing, authExpired, permissionDenied, rateLimited
        case toolNotFound, schemaChanged, noRecentData, network, timeout, other
    }

    public var kind: Kind
    public var message: String
    /// Actionable fix, e.g. "터미널에서 `aws sso login --profile work` 실행".
    public var fixHint: String?

    public init(kind: Kind, message: String, fixHint: String? = nil) {
        self.kind = kind
        self.message = message
        self.fixHint = fixHint
    }
}

public struct SourceAttempt: Sendable, Equatable, Codable {
    public var source: String
    public var trust: SourceTrust
    public var succeeded: Bool
    public var message: String?

    public init(source: String, trust: SourceTrust, succeeded: Bool, message: String? = nil) {
        self.source = source
        self.trust = trust
        self.succeeded = succeeded
        self.message = message
    }
}

/// Result of one provider refresh. `snapshot` is the merged best data; `error` is set when nothing usable was found.
public struct ProviderReport: Sendable, Equatable {
    public var provider: ProviderID
    public var snapshot: QuotaSnapshot?
    public var error: ProviderError?
    public var attempts: [SourceAttempt]

    public init(provider: ProviderID, snapshot: QuotaSnapshot?, error: ProviderError?, attempts: [SourceAttempt]) {
        self.provider = provider
        self.snapshot = snapshot
        self.error = error
        self.attempts = attempts
    }
}

// MARK: - Provider contract

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    /// Tries the enabled sources in trust order and returns what it found. Must not throw and must
    /// finish within ~30 s (enforce your own timeouts). Never writes or refreshes other tools' credentials.
    func fetch(settings: QuotaSettings) async -> ProviderReport
}

// MARK: - Settings

public struct QuotaSettings: Codable, Sendable, Equatable {
    // Claude
    public var claudeEnabled = true
    /// Read rate limits written by the GoRunner statusline hook (official Claude Code statusline JSON).
    public var claudeStatuslineSource = true
    /// Undocumented `api.anthropic.com/api/oauth/usage` using Claude Code's Keychain credential. Opt-in.
    public var claudeOAuthSource = false
    /// Parse `~/.claude/projects/**/*.jsonl` for tokens / estimated cost.
    public var claudeLocalLogsSource = true

    // Codex
    public var codexEnabled = true
    public var codexAppServerSource = true
    public var codexSessionLogsSource = true
    /// Optional absolute path override for the `codex` executable.
    public var codexExecutablePath = ""

    // Bedrock
    public var bedrockEnabled = false
    public var awsProfile = "default"
    public var awsRegion = "us-east-1"
    /// Empty = discover models that had invocations in the last 24 h.
    public var bedrockModelIDs: [String] = []
    /// Cost Explorer costs $0.01 per request; polled at most every 6 h when enabled.
    public var bedrockCostExplorer = false
    /// Optional absolute path override for the `aws` executable.
    public var awsExecutablePath = ""

    public init() {}
}
