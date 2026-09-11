import Foundation
import GoRunnerCore

// `codex app-server` wire protocol. Verified against codex-cli 0.153.0 on this Mac and openai/codex @e53c444
// (`codex-rs/app-server-protocol/src/rpc.rs`, `protocol/common.rs`, `protocol/v1.rs`, `protocol/v2/account.rs`,
// `app-server-transport/src/transport/stdio.rs`):
// - stdio transport, one JSON message per line (the server reads `stdin.lines()`).
// - JSON-RPC 2.0 shaped, but "We do not do true JSON-RPC 2.0": `"jsonrpc":"2.0"` is neither sent nor required.
// - `initialize {clientInfo:{name,title?,version}}` must come first (other requests get -32600 "Not initialized"),
//   followed by the `initialized` notification.
// - `account/read {}` → `{account: {type:"chatgpt",email,planType} | {type:"apiKey"} | {type:"amazonBedrock"} | null,
//   requiresOpenaiAuth}`.
// - `account/rateLimits/read` takes NO params on 0.153.0 (a params object fails with "invalid type: map, expected unit")
//   → `{rateLimits:{limitId,limitName,primary:{usedPercent:int,windowDurationMins,resetsAt:epoch s},secondary,credits,
//   planType,rateLimitReachedType,…}, rateLimitsByLimitId:{<id>:snapshot}, rateLimitResetCredits, …}`.
// - Not signed in: -32600 "codex account authentication required to read rate limits";
//   API-key login: -32600 "chatgpt authentication required to read rate limits".

/// A `JSONSerialization` object boxed so it can cross concurrency domains (it is never mutated).
struct JSONObject: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

enum CodexRPC {
    static let initialize = "initialize"
    static let initialized = "initialized"
    static let accountRead = "account/read"
    static let rateLimitsRead = "account/rateLimits/read"

    enum Message {
        case response(id: Int, result: JSONObject)
        case error(id: Int, code: Int, message: String)
        case notification(method: String)
        /// Server → client request (e.g. approvals). GoRunner never starts turns, so these are ignored.
        case serverRequest(id: Int, method: String)
        case unparseable
    }

    static func request(id: Int, method: String, params: [String: Any]? = nil) -> Data {
        var object: [String: Any] = ["id": id, "method": method]
        if let params { object["params"] = params }
        return line(object)
    }

    static func notification(method: String, params: [String: Any]? = nil) -> Data {
        var object: [String: Any] = ["method": method]
        if let params { object["params"] = params }
        return line(object)
    }

    static func initializeParams(clientName: String, clientVersion: String) -> [String: Any] {
        ["clientInfo": ["name": clientName, "title": "go-runner", "version": clientVersion]]
    }

    /// Compact JSON plus exactly one trailing newline (JSONSerialization escapes newlines inside strings).
    static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    static func decode(_ line: Data) -> Message {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return .unparseable }
        let id = requestID(object["id"])
        if let method = object["method"] as? String {
            if let id { return .serverRequest(id: id, method: method) }
            return .notification(method: method)
        }
        guard let id else { return .unparseable }
        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? 0
            return .error(id: id, code: code, message: error["message"] as? String ?? "")
        }
        if object.keys.contains("result") {
            return .response(id: id, result: JSONObject(object["result"] as? [String: Any] ?? [:]))
        }
        return .unparseable
    }

    private static func requestID(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

/// Splits a byte stream into newline-terminated lines.
struct LineBuffer {
    let maxLineBytes: Int
    private var storage = Data()
    private var scanned = 0

    init(maxLineBytes: Int = 16 << 20) {
        self.maxLineBytes = maxLineBytes
    }

    /// Appends bytes and returns every completed line (newline and trailing CR stripped, blank lines skipped).
    /// `overflow` is true when an unterminated line grew past `maxLineBytes`; that partial line is dropped.
    mutating func append(_ data: Data) -> (lines: [Data], overflow: Bool) {
        storage.append(data)
        var lines: [Data] = []
        var lineStart = storage.startIndex
        var searchFrom = storage.startIndex + scanned
        while searchFrom < storage.endIndex, let newline = storage[searchFrom...].firstIndex(of: 0x0A) {
            var line = storage[lineStart..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
            lineStart = newline + 1
            searchFrom = lineStart
        }
        if lineStart > storage.startIndex {
            storage = Data(storage[lineStart...])
        }
        scanned = storage.count
        if storage.count > maxLineBytes {
            storage = Data()
            scanned = 0
            return (lines, true)
        }
        return (lines, false)
    }
}

// MARK: - Models

struct CodexRateLimitWindow: Sendable, Equatable {
    /// 0...100.
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?
}

struct CodexRateLimitBucket: Sendable, Equatable {
    var limitID: String?
    var limitName: String?
    var primary: CodexRateLimitWindow?
    var secondary: CodexRateLimitWindow?
    var planType: String?
    var rateLimitReachedType: String?

    var hasWindows: Bool { primary != nil || secondary != nil }
}

struct CodexRateLimits: Sendable, Equatable {
    /// `rateLimits` (the `codex` bucket).
    var main: CodexRateLimitBucket
    /// Other buckets from `rateLimitsByLimitId`, sorted by id.
    var additional: [CodexRateLimitBucket] = []
}

struct CodexAccountInfo: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case chatgpt, apiKey, amazonBedrock
        case other(String)
    }

    /// nil when not signed in. The account email is deliberately not kept.
    var kind: Kind?
    var planType: String?
    var requiresOpenAIAuth: Bool
}

