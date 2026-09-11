import Foundation
import GoRunnerCore

// Rollout files: `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`. Relevant line (codex-cli 0.153.0,
// `codex-rs/protocol/src/protocol.rs` `TokenCountEvent` / `RateLimitSnapshot` / `RateLimitWindow`):
// {"timestamp":"2026-09-11T01:38:29.430Z","type":"event_msg","payload":{"type":"token_count",
//  "info":{"total_token_usage":{input_tokens,cached_input_tokens,cache_write_input_tokens,output_tokens,
//          reasoning_output_tokens,total_tokens},"last_token_usage":{…},"model_context_window":…} | null,
//  "rate_limits":{"limit_id":"codex","primary":{"used_percent":3.0,"window_minutes":300,"resets_at":1789108698},
//                 "secondary":{…},"plan_type":"plus",…} | null}}

struct CodexTokenUsage: Sendable, Equatable {
    var input = 0
    var cachedInput = 0
    var cacheWriteInput = 0
    var output = 0
    var reasoningOutput = 0
    var total = 0

    init(input: Int = 0, cachedInput: Int = 0, cacheWriteInput: Int = 0, output: Int = 0, reasoningOutput: Int = 0, total: Int = 0) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.output = output
        self.reasoningOutput = reasoningOutput
        self.total = total
    }

    init?(json: Any?) {
        guard let dict = json as? [String: Any] else { return nil }
        func int(_ key: String) -> Int { CodexResponseParser.number(dict[key]).map { Int($0) } ?? 0 }
        self.init(input: int("input_tokens"), cachedInput: int("cached_input_tokens"),
                  cacheWriteInput: int("cache_write_input_tokens"), output: int("output_tokens"),
                  reasoningOutput: int("reasoning_output_tokens"), total: int("total_tokens"))
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, cachedInput: lhs.cachedInput + rhs.cachedInput,
             cacheWriteInput: lhs.cacheWriteInput + rhs.cacheWriteInput, output: lhs.output + rhs.output,
             reasoningOutput: lhs.reasoningOutput + rhs.reasoningOutput, total: lhs.total + rhs.total)
    }

    /// Field-wise difference clamped at zero.
    func subtracting(_ other: Self) -> Self {
        Self(input: max(0, input - other.input), cachedInput: max(0, cachedInput - other.cachedInput),
             cacheWriteInput: max(0, cacheWriteInput - other.cacheWriteInput), output: max(0, output - other.output),
             reasoningOutput: max(0, reasoningOutput - other.reasoningOutput), total: max(0, total - other.total))
    }

    /// OpenAI `input_tokens` already include cached/cache-write tokens and `output_tokens` include reasoning,
    /// so `summary.total == input_tokens + output_tokens`. No cost: Codex plan usage is not billed per token.
    var summary: TokenSummary {
        TokenSummary(input: max(0, input - cachedInput - cacheWriteInput), output: output,
                     cacheCreation: cacheWriteInput, cacheRead: cachedInput, estimatedCostUSD: nil)
    }
}

struct CodexTokenCountEvent: Sendable, Equatable {
    var timestamp: Date
    var totalUsage: CodexTokenUsage?
    var lastUsage: CodexTokenUsage?
    /// nil when the event had no `rate_limits` (or no windows in it).
    var rateLimits: CodexRateLimitBucket?
}

struct CodexSessionLogResult: Sendable, Equatable {
    /// Newest `token_count` event that carried rate limits.
    var latestRateLimits: CodexTokenCountEvent?
    /// Tokens used since local midnight across sessions written today.
    var todayUsage: CodexTokenUsage?
}

struct CodexSessionLogReader: Sendable {
    var sessionsRoot: URL
    var lookbackDays = 7
    var maxFiles = 50
    var maxBytesPerFile = 32 << 20
    var maxTotalBytes = 128 << 20
    var chunkSize = 256 << 10
    var calendar = Calendar.current

    init(sessionsRoot: URL = Self.defaultSessionsRoot) {
        self.sessionsRoot = sessionsRoot
    }

    static var defaultSessionsRoot: URL {
        let codexHome: URL
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            codexHome = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        return codexHome.appendingPathComponent("sessions", isDirectory: true)
    }

    static let tokenCountMarker = Data("\"token_count\"".utf8)

