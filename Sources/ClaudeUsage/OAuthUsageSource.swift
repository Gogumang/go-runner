import Foundation
import GoRunnerCore

// Opt-in only (QuotaSettings.claudeOAuthSource). Undocumented endpoint used by Claude Code's `/usage`.
// Response shape verified against CodexBar `ClaudeOAuthUsageFetcher.swift` and ClaudeBar `ClaudeAPIUsageProbe.swift`
// (see docs/research/04-ai-quota.md §2.3). The access token is read from the Keychain for this one request,
// held only in local variables, and never refreshed, stored, logged or sent anywhere else.

// MARK: - Credential

struct ClaudeOAuthCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var accessToken: String
    var expiresAt: Date?
    var subscriptionType: String?
    var rateLimitTier: String?

    var description: String {
        "ClaudeOAuthCredential(token: <redacted>, expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"), plan: \(planLabel ?? "nil"))"
    }

    var debugDescription: String { description }

    var planLabel: String? { Self.planLabel(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier) }

    func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// Parses the Keychain item `Claude Code-credentials`: `{"claudeAiOauth": {"accessToken", "expiresAt" (ms), "subscriptionType", …}}`.
    static func parse(_ data: Data) -> Result<ClaudeOAuthCredential, ProviderError> {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return .failure(ProviderError(kind: .schemaChanged,
                                          message: Loc.t("Claude Code 자격 증명 형식을 읽을 수 없습니다", "Could not read the Claude Code credential format")))
        }
        guard let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            return .failure(ProviderError(kind: .authMissing,
                                          message: Loc.t("Claude.ai 로그인 정보가 없습니다", "No Claude.ai sign-in found"),
                                          fixHint: Loc.t("Claude Code에서 /login으로 Claude.ai 계정에 로그인하세요",
                                                         "Sign in to your Claude.ai account with /login in Claude Code")))
        }
        let expiresAt = JSONValue.double(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        return .success(ClaudeOAuthCredential(accessToken: token, expiresAt: expiresAt,
                                              subscriptionType: oauth["subscriptionType"] as? String,
                                              rateLimitTier: oauth["rateLimitTier"] as? String))
    }

    /// "max" → "Max" (or "Max 20x" / "Max 5x" when the rate-limit tier says so), "pro" → "Pro".
    static func planLabel(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        switch lower {
        case "max":
            let tier = rateLimitTier?.lowercased() ?? ""
            if tier.contains("20x") { return "Max 20x" }
            if tier.contains("5x") { return "Max 5x" }
            return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

enum ClaudeKeychainCredential {
    static let service = "Claude Code-credentials"
    static let timeout: TimeInterval = 15

    /// `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`. May show a Keychain prompt.
    static func load() async -> Result<Data, ProviderError> {
        do {
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/security"),
                                                     arguments: ["find-generic-password", "-s", service, "-w"],
                                                     timeout: timeout,
                                                     environment: ProcessInfo.processInfo.environment)
            switch result.exitCode {
            case 0:
                return .success(result.stdout)
            case 44: // errSecItemNotFound
                return .failure(ProviderError(kind: .authMissing,
                                              message: Loc.t("키체인에 Claude Code 자격 증명이 없습니다", "No Claude Code credential in the Keychain"),
                                              fixHint: Loc.t("Claude Code에서 /login으로 로그인하세요", "Sign in with /login in Claude Code")))
            default:
                return .failure(ProviderError(kind: .permissionDenied,
                                              message: Loc.t("키체인에서 Claude Code 자격 증명을 읽지 못했습니다 (코드 \(result.exitCode))",
                                                             "Could not read the Claude Code credential from the Keychain (code \(result.exitCode))"),
                                              fixHint: Loc.t("키체인 접근 요청에서 '허용'을 선택하세요", "Choose Allow in the Keychain prompt")))
            }
        } catch ProcessRunnerError.timeout {
            return .failure(ProviderError(kind: .timeout,
                                          message: Loc.t("키체인 응답 시간 초과", "Keychain request timed out"),
                                          fixHint: Loc.t("키체인 접근 요청 창이 떠 있는지 확인하세요", "Check for a pending Keychain prompt")))
        } catch {
            return .failure(ProviderError(kind: .other, message: Loc.t("security 실행 실패", "Failed to run security")))
        }
    }
}

// MARK: - Response

enum ClaudeOAuthUsageParser {
    static func parse(_ data: Data, now: Date) -> SourceOutcome {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(schemaChanged)
        }
        var windows: [QuotaWindow] = []
        var notes: [String] = []

        for id in [ClaudeWindow.fiveHour, ClaudeWindow.sevenDay, ClaudeWindow.sevenDayOpus, ClaudeWindow.sevenDaySonnet] {
            guard let raw = root[id] as? [String: Any], let utilization = JSONValue.double(raw["utilization"]) else { continue }
            windows.append(ClaudeWindow.make(id: id, percent: utilization, resetsAt: date(raw["resets_at"]), now: now, notes: &notes))
        }

        // Newer `limits[]` entries scoped to a model (e.g. "Fable") that have no flat `seven_day_*` key.
        for entry in root["limits"] as? [[String: Any]] ?? [] {
            let group = ((entry["group"] as? String) ?? (entry["kind"] as? String) ?? "").lowercased()
            guard group.contains("week"), (entry["is_active"] as? Bool) != false,
                  let name = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String,
                  !name.isEmpty, let percent = JSONValue.double(entry["percent"])
            else { continue }
            let id = "seven_day_" + slug(name)
            guard !windows.contains(where: { $0.id == id }) else { continue }
            windows.append(ClaudeWindow.make(id: id, label: Loc.t("\(name) 주간", "\(name) weekly"), percent: percent,
                                             resetsAt: date(entry["resets_at"]), now: now, notes: &notes))
        }

        if let extra = root["extra_usage"] as? [String: Any], (extra["is_enabled"] as? Bool) == true,
           let window = extraUsageWindow(extra) {
            windows.append(window)
        }

        guard !windows.isEmpty else { return .failure(schemaChanged) }
        return .success(SourceResult(windows: windows, dataAsOf: now, notes: notes))
    }

    /// `used_credits` / `monthly_limit` are minor units (`decimal_places`, default 2 → cents), as ClaudeBar decodes them.
    static func extraUsageWindow(_ extra: [String: Any]) -> QuotaWindow? {
        let places = JSONValue.double(extra["decimal_places"]) ?? 2
        let divisor = pow(10, max(0, places))
        let used = JSONValue.double(extra["used_credits"]).map { $0 / divisor }
        let limit = JSONValue.double(extra["monthly_limit"]).map { $0 / divisor }
        var fraction = JSONValue.double(extra["utilization"]).map { max(0, $0) / 100 }
        if fraction == nil, let used, let limit, limit > 0 { fraction = used / limit }
        guard fraction != nil || used != nil else { return nil }

        let currency = (extra["currency"] as? String)?.uppercased() ?? "USD"
        func money(_ amount: Double) -> String {
            currency == "USD" ? String(format: "$%.2f", amount) : String(format: "%.2f %@", amount, currency)
        }
        var detail: String?
        if let used, let limit { detail = "\(money(used)) / \(money(limit))" } else if let used { detail = money(used) }
        return QuotaWindow(id: ClaudeWindow.extraUsage, label: ClaudeWindow.label(for: ClaudeWindow.extraUsage),
                           usedFraction: fraction, resetsAt: nil, detail: detail)
    }

    private static var schemaChanged: ProviderError {
        ProviderError(kind: .schemaChanged,
                      message: Loc.t("OAuth 사용량 응답 형식이 바뀌었습니다", "The OAuth usage response format changed"))
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap(ClaudeTimestamp.parse)
    }

    private static func slug(_ name: String) -> String {
        String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }
}

