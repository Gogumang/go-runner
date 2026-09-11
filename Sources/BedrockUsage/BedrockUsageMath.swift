import Foundation
import GoRunnerCore

/// Per-model figures derived from CloudWatch data.
struct BedrockModelUsage: Sendable, Equatable {
    var modelID: String
    /// Peak tokens/minute counted against the TPM quota over the lookback window.
    var peakTPM: Double
    /// true when `peakTPM` comes from `EstimatedTPMQuotaUsage` instead of the burndown formula.
    var fromEstimatedMetric: Bool
    var peakRPM: Double
    var throttlesLastHour: Int
    var today: TokenSummary
    var lastDataAt: Date?
}

enum BedrockUsageMath {
    /// Quota lookback: the current minute bucket plus the 5 previous ones (CloudWatch lags a few minutes).
    static let lookback: TimeInterval = 5 * 60

    static func floorToMinute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    static func inWindow(_ point: MetricPoint, now: Date) -> Bool {
        point.timestamp >= floorToMinute(now).addingTimeInterval(-lookback) && point.timestamp <= now
    }

    /// Per-minute quota consumption: `input + cacheWrite + output × burndown` (docs/research/04-ai-quota.md §4.2).
    static func quotaTokensPerMinute(input: [MetricPoint], cacheWrite: [MetricPoint], output: [MetricPoint],
                                     burndown: Double) -> [Date: Double] {
        var byMinute: [Date: Double] = [:]
        for p in input { byMinute[p.timestamp, default: 0] += p.value }
        for p in cacheWrite { byMinute[p.timestamp, default: 0] += p.value }
        for p in output { byMinute[p.timestamp, default: 0] += p.value * burndown }
        return byMinute
    }

    /// Max over the lookback window. Prefers `EstimatedTPMQuotaUsage` when that metric returned data points.
    static func peakTPM(modelID: String, data: BedrockMetricData, now: Date) -> (value: Double, fromEstimate: Bool) {
        let estimated = data.points(modelID, .estimatedTPM).filter { inWindow($0, now: now) }
        if !estimated.isEmpty {
            return (estimated.map(\.value).max() ?? 0, true)
        }
        let burndown = BedrockBurndown.multiplier(for: BedrockModelID(modelID))
        let perMinute = quotaTokensPerMinute(input: data.points(modelID, .inputTokens),
                                             cacheWrite: data.points(modelID, .cacheWriteTokens),
                                             output: data.points(modelID, .outputTokens), burndown: burndown)
        let peak = perMinute.filter { inWindow(MetricPoint(timestamp: $0.key, value: $0.value), now: now) }.values.max() ?? 0
        return (peak, false)
    }

    static func usage(modelID: String, recent: BedrockMetricData?, today: BedrockMetricData?, now: Date) -> BedrockModelUsage {
        var peak = (value: 0.0, fromEstimate: false)
        var rpm = 0.0
        var throttles = 0
        var last: Date?
        if let recent {
            peak = peakTPM(modelID: modelID, data: recent, now: now)
            rpm = recent.points(modelID, .invocations).filter { inWindow($0, now: now) }.map(\.value).max() ?? 0
            throttles = Int(recent.sum(modelID, .throttles).rounded())
            last = BedrockMetric.allCases.compactMap { recent.points(modelID, $0).last(where: { $0.value > 0 })?.timestamp }.max()
        }
        var summary = TokenSummary()
        if let today {
            summary = TokenSummary(input: Int(today.sum(modelID, .inputTokens)), output: Int(today.sum(modelID, .outputTokens)),
                                   cacheCreation: Int(today.sum(modelID, .cacheWriteTokens)),
                                   cacheRead: Int(today.sum(modelID, .cacheReadTokens)))
        }
        return BedrockModelUsage(modelID: modelID, peakTPM: peak.value, fromEstimatedMetric: peak.fromEstimate, peakRPM: rpm,
                                 throttlesLastHour: throttles, today: summary, lastDataAt: last)
    }

    /// "12.4K", "200K", "1.2M", "950".
    static func compact(_ value: Double) -> String {
        let v = max(0, value)
        func trim(_ s: String) -> String { s.hasSuffix(".0") ? String(s.dropLast(2)) : s }
        switch v {
        case ..<1_000: return "\(Int(v.rounded()))"
        case ..<1_000_000: return trim(String(format: "%.1f", v / 1_000)) + "K"
        case ..<1_000_000_000: return trim(String(format: "%.1f", v / 1_000_000)) + "M"
        default: return trim(String(format: "%.1f", v / 1_000_000_000)) + "B"
        }
    }
}