    /// `*.jsonl` in the day folders of the last `lookbackDays` days, modified within that period, newest first.
    func candidateFiles(now: Date) -> [(url: URL, modified: Date)] {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        var seen = Set<String>()
        var files: [(url: URL, modified: Date)] = []
        // -1 covers folders named in a timezone ahead of ours.
        for offset in -1...lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
            let dir = sessionsRoot.appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, dayOfMonth), isDirectory: true)
            guard seen.insert(dir.path).inserted,
                  let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            for url in entries where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= cutoff else { continue }
                files.append((url, modified))
            }
        }
        return Array(files.sorted { $0.modified > $1.modified }.prefix(maxFiles))
    }

    func read(now: Date = Date()) -> Result<CodexSessionLogResult, ProviderError> {
        let files = candidateFiles(now: now)
        guard !files.isEmpty else {
            return .failure(ProviderError(kind: .noRecentData,
                                          message: Loc.t("최근 \(lookbackDays)일간 Codex 세션 기록이 없습니다",
                                                         "No Codex sessions in the last \(lookbackDays) days")))
        }
        let startOfToday = calendar.startOfDay(for: now)
        var latest: CodexTokenCountEvent?
        var today: CodexTokenUsage?
        var budget = maxTotalBytes
        for file in files {
            let wantTokens = file.modified >= startOfToday
            let wantLimits = latest == nil
            // Sorted newest first: once past today with limits found, nothing older matters.
            if !wantTokens && !wantLimits { break }
            guard budget > 0 else { break }
            let scan = scan(file: file.url, startOfToday: wantTokens ? startOfToday : nil,
                            wantRateLimits: wantLimits, byteBudget: min(maxBytesPerFile, budget))
            budget -= scan.bytesRead
            if wantLimits, let event = scan.rateLimitEvent { latest = event }
            if let usage = scan.todayUsage { today = (today ?? CodexTokenUsage()) + usage }
        }
        guard latest != nil || today != nil else {
            return .failure(ProviderError(kind: .noRecentData,
                                          message: Loc.t("최근 Codex 세션에 한도 정보가 없습니다",
                                                         "Recent Codex sessions contain no rate-limit data")))
        }
        return .success(CodexSessionLogResult(latestRateLimits: latest, todayUsage: today))
    }

    struct FileScan: Equatable {
        var rateLimitEvent: CodexTokenCountEvent?
        var todayUsage: CodexTokenUsage?
        var bytesRead: Int
    }

    /// Reads `file` backwards. Today's usage = newest `total_token_usage` minus the newest one from before
    /// `startOfToday` (zero when the session started today); robust against repeated events.
    func scan(file: URL, startOfToday: Date?, wantRateLimits: Bool, byteBudget: Int) -> FileScan {
        var rateLimitEvent: CodexTokenCountEvent?
        var latestTotal: CodexTokenUsage?
        var baseline: CodexTokenUsage?
        var reachedBeforeToday = false
        let outcome = ReverseLineReader.read(url: file, chunkSize: chunkSize, maxBytes: byteBudget,
                                             marker: Self.tokenCountMarker) { line in
            guard let event = Self.parseTokenCount(line) else { return true }
            if wantRateLimits, rateLimitEvent == nil, event.rateLimits != nil {
                rateLimitEvent = event
            }
            if let startOfToday, !reachedBeforeToday, let total = event.totalUsage {
                if event.timestamp >= startOfToday {
                    if latestTotal == nil { latestTotal = total }
                } else {
                    baseline = total
                    reachedBeforeToday = true
                }
            }
            let limitsDone = !wantRateLimits || rateLimitEvent != nil
            let tokensDone = startOfToday == nil || reachedBeforeToday
            return !(limitsDone && tokensDone)
        }
        var todayUsage: CodexTokenUsage?
        if startOfToday != nil, let latestTotal, reachedBeforeToday || outcome.reachedStart {
            todayUsage = latestTotal.subtracting(baseline ?? CodexTokenUsage())
        }
        return FileScan(rateLimitEvent: rateLimitEvent, todayUsage: todayUsage, bytesRead: outcome.bytesRead)
    }

    static func parseTokenCount(_ line: Data) -> CodexTokenCountEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let timestamp = CodexResponseParser.date(object["timestamp"])
        else { return nil }
        let info = payload["info"] as? [String: Any]
        var bucket: CodexRateLimitBucket?
        if let limits = payload["rate_limits"] as? [String: Any],
           let parsed = try? CodexResponseParser.bucket(limits, style: .rollout, reference: timestamp),
           parsed.hasWindows {
            bucket = parsed
        }
        return CodexTokenCountEvent(timestamp: timestamp,
                                    totalUsage: CodexTokenUsage(json: info?["total_token_usage"]),
                                    lastUsage: CodexTokenUsage(json: info?["last_token_usage"]),
                                    rateLimits: bucket)
    }
}

/// Yields a file's lines last-to-first, reading fixed-size chunks from the end.
enum ReverseLineReader {
    struct Outcome: Equatable {
        var bytesRead: Int
        /// True when every line down to the start of the file was visited.
        var reachedStart: Bool
    }

    /// Calls `body` for each non-empty line containing `marker` (all lines when nil), newest first.
    /// `body` returns false to stop. Stops early once `maxBytes` have been read.
    static func read(url: URL, chunkSize: Int, maxBytes: Int, marker: Data?, body: (Data) -> Bool) -> Outcome {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Outcome(bytesRead: 0, reachedStart: false) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return Outcome(bytesRead: 0, reachedStart: false) }

        var position = size
        var carry = Data()
        var bytesRead = 0
        let chunk = UInt64(max(1, chunkSize))

        func emit(_ line: Data.SubSequence) -> Bool {
            if line.isEmpty { return true }
            if let marker, line.range(of: marker) == nil { return true }
            return body(Data(line))
        }

        while position > 0 {
            if bytesRead >= maxBytes { return Outcome(bytesRead: bytesRead, reachedStart: false) }
            let start = position > chunk ? position - chunk : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let block = try? handle.read(upToCount: Int(position - start)), !block.isEmpty
            else { return Outcome(bytesRead: bytesRead, reachedStart: false) }
            bytesRead += block.count
            position = start

            var joined = Data(block)
            let newBytes = joined.count
            joined.append(carry)
            var lineEnd = joined.endIndex
            var searchEnd = joined.startIndex + newBytes // `carry` holds no newline
            while searchEnd > joined.startIndex, let newline = joined[joined.startIndex..<searchEnd].lastIndex(of: 0x0A) {
                if !emit(joined[(newline + 1)..<lineEnd]) { return Outcome(bytesRead: bytesRead, reachedStart: false) }
                lineEnd = newline
                searchEnd = newline
            }
            carry = Data(joined[joined.startIndex..<lineEnd])
            if carry.count > maxBytes { return Outcome(bytesRead: bytesRead, reachedStart: false) }
        }
        if !emit(carry[carry.startIndex..<carry.endIndex]) { return Outcome(bytesRead: bytesRead, reachedStart: false) }
        return Outcome(bytesRead: bytesRead, reachedStart: true)
    }
}
