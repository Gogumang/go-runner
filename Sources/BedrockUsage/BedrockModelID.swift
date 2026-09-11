import Foundation

/// Inference scope implied by a Bedrock model id prefix.
enum BedrockInferenceScope: String, Sendable, Equatable, Codable {
    /// `anthropic.claude-…` — in-region on-demand.
    case onDemand
    /// `us.` / `eu.` / `apac.` / `jp.` / `au.` / `ca.` / `us-gov.` inference profiles.
    case crossRegion
    /// `global.` inference profiles.
    case global
}

/// A CloudWatch `ModelId` dimension value broken into comparable parts.
///
/// Examples:
/// - `anthropic.claude-sonnet-4-5-20250929-v1:0` → provider `anthropic`, tokens `[claude, sonnet, 4.5]`, scope onDemand
/// - `us.anthropic.claude-opus-5` → provider `anthropic`, tokens `[claude, opus, 5]`, scope crossRegion, geo `us`
/// - `meta.llama3-1-70b-instruct-v1:0` → provider `meta`, tokens `[llama, 3.1, 70b, instruct]`
struct BedrockModelID: Sendable, Equatable {
    static let crossRegionPrefixes: Set<String> = ["us", "eu", "apac", "jp", "au", "ca", "us-gov", "apne", "sa"]

    let raw: String
    let scope: BedrockInferenceScope
    /// Geography prefix ("us", "global", …) or nil for on-demand ids.
    let geo: String?
    /// Vendor segment, e.g. "anthropic", "amazon", "meta". nil when the id has no vendor (e.g. an application profile ARN).
    let provider: String?
    /// Normalized model tokens (vendor names removed, versions joined with ".").
    let tokens: [String]

    init(_ raw: String) {
        self.raw = raw
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Inference profile ARNs: arn:aws:bedrock:us-east-1:123:inference-profile/us.anthropic.claude-…
        if id.lowercased().hasPrefix("arn:"), let slash = id.lastIndex(of: "/") {
            id = String(id[id.index(after: slash)...])
        }
        var parts = id.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var scope = BedrockInferenceScope.onDemand
        var geo: String?
        if parts.count >= 3, let first = parts.first?.lowercased() {
            if first == "global" {
                scope = .global
                geo = first
                parts.removeFirst()
            } else if Self.crossRegionPrefixes.contains(first) {
                scope = .crossRegion
                geo = first
                parts.removeFirst()
            }
        }
        self.scope = scope
        self.geo = geo
        if parts.count >= 2 {
            provider = parts[0].lowercased()
            // Re-join the rest (model names like "llama3.1" are rare, but keep dots between digits).
            tokens = BedrockModelTokenizer.modelTokens(fromID: parts.dropFirst().joined(separator: "."))
        } else {
            provider = nil
            tokens = BedrockModelTokenizer.modelTokens(fromID: id)
        }
    }

    var isAnthropic: Bool { provider == "anthropic" }

    /// Claude family word, e.g. "opus", "sonnet", "haiku", "fable".
    var family: String? {
        tokens.first { ["opus", "sonnet", "haiku", "fable", "mythos", "instant"].contains($0) }
    }

    /// First version-like token as (major, minor), e.g. "4.5" → (4, 5), "5" → (5, 0).
    var version: (major: Int, minor: Int)? {
        for token in tokens {
            let comps = token.split(separator: ".")
            guard !comps.isEmpty, comps.count <= 2, comps.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { continue }
            guard let major = Int(comps[0]) else { continue }
            let minor = comps.count == 2 ? Int(comps[1]) ?? 0 : 0
            return (major, minor)
        }
        return nil
    }

    /// Short display name: "Sonnet 4.5", "Opus 5", "Nova Pro", "Llama 3.1 70B Instruct". Adds "(us)" / "(global)" for profiles.
    var shortName: String {
        var words = tokens
        if isAnthropic, words.first == "claude", words.count > 1 { words.removeFirst() }
        // Claude 3.x ids put the version first ("3.5 sonnet"); show family first.
        if isAnthropic, words.count == 2, words[0].first?.isNumber == true, words[1].first?.isLetter == true {
            words.swapAt(0, 1)
        }
        let pretty = words.map { word -> String in
            if word.first?.isNumber == true { return word.uppercased() }
            if word.count <= 2, word.hasPrefix("v") == false, word != "r" { return word.uppercased() }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
        let base = pretty.isEmpty ? raw : pretty
        if let geo { return "\(base) (\(geo))" }
        return base
    }
}

enum BedrockModelTokenizer {
    /// Words that identify a vendor rather than a model. Removed from both ids and quota names before comparing.
    static let vendorWords: Set<String> = [
        "anthropic", "amazon", "meta", "mistral", "mistralai", "cohere", "ai21", "ai21labs", "labs", "deepseek",
        "openai", "qwen", "writer", "twelvelabs", "stability", "luma", "google", "moonshot", "minimax", "nvidia",
    ]

