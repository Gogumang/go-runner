import Foundation
import GoRunnerCore
import XCTest
@testable import ClaudeUsage

final class LocalLogTests: XCTestCase {
    private func fixtureSnapshot() async -> ClaudeLogIndex.Snapshot {
        await ClaudeLogIndex().refresh(roots: [Fixture.url("projects")], modifiedSince: .distantPast)
    }

    // MARK: Parsing and dedupe

    func testParsesNestedFilesAndDedupes() async throws {
        let snapshot = await fixtureSnapshot()
        XCTAssertEqual(snapshot.existingRootCount, 1)
        XCTAssertEqual(snapshot.fileCount, 2, "includes <session>/subagents/*.jsonl")
        let entries = snapshot.entries.sorted { $0.timestamp < $1.timestamp }
        // user line with usage, malformed line and <synthetic> are skipped; msg_1 appears 3× across 2 files.
        XCTAssertEqual(entries.map(\.messageID), ["msg_1", "msg_2", "msg_3", "msg_4", "msg_5", "msg_6"])
        XCTAssertEqual(entries[0].outputTokens, 500, "keeps the final streaming chunk")
        XCTAssertEqual(entries[0].timestamp, utcDate("2026-09-10T01:10:00Z"))
        XCTAssertEqual(entries[0].cacheCreationTokens, 1000)
        XCTAssertEqual(entries[0].cacheReadTokens, 2000)
        XCTAssertEqual(entries[5].model, "claude-fable-5-1")
        XCTAssertEqual(entries[5].cacheCreation1hTokens, 2000)
    }

