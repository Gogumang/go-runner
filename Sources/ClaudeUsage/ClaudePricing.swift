import Foundation

/// USD per million tokens.
struct ClaudeModelPrice: Sendable, Equatable {
    var input: Double
    var output: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var cacheRead: Double

    /// Anthropic's cache multipliers: 5-minute write 1.25× input, 1-hour write 2×, read 0.1× (unless given).
    static func standard(input: Double, output: Double, cacheRead: Double? = nil) -> ClaudeModelPrice {
        ClaudeModelPrice(input: input, output: output, cacheWrite5m: input * 1.25, cacheWrite1h: input * 2,
                         cacheRead: cacheRead ?? input * 0.1)
    }

    func scaled(by factor: Double) -> ClaudeModelPrice {
        ClaudeModelPrice(input: input * factor, output: output * factor, cacheWrite5m: cacheWrite5m * factor,
                         cacheWrite1h: cacheWrite1h * factor, cacheRead: cacheRead * factor)
    }
}

/// First-party Claude API list prices (claude-api skill model table and prompt-caching economics, checked 2026-09-11).
/// Logs are costed as if billed per token; subscription users pay a flat plan price, so this is an estimate.
enum ClaudePricing {
    static let table: [String: ClaudeModelPrice] = {
        let fable51 = ClaudeModelPrice.standard(input: 10, output: 50, cacheRead: 0.25) // cache read 0.025×
        let fable5 = ClaudeModelPrice.standard(input: 10, output: 50)
        let opus = ClaudeModelPrice.standard(input: 5, output: 25)
        let opusLegacy = ClaudeModelPrice.standard(input: 15, output: 75)
        let sonnet5 = ClaudeModelPrice.standard(input: 2, output: 10)
        let sonnet4 = ClaudeModelPrice.standard(input: 3, output: 15)
        let haiku45 = ClaudeModelPrice.standard(input: 1, output: 5)
        return [
            "claude-fable-5-1": fable51,
            "claude-mythos-5-1": fable51,
            "claude-fable-5": fable5,
            "claude-mythos-5": fable5,
            "claude-opus-5": opus,
            "claude-opus-4-8": opus,
            "claude-opus-4-7": opus,
            "claude-opus-4-6": opus,
            "claude-opus-4-5": opus,
            "claude-opus-4-1": opusLegacy,
            "claude-opus-4": opusLegacy,
            "claude-sonnet-5": sonnet5,
            "claude-sonnet-4-6": sonnet4,
            "claude-sonnet-4-5": sonnet4,
            "claude-sonnet-4": sonnet4,
            "claude-haiku-4-5": haiku45,
        ]
    }()

    /// Fast mode (`usage.speed == "fast"`): Claude Opus 5 is $10 / $50 per MTok = 2× standard.
    static let fastModeMultiplier: [String: Double] = ["claude-opus-5": 2]

    /// `us.anthropic.claude-opus-4-1-20250805-v1:0` → `claude-opus-4-1`, `claude-opus-5[1m]` → `claude-opus-5`.
    static func normalizedModelID(_ raw: String) -> String {
        var id = raw.lowercased()
        if let range = id.range(of: "claude-") { id = String(id[range.lowerBound...]) }
        for separator in ["[", "@", ":"] {
            if let index = id.firstIndex(of: Character(separator)) { id = String(id[..<index]) }
        }
        if let range = id.range(of: "-v[0-9]+$", options: .regularExpression) { id.removeSubrange(range) }
        if let range = id.range(of: "-[0-9]{8}$", options: .regularExpression) { id.removeSubrange(range) }
        return id
    }

    static func price(for model: String, fastMode: Bool = false) -> ClaudeModelPrice? {
        let id = normalizedModelID(model)
        guard let price = table[id] else { return nil }
        if fastMode, let factor = fastModeMultiplier[id] { return price.scaled(by: factor) }
        return price
    }

    static func cost(of entry: ClaudeUsageEntry, price: ClaudeModelPrice) -> Double {
        let oneHour = min(entry.cacheCreation1hTokens, entry.cacheCreationTokens)
        let fiveMinute = entry.cacheCreationTokens - oneHour
        let micros = Double(entry.inputTokens) * price.input
            + Double(entry.outputTokens) * price.output
            + Double(fiveMinute) * price.cacheWrite5m
            + Double(oneHour) * price.cacheWrite1h
            + Double(entry.cacheReadTokens) * price.cacheRead
        return micros / 1_000_000
    }

    /// nil for models not in the table (tokens still count).
    static func cost(of entry: ClaudeUsageEntry) -> Double? {
        price(for: entry.model, fastMode: entry.isFastMode).map { cost(of: entry, price: $0) }
    }
}