// MARK: - Client

struct ClaudeOAuthClient: Sendable {
    typealias CredentialLoader = @Sendable () async -> Result<Data, ProviderError>
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"
    static let requestTimeout: TimeInterval = 15

    var loadCredential: CredentialLoader
    var transport: Transport
    var appVersion: String = AppIdentity.version

    static func makeRequest(accessToken: String, appVersion: String) -> URLRequest {
        var request = URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("GoRunner/\(appVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }

    func fetchUsage(now: Date) async -> SourceOutcome {
        let credential: ClaudeOAuthCredential
        switch await loadCredential() {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            switch ClaudeOAuthCredential.parse(data) {
            case .failure(let error): return .failure(error)
            case .success(let parsed): credential = parsed
            }
        }
        guard !credential.isExpired(now: now) else {
            return .failure(ProviderError(kind: .authExpired,
                                          message: Loc.t("Claude Code 로그인 토큰이 만료되었습니다", "The Claude Code sign-in token has expired"),
                                          fixHint: ClaudeHints.refreshToken))
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(Self.makeRequest(accessToken: credential.accessToken, appVersion: appVersion))
        } catch let error as URLError where error.code == .timedOut {
            return .failure(ProviderError(kind: .timeout, message: Loc.t("OAuth 사용량 요청 시간 초과", "OAuth usage request timed out")))
        } catch {
            return .failure(ProviderError(kind: .network,
                                          message: Loc.t("OAuth 사용량 요청 실패: \(error.localizedDescription)",
                                                         "OAuth usage request failed: \(error.localizedDescription)")))
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            guard case .success(var result) = ClaudeOAuthUsageParser.parse(data, now: now) else {
                return ClaudeOAuthUsageParser.parse(data, now: now)
            }
            result.planLabel = credential.planLabel
            return .success(result)
        case 401:
            return .failure(ProviderError(kind: .authExpired,
                                          message: Loc.t("OAuth 토큰이 거부되었습니다 (401)", "The OAuth token was rejected (401)"),
                                          fixHint: ClaudeHints.refreshToken))
        case 403:
            return .failure(ProviderError(kind: .permissionDenied,
                                          message: Loc.t("토큰에 사용량 조회 권한이 없습니다 (403)", "The token cannot read usage (403)"),
                                          fixHint: Loc.t("Claude Code에서 /login으로 다시 로그인하세요", "Sign in again with /login in Claude Code")))
        case 429:
            return .failure(ProviderError(kind: .rateLimited,
                                          message: Loc.t("요청이 너무 많습니다 (429) — 10분 후 다시 시도합니다",
                                                         "Too many requests (429) — retrying in 10 minutes")))
        default:
            return .failure(ProviderError(kind: .network, message: "HTTP \(status)"))
        }
    }
}

extension ClaudeOAuthClient {
    /// Ephemeral session: no cookies, no URL cache, nothing persisted under HTTPStorages.
    static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration)
    }()

