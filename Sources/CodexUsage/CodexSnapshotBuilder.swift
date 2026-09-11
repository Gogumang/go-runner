import Foundation
import GoRunnerCore

enum CodexWindowLabel {
    /// Label by window length, never by primary/secondary position.
    static func label(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return Loc.t("한도", "Limit") }
        switch minutes {
        case 300:
            return Loc.t("5시간", "5-hour")
        case 10_080:
            return Loc.t("주간", "Weekly")
        case let m where m % 60 == 0:
            let hours = m / 60
            return Loc.t("\(hours)시간", "\(hours)-hour")
        default:
            return Loc.t("\(minutes)분", "\(minutes)-min")
        }
    }
}

enum CodexSnapshotBuilder {
    static let appServerSourceName = "codex app-server"

    static var sessionLogsSourceName: String {
        Loc.t("Codex 세션 로그", "Codex session logs")
    }

    /// `plus` → "Plus", `prolite` → "Pro Lite", `self_serve_business_usage_based` → "Self Serve Business Usage Based".
    static func planLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw.lowercased() != "unknown" else { return nil }
        let words = raw.lowercased().split(separator: "_").map { word -> String in
            word == "prolite" ? "Pro Lite" : word.prefix(1).uppercased() + word.dropFirst()
        }
        return words.joined(separator: " ")
    }

    /// - Parameter zeroPastResets: for stale data, a window whose reset time has passed is reported as 0 % with a note.
    static func quotaWindows(for limits: CodexRateLimits, now: Date, zeroPastResets: Bool) -> (windows: [QuotaWindow], notes: [String]) {
        var windows: [QuotaWindow] = []
        var notes: [String] = []

        func add(_ window: CodexRateLimitWindow?, id: String, prefix: String?) {
            guard let window else { return }
            let base = CodexWindowLabel.label(minutes: window.windowMinutes)
            let label = prefix.map { "\($0) · \(base)" } ?? base
            var fraction = max(0, window.usedPercent / 100)
            var resetsAt = window.resetsAt
            if zeroPastResets, let reset = resetsAt, reset <= now {
                fraction = 0
                resetsAt = nil
                notes.append(Loc.t("\(label) 한도는 마지막 기록 이후 리셋되었습니다",
                                   "\(label) limit has reset since the last recorded turn"))
            }
            windows.append(QuotaWindow(id: id, label: label, usedFraction: fraction, resetsAt: resetsAt))
        }

        add(limits.main.primary, id: "primary", prefix: nil)
        add(limits.main.secondary, id: "secondary", prefix: nil)
        for bucket in limits.additional {
            let key = bucket.limitID ?? "extra"
            let name = bucket.limitName ?? key
            add(bucket.primary, id: "\(key).primary", prefix: name)
            add(bucket.secondary, id: "\(key).secondary", prefix: name)
        }
        if limits.main.rateLimitReachedType != nil {
            notes.append(Loc.t("사용 한도에 도달했습니다", "Usage limit reached"))
        }
        return (windows, notes)
    }

    static func appServerSnapshot(_ result: CodexAppServerResult, now: Date) -> QuotaSnapshot {
        var (windows, notes) = quotaWindows(for: result.rateLimits, now: now, zeroPastResets: false)
        if windows.isEmpty {
            notes.append(Loc.t("codex가 보고한 사용 한도가 없습니다", "codex reported no usage limits"))
        }
        return QuotaSnapshot(provider: .codex,
                             planLabel: planLabel(result.rateLimits.main.planType ?? result.account?.planType),
                             windows: windows, sourceName: appServerSourceName, trust: .openInterface,
                             fetchedAt: now, dataAsOf: now, notes: notes)
    }

    static func sessionLogSnapshot(_ result: CodexSessionLogResult, now: Date) -> QuotaSnapshot {
        var windows: [QuotaWindow] = []
        var notes: [String] = []
        if let event = result.latestRateLimits, let bucket = event.rateLimits {
            (windows, notes) = quotaWindows(for: CodexRateLimits(main: bucket), now: now, zeroPastResets: true)
            notes.insert(Loc.t("마지막 Codex 사용 시점 기준 수치입니다", "Values as of the last Codex turn"), at: 0)
        }
        return QuotaSnapshot(provider: .codex, planLabel: planLabel(result.latestRateLimits?.rateLimits?.planType),
                             windows: windows, tokens: result.todayUsage?.summary,
                             sourceName: sessionLogsSourceName, trust: .heuristic, fetchedAt: now,
                             dataAsOf: result.latestRateLimits?.timestamp, notes: notes)
    }
}