    func testDedupeKeepsLargestUsageAndEarliestTime() {
        let chunk = makeEntry("2026-09-10T00:00:00Z", output: 5, id: "m", request: "r")
        let final = makeEntry("2026-09-10T00:00:03Z", output: 700, id: "m", request: "r")
        let otherRequest = makeEntry("2026-09-10T00:00:04Z", output: 1, id: "m", request: "r2")
        let noID = makeEntry("2026-09-10T00:00:05Z")
        let result = ClaudeUsageDeduper.dedupe([final, chunk, otherRequest, noID, noID])
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0].outputTokens, 700)
        XCTAssertEqual(result[0].timestamp, utcDate("2026-09-10T00:00:00Z"))
    }

    func testTimestampParser() {
        XCTAssertEqual(ClaudeTimestamp.parse("2026-09-11T00:58:23.590Z")?.timeIntervalSince1970 ?? 0,
                       utcDate("2026-09-11T00:58:23.590Z").timeIntervalSince1970, accuracy: 0.0005)
        XCTAssertEqual(ClaudeTimestamp.parse("2024-02-29T12:00:00.5Z")?.timeIntervalSince1970 ?? 0, 1_709_208_000.5, accuracy: 0.0005)
        XCTAssertEqual(ClaudeTimestamp.parse("1999-12-31T23:59:59.123456Z")?.timeIntervalSince1970 ?? 0, 946_684_799.123456, accuracy: 0.000_01)
        XCTAssertEqual(ClaudeTimestamp.parse("2026-09-15T18:00:00+09:00"), utcDate("2026-09-15T09:00:00Z"))
        XCTAssertEqual(ClaudeTimestamp.parse("2026-09-15T09:00:00+00:00"), utcDate("2026-09-15T09:00:00Z"))
        XCTAssertNil(ClaudeTimestamp.parse("not a date"))
        XCTAssertNil(ClaudeTimestamp.parse("2026-13-45T00:00:00Z"))
    }

    func testIncrementalIndexReadsOnlyAppendedBytes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        let folder = projects.appendingPathComponent("-Users-test-project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("session.jsonl")

        func line(_ id: String, _ time: String) -> String {
            #"{"type":"assistant","timestamp":"\#(time)","requestId":"req_\#(id)","message":{"id":"\#(id)","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        }
        let line1 = line("a", "2026-09-10T10:00:00.000Z")
        let line2 = line("b", "2026-09-10T10:01:00.000Z")
        let line3 = line("c", "2026-09-10T10:02:00.000Z")
        let split = line2.count / 2
        try Data((line1 + "\n" + String(line2.prefix(split))).utf8).write(to: file)

        let index = ClaudeLogIndex()
        let first = await index.refresh(roots: [projects], modifiedSince: .distantPast)
        XCTAssertEqual(first.entries.compactMap(\.messageID), ["a"], "a half-written line is not consumed")

        let appended = Data((String(line2.dropFirst(split)) + "\n" + line3 + "\n").utf8)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: appended)
        try handle.close()

        let second = await index.refresh(roots: [projects], modifiedSince: .distantPast)
        XCTAssertEqual(Set(second.entries.compactMap(\.messageID)), ["a", "b", "c"])
        XCTAssertEqual(second.bytesRead, split + appended.count, "re-reads only from the end of line 1")

        let third = await index.refresh(roots: [projects], modifiedSince: .distantPast)
        XCTAssertEqual(third.bytesRead, 0)
        XCTAssertEqual(third.entries.count, 3)

        let none = await index.refresh(roots: [projects], modifiedSince: Date().addingTimeInterval(3600))
        XCTAssertEqual(none.fileCount, 0, "files older than the lookback are skipped")
        XCTAssertEqual(none.entries.count, 0)
    }

    // MARK: Blocks

    func testBlocksFromFixture() async {
        let blocks = ClaudeBlockCalculator.blocks(for: await fixtureSnapshot().entries)
        XCTAssertEqual(blocks.map(\.start), [utcDate("2026-09-10T01:00:00Z"), utcDate("2026-09-10T09:00:00Z"), utcDate("2026-09-10T14:00:00Z")])
        XCTAssertEqual(blocks.map(\.entries.count), [2, 1, 3])
        XCTAssertEqual(blocks[2].end, utcDate("2026-09-10T19:00:00Z"))
        XCTAssertTrue(blocks[2].isActive(now: utcDate("2026-09-10T15:00:00Z")))
        XCTAssertFalse(blocks[2].isActive(now: utcDate("2026-09-10T19:00:00Z")))
        XCTAssertFalse(blocks[1].isActive(now: utcDate("2026-09-10T15:00:00Z")))
    }

    func testBlockBoundaries() {
        // Exactly 5 h after the block start stays in the block (the rule is strictly greater).
        let exact = ClaudeBlockCalculator.blocks(for: [makeEntry("2026-09-10T10:00:00Z"), makeEntry("2026-09-10T15:00:00Z")])
        XCTAssertEqual(exact.count, 1)

        // More than 5 h after the block start, though under 5 h after the previous message: new block, floored to the hour.
        let byStart = ClaudeBlockCalculator.blocks(for: [makeEntry("2026-09-10T10:20:00Z"), makeEntry("2026-09-10T13:00:00Z"),
                                                         makeEntry("2026-09-10T15:30:00Z")])
        XCTAssertEqual(byStart.map(\.start), [utcDate("2026-09-10T10:00:00Z"), utcDate("2026-09-10T15:00:00Z")])
        XCTAssertEqual(byStart.map(\.entries.count), [2, 1])

        // A gap of more than 5 h since the previous message.
        let gap = ClaudeBlockCalculator.blocks(for: [makeEntry("2026-09-10T22:40:00Z"), makeEntry("2026-09-10T22:50:00Z"),
                                                     makeEntry("2026-09-11T04:05:00Z")])
        XCTAssertEqual(gap.map(\.start), [utcDate("2026-09-10T22:00:00Z"), utcDate("2026-09-11T04:00:00Z")])
        XCTAssertEqual(gap[1].end, utcDate("2026-09-11T09:00:00Z"))

        XCTAssertEqual(ClaudeBlockCalculator.blocks(for: []).count, 0)
    }

    // MARK: Pricing

    func testCostMath() async throws {
        let entries = await fixtureSnapshot().entries
        let byID = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.messageID.map { ($0, entry) } })
        // Opus 5: 100×$5 + 500×$25 + 1000×$6.25 (5m write) + 2000×$0.50 (read) = $0.02025
        XCTAssertEqual(try XCTUnwrap(ClaudePricing.cost(of: try XCTUnwrap(byID["msg_1"]))), 0.02025, accuracy: 1e-12)
        // Sonnet 5: 1000×$2 + 1000×$10 = $0.012
        XCTAssertEqual(try XCTUnwrap(ClaudePricing.cost(of: try XCTUnwrap(byID["msg_2"]))), 0.012, accuracy: 1e-12)
        // Fable 5.1: 100×$50 + 2000×$20 (1h write) + 10000×$0.25 (read) = $0.0475
        XCTAssertEqual(try XCTUnwrap(ClaudePricing.cost(of: try XCTUnwrap(byID["msg_6"]))), 0.0475, accuracy: 1e-12)
        XCTAssertNil(ClaudePricing.cost(of: try XCTUnwrap(byID["msg_5"])), "unknown model has no cost")

        let totals = ClaudeUsageTotals.of(entries)
        XCTAssertEqual(totals.costUSD, 0.02025 + 0.012 + 0.0003 + 0.055 + 0.0475, accuracy: 1e-9)
        XCTAssertEqual(totals.unpricedModels, ["claude-mystery-9"])
        XCTAssertEqual(totals.tokens.input, 2160)
        XCTAssertEqual(totals.tokens.output, 3660)
        XCTAssertEqual(totals.tokens.cacheCreation, 3000)
        XCTAssertEqual(totals.tokens.cacheRead, 12000)
        XCTAssertEqual(totals.tokens.estimatedCostUSD ?? 0, 0.13505, accuracy: 1e-9)
    }

    func testFastModeAndCacheTTLPricing() {
        var entry = ClaudeUsageEntry(timestamp: Date(), model: "claude-opus-5", inputTokens: 1_000_000, outputTokens: 0,
                                     cacheCreationTokens: 0, cacheCreation1hTokens: 0, cacheReadTokens: 0,
                                     isFastMode: true, messageID: nil, requestID: nil)
        XCTAssertEqual(ClaudePricing.cost(of: entry) ?? 0, 10, accuracy: 1e-9, "Opus 5 fast mode is $10/MTok input")
        entry.isFastMode = false
        entry.inputTokens = 0
        entry.cacheCreationTokens = 1_000_000
        XCTAssertEqual(ClaudePricing.cost(of: entry) ?? 0, 6.25, accuracy: 1e-9, "5-minute write 1.25×")
        entry.cacheCreation1hTokens = 1_000_000
        XCTAssertEqual(ClaudePricing.cost(of: entry) ?? 0, 10, accuracy: 1e-9, "1-hour write 2×")
        entry.model = "claude-haiku-4-5-20251001"
        entry.cacheCreationTokens = 0
        entry.cacheCreation1hTokens = 0
        entry.cacheReadTokens = 1_000_000
        XCTAssertEqual(ClaudePricing.cost(of: entry) ?? 0, 0.1, accuracy: 1e-9, "read 0.1×")
    }

    func testModelNormalization() {
        XCTAssertEqual(ClaudePricing.normalizedModelID("us.anthropic.claude-opus-4-1-20250805-v1:0"), "claude-opus-4-1")
        XCTAssertEqual(ClaudePricing.normalizedModelID("claude-sonnet-4-20250514"), "claude-sonnet-4")
        XCTAssertEqual(ClaudePricing.normalizedModelID("claude-opus-5[1m]"), "claude-opus-5")
        XCTAssertEqual(ClaudePricing.normalizedModelID("claude-opus-4-5@20251101"), "claude-opus-4-5")
        XCTAssertEqual(ClaudePricing.price(for: "claude-opus-4-1-20250805")?.input, 15)
        XCTAssertEqual(ClaudePricing.price(for: "claude-opus-4-8")?.output, 25)
        XCTAssertEqual(ClaudePricing.price(for: "claude-sonnet-5")?.input, 2)
        XCTAssertEqual(ClaudePricing.price(for: "claude-sonnet-4-6")?.output, 15)
        XCTAssertEqual(ClaudePricing.price(for: "claude-fable-5-1")?.cacheRead, 0.25)
        XCTAssertEqual(ClaudePricing.price(for: "claude-fable-5")?.cacheRead, 1)
        XCTAssertNil(ClaudePricing.price(for: "claude-opus-4-9"))
        XCTAssertNil(ClaudePricing.price(for: "gpt-5"))
    }

    // MARK: Summary

    func testSummaryWindowTokensAndSpend() async throws {
        let entries = await fixtureSnapshot().entries
        let now = utcDate("2026-09-10T15:00:00Z")
        let result = try XCTUnwrap(ClaudeLogSummarizer.summarize(entries, now: now, calendar: utcCalendar).result)

        XCTAssertEqual(result.windows.count, 1)
        let block = result.windows[0]
        XCTAssertEqual(block.id, "five_hour_block")
        XCTAssertEqual(block.label, Loc.t("5시간 블록 (로그)", "5h block (logs)"))
        XCTAssertNil(block.usedFraction)
        XCTAssertEqual(block.resetsAt, utcDate("2026-09-10T19:00:00Z"))
        XCTAssertEqual(block.detail, Loc.t("15.2K 토큰 · ~$0.10", "15.2K tokens · ~$0.10"))

        XCTAssertEqual(result.tokens?.total, 20_820)
        XCTAssertEqual(result.tokens?.estimatedCostUSD ?? 0, 0.13505, accuracy: 1e-9)
        XCTAssertEqual(result.spend.count, 2)
        XCTAssertTrue(result.spend.allSatisfy(\.isEstimate))
        XCTAssertEqual(result.spend[0].amountUSD, 0.13505, accuracy: 1e-9)
        XCTAssertEqual(result.spend[1].amountUSD, 0.13505, accuracy: 1e-9)
        XCTAssertEqual(result.dataAsOf, utcDate("2026-09-10T14:30:00Z"))
        XCTAssertEqual(result.notes.count, 1, "unpriced model note")

        let nextDay = try XCTUnwrap(ClaudeLogSummarizer.summarize(entries, now: utcDate("2026-09-11T09:00:00Z"), calendar: utcCalendar).result)
        XCTAssertEqual(nextDay.windows, [], "block no longer active")
        XCTAssertEqual(nextDay.tokens?.total, 0)
        XCTAssertEqual(nextDay.spend.first?.amountUSD, 0)

        let muchLater = ClaudeLogSummarizer.summarize(entries, now: utcDate("2026-09-18T15:00:00Z"), calendar: utcCalendar)
        XCTAssertEqual(muchLater.error?.kind, .noRecentData)
    }
}
