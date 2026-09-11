import Foundation
import GoRunnerCore

/// The three Claude data sources, in trust order.
enum ClaudeSource: String, Sendable, CaseIterable {
    case statusline, oauth, localLogs

    /// Stable id recorded in `SourceAttempt.source`.
    var attemptName: String {
        switch self {
        case .statusline: "statusline"
        case .oauth: "oauth-usage"
        case .localLogs: "local-logs"
        }
    }

    /// Shown in `QuotaSnapshot.sourceName`, e.g. "statusline + 로컬 로그".
    var displayName: String {
        switch self {
        case .statusline: "statusline"
        case .oauth: "OAuth"
        case .localLogs: Loc.t("로컬 로그", "local logs")
        }
    }

    var trust: SourceTrust {
        switch self {
        case .statusline: .official
        case .oauth: .undocumented
        case .localLogs: .heuristic
        }
    }
}

/// What one source produced.
struct SourceResult: Sendable, Equatable {
    var windows: [QuotaWindow] = []
    var planLabel: String?
    var tokens: TokenSummary?
    var spend: [SpendLine] = []
    var dataAsOf: Date?
    var notes: [String] = []
    /// Short diagnostic for `SourceAttempt.message` (never contains secrets).
    var message: String?
}

enum SourceOutcome: Sendable, Equatable {
    case success(SourceResult)
    case failure(ProviderError)

    var result: SourceResult? {
        if case .success(let result) = self { return result }
        return nil
    }

    var error: ProviderError? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

enum ClaudeWindow {
    static let fiveHour = "five_hour"
    static let sevenDay = "seven_day"
    static let sevenDayOpus = "seven_day_opus"
    static let sevenDaySonnet = "seven_day_sonnet"
    static let spendLimit = "spend_limit"
    static let extraUsage = "extra_usage"
    static let fiveHourBlock = "five_hour_block"

    static func label(for id: String) -> String {
        switch id {
        case fiveHour: Loc.t("5시간", "5-hour")
        case sevenDay: Loc.t("주간", "Weekly")
        case sevenDayOpus: Loc.t("Opus 주간", "Opus weekly")
        case sevenDaySonnet: Loc.t("Sonnet 주간", "Sonnet weekly")
        case spendLimit: Loc.t("사용 한도", "Spend limit")
        case extraUsage: Loc.t("추가 사용량", "Extra usage")
        case fiveHourBlock: Loc.t("5시간 블록 (로그)", "5h block (logs)")
        default: id
        }
    }

    /// Builds a percentage window. A window whose reset time has passed has reset: 0 % and a note.
    static func make(id: String, label: String? = nil, percent: Double, resetsAt: Date?, now: Date,
                     detail: String? = nil, notes: inout [String]) -> QuotaWindow {
        let label = label ?? self.label(for: id)
        if let resetsAt, resetsAt <= now {
            notes.append(Loc.t("\(label) 한도가 리셋되었습니다 (새 데이터 대기 중)", "\(label) limit has reset (waiting for new data)"))
            return QuotaWindow(id: id, label: label, usedFraction: 0, resetsAt: nil, detail: detail)
        }
        return QuotaWindow(id: id, label: label, usedFraction: max(0, percent) / 100, resetsAt: resetsAt, detail: detail)
    }
}

enum ClaudeHints {
    static var installHook: String {
        Loc.t("설정 → AI 서비스에서 statusline 훅을 설치하세요", "Install the statusline hook in Settings → AI Services")
    }

    static var refreshToken: String {
        Loc.t("Claude Code를 한 번 실행해 토큰을 갱신하세요", "Run Claude Code once to refresh the token")
    }
}

enum JSONValue {
    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

/// Fast ISO-8601 parser for `2026-09-11T00:58:23.590Z` / `…+09:00` (falls back to ISO8601DateFormatter).
enum ClaudeTimestamp {
    static func parse(_ string: String) -> Date? {
        let b = Array(string.utf8)
        guard b.count >= 19, b[4] == 45, b[7] == 45, b[10] == 84 || b[10] == 116 || b[10] == 32, b[13] == 58, b[16] == 58
        else { return fallback(string) }

        func digits(_ from: Int, _ length: Int) -> Int? {
            guard from + length <= b.count else { return nil }
            var value = 0
            for index in from..<(from + length) {
                let digit = Int(b[index]) - 48
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }

        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day)
        else { return fallback(string) }

        var index = 19
        var fraction = 0.0
        if index < b.count, b[index] == 46 {
            index += 1
            var scale = 0.1
            while index < b.count, (48...57).contains(b[index]) {
                fraction += Double(b[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }

        var offsetSeconds = 0
        if index < b.count {
            switch b[index] {
            case 90, 122: // Z z
                index += 1
            case 43, 45: // + -
                guard let offsetHours = digits(index + 1, 2) else { return fallback(string) }
                let minuteStart = index + 3 < b.count && b[index + 3] == 58 ? index + 4 : index + 3
                let offsetMinutes = digits(minuteStart, 2) ?? 0
                offsetSeconds = (offsetHours * 3600 + offsetMinutes * 60) * (b[index] == 45 ? -1 : 1)
                index = minuteStart + 2
            default:
                return fallback(string)
            }
        }
        guard index >= b.count else { return fallback(string) }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = days * 86400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    /// Days since 1970-01-01 (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthIndex = (month + 9) % 12
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func fallback(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// Resumes exactly once.
final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}

/// Returns `operation`'s value, or `onTimeout()` after `seconds` — without waiting for work that ignores
/// cancellation (e.g. a `ProcessRunner` child waiting on a Keychain prompt).
func withDeadline<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T,
                               onTimeout: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let gate = ResumeGate()
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard !Task.isCancelled, gate.claim() else { return }
            continuation.resume(returning: onTimeout())
        }
        Task {
            let value = await operation()
            guard gate.claim() else { return }
            timer.cancel()
            continuation.resume(returning: value)
        }
    }
}