/// Everything one refresh gathered; turned into a `QuotaSnapshot` by a pure function.
struct BedrockFetchResults: Sendable {
    var profile: String
    var region: String
    var models: [String]
    var recent: BedrockMetricData?
    var today: BedrockMetricData?
    /// nil when Service Quotas could not be read.
    var quotas: [BedrockServiceQuota]?
    var monthToDateUSD: Double?
    var notes: [String] = []
}

enum BedrockSnapshotBuilder {
    static func build(_ results: BedrockFetchResults, now: Date) -> QuotaSnapshot {
        var notes = results.notes
        var windows: [(QuotaWindow, Double, Int)] = []
        var totals = TokenSummary()
        var usedEstimate = false
        var throttled: [(String, Int)] = []
        var latest: Date?

        for modelID in results.models {
            let usage = BedrockUsageMath.usage(modelID: modelID, recent: results.recent, today: results.today, now: now)
            let model = BedrockModelID(modelID)
            totals.input += usage.today.input
            totals.output += usage.today.output
            totals.cacheCreation += usage.today.cacheCreation
            totals.cacheRead += usage.today.cacheRead
            if usage.fromEstimatedMetric { usedEstimate = true }
            if usage.throttlesLastHour > 0 { throttled.append((model.shortName, usage.throttlesLastHour)) }
            if let date = usage.lastDataAt { latest = max(latest ?? date, date) }

            let todayText = Loc.t("오늘 \(BedrockUsageMath.compact(Double(usage.today.total))) 토큰",
                                  "today \(BedrockUsageMath.compact(Double(usage.today.total))) tokens")
            let tpmQuota = results.quotas.flatMap { BedrockQuotaMatcher.tpmQuota(for: modelID, in: $0) }
            let rpmQuota = results.quotas.flatMap { BedrockQuotaMatcher.rpmQuota(for: modelID, in: $0) }
            var parts: [String] = []
            var fraction: Double?
            if let tpmQuota, tpmQuota.value > 0 {
                fraction = usage.peakTPM / tpmQuota.value
                parts.append("\(BedrockUsageMath.compact(usage.peakTPM)) / \(BedrockUsageMath.compact(tpmQuota.value)) TPM")
            } else {
                parts.append(Loc.t("최대 \(BedrockUsageMath.compact(usage.peakTPM)) TPM (쿼터 미확인)",
                                   "peak \(BedrockUsageMath.compact(usage.peakTPM)) TPM (quota unknown)"))
            }
            if let rpmQuota, rpmQuota.value > 0 {
                parts.append("\(BedrockUsageMath.compact(usage.peakRPM)) / \(BedrockUsageMath.compact(rpmQuota.value)) RPM")
            }
            parts.append(todayText)
            let window = QuotaWindow(id: "tpm:\(modelID)", label: "TPM · \(model.shortName)", usedFraction: fraction,
                                     resetsAt: nil, detail: parts.joined(separator: " · "))
            windows.append((window, fraction ?? -1, usage.today.total))
        }

        windows.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2 }

        if usedEstimate {
            notes.append(Loc.t("TPM은 CloudWatch EstimatedTPMQuotaUsage(AWS 추정치) 기준",
                               "TPM uses CloudWatch EstimatedTPMQuotaUsage (an AWS estimate)"))
        }
        if !throttled.isEmpty {
            let list = throttled.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
            notes.append(Loc.t("최근 1시간 스로틀 발생: \(list)", "Throttled in the last hour: \(list)"))
        }

        var spend: [SpendLine] = []
        var source = "CloudWatch + Service Quotas"
        if let mtd = results.monthToDateUSD {
            spend.append(SpendLine(label: Loc.t("이번 달", "Month to date"), amountUSD: mtd, isEstimate: false))
            source += " + Cost Explorer"
            notes.append(Loc.t("Cost Explorer 비용은 약 하루 지연됩니다", "Cost Explorer data lags about a day"))
        }

        return QuotaSnapshot(provider: .bedrock, planLabel: "\(results.region) · \(results.profile)",
                             windows: windows.map(\.0), spend: spend,
                             tokens: results.today == nil ? nil : totals,
                             sourceName: source, trust: .official, fetchedAt: now, dataAsOf: latest, notes: notes)
    }
}
