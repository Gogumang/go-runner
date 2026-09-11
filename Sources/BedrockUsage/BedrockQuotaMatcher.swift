import Foundation

/// One entry from `aws service-quotas list-service-quotas --service-code bedrock`.
struct BedrockServiceQuota: Codable, Sendable, Equatable {
    var code: String
    var name: String
    var value: Double
    var unit: String?
}

/// A quota name parsed into kind, scope and model tokens.
struct ParsedQuotaName: Sendable, Equatable {
    enum Kind: String, Sendable { case tokensPerMinute, requestsPerMinute }
    var kind: Kind
    var scope: BedrockInferenceScope
    var modelTokens: [String]
}

/// Matches CloudWatch `ModelId` values to Service Quotas entries by name.
///
/// Quota names come in two generations (both handled):
/// - "On-demand InvokeModel tokens per minute for Anthropic Claude Sonnet 4.5"
/// - "Cross-region model inference tokens per minute for Anthropic Claude Sonnet 4.5"
/// - "Global cross-Region model inference tokens per minute for Anthropic Claude Opus 5"
/// - "InvokeModel requests per minute for Anthropic Claude 3 Haiku" (RPM; no scope word = on-demand)
///
/// Approach: split the name into `<scope words> (tokens|requests) per minute for <model name>`, reject scopes with
/// unknown words (batch, provisioned, input/output-token mantle quotas, latency-optimized, …), then compare the
/// normalized model token *set* of the name with the id's (vendor words, snapshot dates and v1 suffixes removed,
/// "3-5" and "3.5" both become "3.5"). Only exact set equality counts, so "Claude Opus 4" never matches
/// "Claude Opus 4.1" and "Sonnet 4" never matches a "Sonnet 4 1M Context Length" variant.
enum BedrockQuotaMatcher {
    private static let allowedScopeWords: Set<String> = [
        "on", "demand", "ondemand", "cross", "region", "crossregion", "global", "invokemodel", "model", "inference",
    ]

    static func parse(quotaName: String) -> ParsedQuotaName? {
        let lower = quotaName.lowercased()
        let kind: ParsedQuotaName.Kind
        let marker: String
        if let r = lower.range(of: " tokens per minute for ") {
            kind = .tokensPerMinute
            marker = String(lower[r])
        } else if let r = lower.range(of: " requests per minute for ") {
            kind = .requestsPerMinute
            marker = String(lower[r])
        } else {
            return nil
        }
        guard let range = lower.range(of: marker) else { return nil }
        let scopePart = String(lower[..<range.lowerBound])
        let modelPart = String(quotaName[range.upperBound...])
        let scopeWords = scopePart.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        guard scopeWords.allSatisfy({ allowedScopeWords.contains($0) }) else { return nil }
        let scope: BedrockInferenceScope
        if scopeWords.contains("global") {
            scope = .global
        } else if scopeWords.contains("cross") || scopeWords.contains("crossregion") {
            scope = .crossRegion
        } else {
            scope = .onDemand
        }
        let tokens = BedrockModelTokenizer.modelTokens(fromName: modelPart)
        guard !tokens.isEmpty else { return nil }
        return ParsedQuotaName(kind: kind, scope: scope, modelTokens: tokens)
    }

    /// Best quota of `kind` for `modelID`. Global ids fall back to cross-region quotas when no global quota exists.
    static func match(modelID: String, kind: ParsedQuotaName.Kind, quotas: [BedrockServiceQuota]) -> BedrockServiceQuota? {
        let model = BedrockModelID(modelID)
        guard !model.tokens.isEmpty else { return nil }
        let wanted = Set(model.tokens)
        let candidates = quotas.compactMap { quota -> (BedrockServiceQuota, ParsedQuotaName)? in
            guard let parsed = parse(quotaName: quota.name), parsed.kind == kind, Set(parsed.modelTokens) == wanted else { return nil }
            return (quota, parsed)
        }
        let scopeOrder: [BedrockInferenceScope] = switch model.scope {
        case .global: [.global, .crossRegion]
        case .crossRegion: [.crossRegion]
        case .onDemand: [.onDemand]
        }
        for scope in scopeOrder {
            if let hit = candidates.first(where: { $0.1.scope == scope }) { return hit.0 }
        }
        return nil
    }

    static func tpmQuota(for modelID: String, in quotas: [BedrockServiceQuota]) -> BedrockServiceQuota? {
        match(modelID: modelID, kind: .tokensPerMinute, quotas: quotas)
    }

    static func rpmQuota(for modelID: String, in quotas: [BedrockServiceQuota]) -> BedrockServiceQuota? {
        match(modelID: modelID, kind: .requestsPerMinute, quotas: quotas)
    }
}