    static var live: ClaudeOAuthClient {
        ClaudeOAuthClient(loadCredential: { await ClaudeKeychainCredential.load() },
                          transport: { request in try await liveSession.data(for: request) })
    }
}

// MARK: - Gate (shared across provider instances)

/// Minimum 5 minutes between endpoint calls (served from cache) and a 10-minute pause after HTTP 429.
/// Caches only the parsed result — never the token.
actor ClaudeOAuthGate {
    static let shared = ClaudeOAuthGate()
    static let minimumInterval: TimeInterval = 5 * 60
    static let rateLimitCooldown: TimeInterval = 10 * 60

    private var lastCallAt: Date?
    private var lastOutcome: SourceOutcome?
    private var rateLimitedUntil: Date?
    private var inFlight: Task<SourceOutcome, Never>?

    func fetch(now: Date, call: @escaping @Sendable () async -> SourceOutcome) async -> SourceOutcome {
        if let until = rateLimitedUntil, now < until {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let time = formatter.string(from: until)
            return .failure(ProviderError(kind: .rateLimited,
                                          message: Loc.t("429 이후 대기 중 — \(time) 이후 다시 시도", "Rate limited (429) — next try after \(time)")))
        }
        if let inFlight {
            return await inFlight.value
        }
        if let lastCallAt, let lastOutcome, now.timeIntervalSince(lastCallAt) < Self.minimumInterval {
            guard case .success(var cached) = lastOutcome else { return lastOutcome }
            cached.message = Loc.t("캐시됨 (\(MetricFormat.age(lastCallAt, now: now)))", "cached (\(MetricFormat.age(lastCallAt, now: now)))")
            return .success(cached)
        }

        let task = Task { await call() }
        inFlight = task
        lastCallAt = now
        let outcome = await task.value
        inFlight = nil
        lastOutcome = outcome
        if outcome.error?.kind == .rateLimited {
            rateLimitedUntil = now.addingTimeInterval(Self.rateLimitCooldown)
        }
        return outcome
    }
}