    /// Tokens for the model part of a Bedrock id (after the geo and vendor prefix), e.g. `claude-3-5-sonnet-20241022-v2:0`.
    static func modelTokens(fromID model: String) -> [String] {
        var s = model.lowercased()
        // "-v1:0", "-v2:0", ":0", "-v1" suffixes; "gpt-oss-120b-1:0" style "-N:M".
        var versionSuffix: String?
        if let range = s.range(of: #"-v(\d+)(:\d+)?$"#, options: .regularExpression) {
            let digits = s[range].dropFirst(2).prefix { $0.isNumber }
            if let n = Int(digits), n >= 2 { versionSuffix = "v\(n)" }
            s.removeSubrange(range)
        } else if let range = s.range(of: #"-\d+:\d+$"#, options: .regularExpression) {
            s.removeSubrange(range)
        } else if let range = s.range(of: #":\d+$"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        var tokens = normalize(s)
        if let versionSuffix { tokens.append(versionSuffix) }
        return tokens
    }

    /// Tokens for a human model name from Service Quotas, e.g. "Anthropic Claude 3.5 Sonnet V2".
    static func modelTokens(fromName name: String) -> [String] {
        var s = name.lowercased()
        // Drop parentheticals like "(doubled for cross-region calls)".
        while let range = s.range(of: #"\([^)]*\)"#, options: .regularExpression) {
            s.removeSubrange(range)
        }
        return normalize(s)
    }

    /// Shared normalization: split on separators and letter→digit boundaries, drop dates, "v0"/"v1" and vendor words,
    /// and join runs of short numbers into dotted versions ("3","5" → "3.5").
    static func normalize(_ input: String) -> [String] {
        let raw = input.split { !($0.isLetter || $0.isNumber || $0 == ".") }.map(String.init)
        var pieces: [String] = []
        for token in raw {
            for dotted in splitDots(token) {
                pieces += splitLetterDigit(dotted)
            }
        }
        var out: [String] = []
        var numberRun: [String] = []
        func flushRun() {
            guard !numberRun.isEmpty else { return }
            // Join at most major.minor; extra numbers become separate tokens.
            var index = 0
            while index < numberRun.count {
                if index + 1 < numberRun.count {
                    out.append("\(numberRun[index]).\(numberRun[index + 1])")
                    index += 2
                } else {
                    out.append(numberRun[index])
                    index += 1
                }
            }
            numberRun.removeAll()
        }
        for piece in pieces {
            if piece.isEmpty { continue }
            if piece.count == 8, piece.allSatisfy(\.isNumber) { continue } // 20250929 snapshot date
            if piece == "v0" || piece == "v1" { continue }
            if vendorWords.contains(piece) { continue }
            if piece.allSatisfy(\.isNumber), piece.count <= 2 {
                numberRun.append(String(Int(piece) ?? 0))
                continue
            }
            if piece.contains("."), piece.split(separator: ".").allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                flushRun()
                out.append(piece)
                continue
            }
            flushRun()
            out.append(piece)
        }
        flushRun()
        return out
    }

    /// "3.5" stays; "llama3.1" → ["llama", "3.1"]; trailing dots are removed.
    private static func splitDots(_ token: String) -> [String] {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if trimmed.isEmpty { return [] }
        let comps = trimmed.split(separator: ".").map(String.init)
        if comps.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return [trimmed] }
        // No dot: leave "v2", "70b", "llama3" to splitLetterDigit.
        guard trimmed.contains(".") else { return [trimmed] }
        // Mixed: split letters from the dotted number, e.g. "llama3.1"
        if let firstDigit = trimmed.firstIndex(where: \.isNumber), firstDigit != trimmed.startIndex,
           trimmed[..<firstDigit].allSatisfy(\.isLetter) {
            let rest = String(trimmed[firstDigit...])
            if rest.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                return [String(trimmed[..<firstDigit]), rest]
            }
        }
        return comps
    }

    /// Splits a letters→digits boundary ("llama3" → "llama", "3"; "r1" → "r", "1") but keeps sizes like "70b".
    /// "v2" is kept intact so quota names like "Claude 3.5 Sonnet V2" line up with `-v2:0` ids.
    private static func splitLetterDigit(_ token: String) -> [String] {
        if token.contains(".") { return [token] }
        if token.range(of: #"^v\d+$"#, options: .regularExpression) != nil { return [token] }
        guard let range = token.range(of: #"^[a-z]+\d+$"#, options: .regularExpression), range == token.startIndex..<token.endIndex,
              let firstDigit = token.firstIndex(where: \.isNumber)
        else { return [token] }
        return [String(token[..<firstDigit]), String(token[firstDigit...])]
    }
}

// MARK: - Output-token burndown

/// Output-token burndown multipliers for the bedrock-runtime TPM quota.
///
/// Source: docs/research/04-ai-quota.md §4.2 (AWS "quotas-token-burndown"):
/// a request settles to `InputTokenCount + CacheWriteInputTokenCount + OutputTokenCount × burndown`.
/// - Claude 4.8 (e.g. Opus 4.8): 15×
/// - Claude Opus 5 / Sonnet 5 / Fable 5.1 (and other 5.x): 10×
/// - Other Anthropic models from Claude 3.7 up to 4.7: 5×
/// - Older Claude (3, 3.5) and non-Anthropic models: 1×
enum BedrockBurndown {
    static func multiplier(for model: BedrockModelID) -> Double {
        guard model.isAnthropic, let version = model.version else { return 1 }
        switch (version.major, version.minor) {
        case (4, 8): return 15
        case let (major, _) where major >= 5: return 10
        case (4, _): return 5
        case let (3, minor) where minor >= 7: return 5
        default: return 1
        }
    }
}