// MARK: - Parsing

enum CodexResponseParser {
    enum KeyStyle {
        /// camelCase from `codex app-server`.
        case appServer
        /// snake_case from rollout `token_count` events (`codex-rs/protocol/src/protocol.rs`).
        case rollout
    }

    static func rateLimits(fromResult result: [String: Any]) throws -> CodexRateLimits {
        guard let main = result["rateLimits"] as? [String: Any] else {
            throw CodexErrors.schema("\(CodexRPC.rateLimitsRead): missing rateLimits")
        }
        let mainBucket = try bucket(main, style: .appServer)
        let mainID = mainBucket.limitID ?? "codex"
        var additional: [CodexRateLimitBucket] = []
        if let byID = result["rateLimitsByLimitId"] as? [String: Any] {
            for (key, value) in byID.sorted(by: { $0.key < $1.key }) where key != mainID {
                guard let dict = value as? [String: Any], var extra = try? bucket(dict, style: .appServer),
                      extra.hasWindows else { continue }
                if extra.limitID == nil { extra.limitID = key }
                additional.append(extra)
            }
        }
        return CodexRateLimits(main: mainBucket, additional: additional)
    }

    static func account(fromResult result: [String: Any]) throws -> CodexAccountInfo {
        guard result.keys.contains("account") || result.keys.contains("requiresOpenaiAuth") else {
            throw CodexErrors.schema("\(CodexRPC.accountRead): missing account")
        }
        let requiresAuth = (result["requiresOpenaiAuth"] as? Bool) ?? false
        guard let account = result["account"] as? [String: Any] else {
            return CodexAccountInfo(kind: nil, planType: nil, requiresOpenAIAuth: requiresAuth)
        }
        let kind: CodexAccountInfo.Kind
        switch account["type"] as? String {
        case "chatgpt": kind = .chatgpt
        case "apiKey": kind = .apiKey
        case "amazonBedrock": kind = .amazonBedrock
        case let other: kind = .other(other ?? "unknown")
        }
        return CodexAccountInfo(kind: kind, planType: account["planType"] as? String, requiresOpenAIAuth: requiresAuth)
    }

    static func bucket(_ dict: [String: Any], style: KeyStyle, reference: Date? = nil) throws -> CodexRateLimitBucket {
        let camel = style == .appServer
        return CodexRateLimitBucket(
            limitID: dict[camel ? "limitId" : "limit_id"] as? String,
            limitName: dict[camel ? "limitName" : "limit_name"] as? String,
            primary: try window(dict["primary"], style: style, reference: reference),
            secondary: try window(dict["secondary"], style: style, reference: reference),
            planType: dict[camel ? "planType" : "plan_type"] as? String,
            rateLimitReachedType: dict[camel ? "rateLimitReachedType" : "rate_limit_reached_type"] as? String
        )
    }

