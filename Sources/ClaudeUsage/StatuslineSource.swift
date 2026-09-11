import Foundation
import GoRunnerCore

/// Reads `{"receivedAt": <epoch s>, "payload": <Claude Code statusline JSON>}` written by the hook.
/// Documented fields (code.claude.com/docs/en/statusline, Claude Code 2.1.268):
/// `rate_limits.{five_hour,seven_day,spend_limit}.used_percentage` (0–100) and `.resets_at` (epoch seconds).
enum ClaudeStatuslineSource {
    static let staleAfter: TimeInterval = 6 * 3600

    static func read(fileURL: URL, hookInstalled: Bool, now: Date) -> SourceOutcome {
        let fileManager = FileManager.default
        guard let data = fileManager.contents(atPath: fileURL.path) else {
            if hookInstalled {
                return .failure(ProviderError(kind: .noRecentData,
                                              message: Loc.t("아직 statusline 데이터가 없습니다", "No statusline data yet"),
                                              fixHint: Loc.t("Claude Code 세션을 실행하면 갱신됩니다", "Start a Claude Code session to update it")))
            }
            return .failure(ProviderError(kind: .notConfigured,
                                          message: Loc.t("statusline 훅이 설치되지 않았습니다", "The statusline hook is not installed"),
                                          fixHint: ClaudeHints.installHook))
        }
        let modified = (try? fileManager.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        return parse(data, fileModified: modified, now: now)
    }

    static func parse(_ data: Data, fileModified: Date? = nil, now: Date) -> SourceOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["payload"] as? [String: Any]
        else {
            return .failure(ProviderError(kind: .schemaChanged,
                                          message: Loc.t("statusline 파일 형식을 읽을 수 없습니다", "Could not read the statusline file")))
        }

        let receivedAt = JSONValue.double(root["receivedAt"]).map { Date(timeIntervalSince1970: $0) } ?? fileModified
        let limits = payload["rate_limits"] as? [String: Any] ?? [:]
        var windows: [QuotaWindow] = []
        var notes: [String] = []
        for id in [ClaudeWindow.fiveHour, ClaudeWindow.sevenDay, ClaudeWindow.spendLimit] {
            guard let raw = limits[id] as? [String: Any], let percent = JSONValue.double(raw["used_percentage"]) else { continue }
            let resetsAt = JSONValue.double(raw["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            windows.append(ClaudeWindow.make(id: id, percent: percent, resetsAt: resetsAt, now: now, notes: &notes))
        }

        guard !windows.isEmpty else {
            return .failure(ProviderError(
                kind: .other,
                message: Loc.t("statusline 데이터에 rate_limits가 없습니다 — API 키·Bedrock 요금제이거나 세션의 첫 응답 전입니다",
                               "No rate_limits in the statusline data — likely an API key or Bedrock plan, or before the session's first response"),
                fixHint: Loc.t("rate_limits는 Claude Pro/Max 구독에서만 제공됩니다", "rate_limits are only sent for Claude Pro/Max subscriptions")))
        }

        var result = SourceResult(windows: windows, dataAsOf: receivedAt, notes: notes)
        if let receivedAt {
            let age = MetricFormat.age(receivedAt, now: now)
            if now.timeIntervalSince(receivedAt) > staleAfter {
                result.notes.append(Loc.t("마지막 statusline 데이터: \(age) · Claude Code 세션이 실행 중일 때만 갱신됩니다",
                                          "Last statusline data: \(age) · it only updates while a Claude Code session is running"))
            }
            result.message = Loc.t("수신 \(age)", "received \(age)")
        }
        return .success(result)
    }
}
