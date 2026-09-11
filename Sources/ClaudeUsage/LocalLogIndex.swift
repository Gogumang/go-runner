import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One assistant message's token usage from a Claude Code transcript line.
struct ClaudeUsageEntry: Sendable, Equatable {
    var timestamp: Date
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    /// All cache-creation tokens (5-minute + 1-hour).
    var cacheCreationTokens: Int
    /// The 1-hour-TTL part of `cacheCreationTokens` (priced at 2× input instead of 1.25×).
    var cacheCreation1hTokens: Int
    var cacheReadTokens: Int
    var isFastMode: Bool
    var messageID: String?
    var requestID: String?

    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }

    /// `message.id + requestId` — streaming writes the same message several times with growing usage.
    var dedupeKey: String? { messageID.map { "\($0)|\(requestID ?? "")" } }
}

enum ClaudeJSONLParser {
    private struct Line: Decodable {
        var type: String?
        var timestamp: String?
        var requestId: String?
        var message: Message?
    }

    private struct Message: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?
    }

    private struct Usage: Decodable {
        var input = 0
        var output = 0
        var cacheCreation = 0
        var cacheCreation1h = 0
        var cacheRead = 0
        var speed: String?

        enum CodingKeys: String, CodingKey {
            case input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens, cache_creation, speed
        }

        enum CacheKeys: String, CodingKey {
            case ephemeral_1h_input_tokens
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            input = Self.int(container, .input_tokens)
            output = Self.int(container, .output_tokens)
            cacheCreation = Self.int(container, .cache_creation_input_tokens)
            cacheRead = Self.int(container, .cache_read_input_tokens)
            if let split = try? container.nestedContainer(keyedBy: CacheKeys.self, forKey: .cache_creation) {
                if let value = try? split.decodeIfPresent(Int.self, forKey: .ephemeral_1h_input_tokens) {
                    cacheCreation1h = value
                } else if let value = try? split.decodeIfPresent(Double.self, forKey: .ephemeral_1h_input_tokens) {
                    cacheCreation1h = Int(value)
                }
            }
            speed = try? container.decodeIfPresent(String.self, forKey: .speed)
        }

        private static func int(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
            return 0
        }
    }

    private static let usageNeedle = Array("\"usage\"".utf8)
    private static let assistantNeedle = Array("\"assistant\"".utf8)

    /// Parses complete lines. `consumed` is the byte count through the last complete line, so a line that is
    /// still being written is re-read next time. A final unterminated line is consumed only if it is a
    /// complete assistant usage entry.
    static func parse(_ data: Data) -> (entries: [ClaudeUsageEntry], consumed: Int) {
        let decoder = JSONDecoder()
        var entries: [ClaudeUsageEntry] = []
        var consumed = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            let count = raw.count
            var start = 0
            while start < count {
                guard let newline = memchr(base + start, 0x0A, count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(newline))
                if let entry = entry(base + start, length: end - start, decoder: decoder) {
                    entries.append(entry)
                }
                start = end + 1
                consumed = start
            }
            if start < count, let entry = entry(base + start, length: count - start, decoder: decoder) {
                entries.append(entry)
                consumed = count
            }
        }
        return (entries, consumed)
    }

    private static func contains(_ base: UnsafeRawPointer, _ length: Int, _ needle: [UInt8]) -> Bool {
        needle.withUnsafeBytes { memmem(base, length, $0.baseAddress, $0.count) != nil }
    }

    private static func entry(_ base: UnsafeRawPointer, length: Int, decoder: JSONDecoder) -> ClaudeUsageEntry? {
        // Cheap byte pre-filter: most lines are user/tool/attachment records.
        guard length > 20, contains(base, length, usageNeedle), contains(base, length, assistantNeedle) else { return nil }
        guard let line = try? decoder.decode(Line.self, from: Data(bytes: base, count: length)),
              line.type == "assistant",
              let message = line.message, let usage = message.usage,
              let timestamp = line.timestamp.flatMap(ClaudeTimestamp.parse)
        else { return nil }
        let model = message.model ?? "unknown"
        if model == "<synthetic>" { return nil }
        return ClaudeUsageEntry(timestamp: timestamp, model: model,
                                inputTokens: usage.input, outputTokens: usage.output,
                                cacheCreationTokens: usage.cacheCreation,
                                cacheCreation1hTokens: min(usage.cacheCreation1h, usage.cacheCreation),
                                cacheReadTokens: usage.cacheRead,
                                isFastMode: usage.speed == "fast",
                                messageID: message.id, requestID: line.requestId)
    }
}

enum ClaudeUsageDeduper {
    /// Keeps one entry per `message.id + requestId`: the one with the most tokens (ccusage), at the earliest timestamp.
    static func dedupe(_ entries: [ClaudeUsageEntry]) -> [ClaudeUsageEntry] {
        var result: [ClaudeUsageEntry] = []
        result.reserveCapacity(entries.count)
        var indexByKey: [String: Int] = [:]
        for entry in entries {
            guard let key = entry.dedupeKey else {
                result.append(entry)
                continue
            }
            if let index = indexByKey[key] {
                let existing = result[index]
                var kept = entry.totalTokens > existing.totalTokens ? entry : existing
                kept.timestamp = min(existing.timestamp, entry.timestamp)
                result[index] = kept
            } else {
                indexByKey[key] = result.count
                result.append(entry)
            }
        }
        return result
    }
}

/// Incremental index of `projects/**/*.jsonl`: remembers each file's parsed entries and byte offset,
/// and on refresh reads only bytes appended since the last scan.
actor ClaudeLogIndex {
    static let shared = ClaudeLogIndex()

    struct Snapshot: Sendable {
        /// Deduplicated entries from every scanned file (any timestamp).
        var entries: [ClaudeUsageEntry]
        var fileCount: Int
        var existingRootCount: Int
        var bytesRead: Int
    }

    private struct FileState {
        var offset: Int
        var size: Int
        var modified: Date
        var entries: [ClaudeUsageEntry]
    }

    private var files: [String: FileState] = [:]

    func refresh(roots: [URL], modifiedSince: Date) -> Snapshot {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var seen = Set<String>()
        var existingRoots = 0
        var bytesRead = 0

        for root in roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            existingRoots += 1

            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let modified = values.contentModificationDate, modified >= modifiedSince
                else { continue }
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                let size = values.fileSize ?? 0

                var state = files[path] ?? FileState(offset: 0, size: 0, modified: .distantPast, entries: [])
                if size < state.offset {
                    state = FileState(offset: 0, size: 0, modified: .distantPast, entries: []) // truncated or replaced
                }
                if size > state.offset, let handle = try? FileHandle(forReadingFrom: url) {
                    defer { try? handle.close() }
                    if (try? handle.seek(toOffset: UInt64(state.offset))) != nil,
                       let data = try? handle.readToEnd(), !data.isEmpty {
                        bytesRead += data.count
                        let parsed = ClaudeJSONLParser.parse(data)
                        state.entries.append(contentsOf: parsed.entries)
                        state.offset += parsed.consumed
                    }
                }
                state.size = size
                state.modified = modified
                files[path] = state
            }
        }

        files = files.filter { seen.contains($0.key) }
        let all = files.values.flatMap(\.entries)
        return Snapshot(entries: ClaudeUsageDeduper.dedupe(all), fileCount: seen.count,
                        existingRootCount: existingRoots, bytesRead: bytesRead)
    }
}
