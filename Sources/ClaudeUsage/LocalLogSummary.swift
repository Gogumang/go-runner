import Foundation
import GoRunnerCore

struct ClaudeUsageTotals: Sendable, Equatable {
    var tokens = TokenSummary()
    var costUSD: Double = 0
    var entryCount = 0
    var pricedEntryCount = 0
    var unpricedModels: Set<String> = []

    /// nil when there are entries but none has a known price.
    var estimatedCostUSD: Double? {
        entryCount == 0 || pricedEntryCount > 0 ? costUSD : nil
    }

    static func of<S: Sequence>(_ entries: S) -> ClaudeUsageTotals where S.Element == ClaudeUsageEntry {
        var totals = ClaudeUsageTotals()
        var priceCache: [String: ClaudeModelPrice?] = [:]
        for entry in entries {
            totals.entryCount += 1
            totals.tokens.input += entry.inputTokens
            totals.tokens.output += entry.outputTokens
            totals.tokens.cacheCreation += entry.cacheCreationTokens
            totals.tokens.cacheRead += entry.cacheReadTokens

            let key = entry.isFastMode ? entry.model + "#fast" : entry.model
            let price: ClaudeModelPrice?
            if let cached = priceCache[key] {
                price = cached
            } else {
                price = ClaudePricing.price(for: entry.model, fastMode: entry.isFastMode)
                priceCache[key] = .some(price)
            }
            if let price {
                totals.costUSD += ClaudePricing.cost(of: entry, price: price)
                totals.pricedEntryCount += 1
            } else {
                totals.unpricedModels.insert(entry.model)
            }
        }
        totals.tokens.estimatedCostUSD = totals.estimatedCostUSD
        return totals
    }
}

struct ClaudeUsageBlock: Sendable, Equatable {
    var start: Date
    var end: Date
    var entries: [ClaudeUsageEntry]

    var lastActivity: Date { entries.last?.timestamp ?? start }

    /// ccusage `create_block`: active while the last entry is < 5 h old and the block has not ended.
    func isActive(now: Date, duration: TimeInterval = ClaudeBlockCalculator.sessionDuration) -> Bool {
        now.timeIntervalSince(lastActivity) < duration && now < end
    }
}

/// ccusage `identify_session_blocks` (MIT, rust/crates/ccusage/src/blocks.rs): a block starts at the first
/// entry floored to the UTC hour; a new block starts when an entry is more than 5 h after the block start
/// or after the previous entry. Gap blocks are not materialized.
enum ClaudeBlockCalculator {
    static let sessionDuration: TimeInterval = 5 * 3600

    static func floorToHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    static func blocks(for entries: [ClaudeUsageEntry], duration: TimeInterval = sessionDuration) -> [ClaudeUsageBlock] {
        let sorted = entries.sorted { $0.timestamp < $1.timestamp }
        var blocks: [ClaudeUsageBlock] = []
        var currentStart: Date?
        var current: [ClaudeUsageEntry] = []
        for entry in sorted {
            if let start = currentStart {
                let last = current.last?.timestamp ?? start
                if entry.timestamp.timeIntervalSince(start) > duration || entry.timestamp.timeIntervalSince(last) > duration {
                    blocks.append(ClaudeUsageBlock(start: start, end: start.addingTimeInterval(duration), entries: current))
                    current = []
                    currentStart = floorToHour(entry.timestamp)
                }
            } else {
                currentStart = floorToHour(entry.timestamp)
            }
            current.append(entry)
        }
        if let start = currentStart, !current.isEmpty {
            blocks.append(ClaudeUsageBlock(start: start, end: start.addingTimeInterval(duration), entries: current))
        }
        return blocks
    }
}

enum ClaudeLogSummarizer {
    static let lookback: TimeInterval = 7 * 86400

    static func summarize(_ entries: [ClaudeUsageEntry], now: Date, calendar: Calendar = .current) -> SourceOutcome {
        let weekStart = now.addingTimeInterval(-lookback)
        let recent = entries.filter { $0.timestamp >= weekStart }.sorted { $0.timestamp < $1.timestamp }
        guard let last = recent.last else {
            return .failure(ProviderError(kind: .noRecentData,
                                          message: Loc.t("최근 7일간 Claude Code 사용 기록이 없습니다", "No Claude Code usage in the last 7 days")))
        }

        let todayStart = calendar.startOfDay(for: now)
        let today = ClaudeUsageTotals.of(recent.lazy.filter { $0.timestamp >= todayStart })
        let week = ClaudeUsageTotals.of(recent)

        var result = SourceResult()
        result.tokens = today.tokens
        if let cost = today.estimatedCostUSD {
            result.spend.append(SpendLine(label: Loc.t("오늘", "Today"), amountUSD: cost, isEstimate: true))
        }
        if let cost = week.estimatedCostUSD {
            let tokens = MetricFormat.tokens(week.tokens.total)
            result.spend.append(SpendLine(label: Loc.t("최근 7일 · \(tokens) 토큰", "Last 7 days · \(tokens) tokens"),
                                          amountUSD: cost, isEstimate: true))
        }

        if let block = ClaudeBlockCalculator.blocks(for: recent).last, block.isActive(now: now) {
            let totals = ClaudeUsageTotals.of(block.entries)
            let tokens = MetricFormat.tokens(totals.tokens.total)
            var detail = Loc.t("\(tokens) 토큰", "\(tokens) tokens")
            if let cost = totals.estimatedCostUSD { detail += " · ~" + MetricFormat.usd(cost) }
            result.windows = [QuotaWindow(id: ClaudeWindow.fiveHourBlock, label: ClaudeWindow.label(for: ClaudeWindow.fiveHourBlock),
                                          usedFraction: nil, resetsAt: block.end, detail: detail)]
        }

        if !week.unpricedModels.isEmpty {
            let models = week.unpricedModels.sorted().joined(separator: ", ")
            result.notes.append(Loc.t("가격 정보가 없는 모델은 비용에서 제외: \(models)", "Cost excludes models without a price: \(models)"))
        }
        result.dataAsOf = last.timestamp
        result.message = Loc.t("최근 7일 \(recent.count)건", "\(recent.count) entries in 7 days")
        return .success(result)
    }
}