    static func window(_ value: Any?, style: KeyStyle, reference: Date?) throws -> CodexRateLimitWindow? {
        guard let value, !(value is NSNull) else { return nil }
        guard let dict = value as? [String: Any] else { throw CodexErrors.schema("rate limit window is not an object") }
        let camel = style == .appServer
        let percentKey = camel ? "usedPercent" : "used_percent"
        guard let percent = number(dict[percentKey]) else { throw CodexErrors.schema("missing \(percentKey)") }
        let minutes = number(dict[camel ? "windowDurationMins" : "window_minutes"]).map { Int($0.rounded()) }
        var resetsAt = date(dict[camel ? "resetsAt" : "resets_at"])
        // Older CLI builds wrote a relative `resets_in_seconds` instead of `resets_at`.
        if resetsAt == nil, let reference, let seconds = number(dict["resets_in_seconds"]) {
            resetsAt = reference.addingTimeInterval(seconds)
        }
        return CodexRateLimitWindow(usedPercent: percent, windowMinutes: minutes, resetsAt: resetsAt)
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// Epoch seconds (or milliseconds), numeric strings, or ISO-8601.
    static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            if let seconds = Double(string) { return epoch(seconds) }
            return iso8601(string)
        }
        return number(value).map(epoch)
    }

    static func iso8601(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
        return try? Date.ISO8601FormatStyle().parse(string)
    }

    private static func epoch(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }
}

// MARK: - Errors

enum CodexErrors {
    static var installHint: String {
        Loc.t("Codex CLI를 설치하거나 설정에서 경로를 지정하세요", "Install Codex CLI or set its path in Settings")
    }

    static var loginHint: String {
        Loc.t("터미널에서 `codex login` 실행", "Run `codex login` in Terminal")
    }

    static func notFound(override: String?) -> ProviderError {
        let message: String
        if let override, !override.isEmpty {
            message = Loc.t("codex 실행 파일이 없습니다: \(override)", "codex executable not found: \(override)")
        } else {
            message = Loc.t("codex CLI를 찾을 수 없습니다", "codex CLI not found")
        }
        return ProviderError(kind: .toolNotFound, message: message, fixHint: installHint)
    }

    static func notLoggedIn(detail: String? = nil) -> ProviderError {
        var message = Loc.t("Codex에 ChatGPT 계정으로 로그인되어 있지 않습니다", "Codex is not signed in with ChatGPT")
        if let detail, !detail.isEmpty { message += " (\(detail))" }
        return ProviderError(kind: .authMissing, message: message, fixHint: loginHint)
    }

    static func timeout(seconds: TimeInterval) -> ProviderError {
        let s = Int(seconds.rounded())
        return ProviderError(kind: .timeout,
                             message: Loc.t("codex app-server가 \(s)초 안에 응답하지 않았습니다",
                                            "codex app-server did not respond within \(s) s"))
    }

    static func schema(_ detail: String) -> ProviderError {
        ProviderError(kind: .schemaChanged,
                      message: Loc.t("codex 응답 형식이 예상과 다릅니다: \(detail)", "Unexpected codex response: \(detail)"),
                      fixHint: Loc.t("go-runner와 Codex CLI를 최신 버전으로 업데이트하세요", "Update go-runner and Codex CLI"))
    }

    /// Account state that makes plan limits unavailable, if any.
    static func accountProblem(_ account: CodexAccountInfo?) -> ProviderError? {
        guard let account else { return nil }
        switch account.kind {
        case nil:
            return notLoggedIn()
        case .apiKey?:
            return notLoggedIn(detail: Loc.t("API 키 로그인에는 플랜 한도가 없습니다", "API-key sign-in has no plan limits"))
        case .amazonBedrock?:
            return notLoggedIn(detail: Loc.t("Bedrock 로그인에는 ChatGPT 한도가 없습니다", "Bedrock sign-in has no ChatGPT limits"))
        default:
            return nil
        }
    }

    static func looksLikeAuthProblem(_ text: String) -> Bool {
        let lower = text.lowercased()
        let needles = ["authentication required", "not logged in", "not signed in", "codex login", "login required",
                       "please log in", "unauthorized", "token expired", "token_expired", "refresh token", "invalid_grant"]
        return needles.contains { lower.contains($0) }
    }

    static func rpcError(code: Int, message: String, method: String) -> ProviderError {
        let lower = message.lowercased()
        if looksLikeAuthProblem(message) {
            return notLoggedIn(detail: message)
        }
        if code == -32601 || lower.contains("method not found") || lower.contains("unknown variant")
            || lower.contains("invalid type") {
            return schema("\(method): \(message)")
        }
        if lower.contains("failed to fetch") || lower.contains("timed out") || lower.contains("connect")
            || lower.contains("network") {
            return ProviderError(kind: .network, message: "\(method): \(message)")
        }
        return ProviderError(kind: .other, message: "\(method): \(message)")
    }
}
