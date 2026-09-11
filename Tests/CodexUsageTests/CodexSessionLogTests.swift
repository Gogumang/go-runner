import Foundation
import GoRunnerCore
import XCTest
@testable import CodexUsage

final class CodexSessionLogTests: XCTestCase {
    private var temp: TempDirectory!
    private let now = UTC.date("2026-09-11T03:00:00Z")

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp.remove()
    }

    private func reader(chunkSize: Int = 64) -> CodexSessionLogReader {
        var reader = CodexSessionLogReader(sessionsRoot: temp.url.appendingPathComponent("sessions"))
        reader.calendar = UTC.calendar
        reader.chunkSize = chunkSize
        return reader
    }

    @discardableResult
    private func place(_ contents: Data, day: String, name: String, modified: Date) throws -> URL {
        let dir = temp.url.appendingPathComponent("sessions/\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try contents.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        return file
    }

    // MARK: Tail parsing

    func testLatestTokenCountWinsAndTodayUsageIsDelta() throws {
        let file = try place(Data(contentsOf: Fixtures.url("session-rollout.jsonl")), day: "2026/09/11",
                             name: "rollout-a.jsonl", modified: now)
        for chunk in [7, 64, 1 << 20] {
            let scan = reader(chunkSize: chunk).scan(file: file, startOfToday: UTC.date("2026-09-11T00:00:00Z"),
                                                     wantRateLimits: true, byteBudget: 1 << 20)
            let event = try XCTUnwrap(scan.rateLimitEvent, "chunk \(chunk)")
            XCTAssertEqual(event.timestamp, UTC.date("2026-09-11T01:00:00Z"))
            XCTAssertEqual(event.rateLimits?.primary?.usedPercent, 12.5)
            XCTAssertEqual(event.rateLimits?.planType, "pro")
            XCTAssertEqual(scan.todayUsage, CodexTokenUsage(input: 4000, cachedInput: 1800, cacheWriteInput: 100,
                                                            output: 400, reasoningOutput: 40, total: 4400), "chunk \(chunk)")
        }
    }

    func testScanStopsEarlyWithoutTokens() throws {
        let file = try place(Data(contentsOf: Fixtures.url("session-rollout.jsonl")), day: "2026/09/11",
                             name: "rollout-a.jsonl", modified: now)
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        let scan = reader(chunkSize: 128).scan(file: file, startOfToday: nil, wantRateLimits: true, byteBudget: 1 << 20)
        XCTAssertNotNil(scan.rateLimitEvent)
        XCTAssertLessThan(scan.bytesRead, size, "should not read the whole file once the newest event is found")
    }

    func testNullRateLimitsAreSkippedAndLegacyResetsInSeconds() throws {
        let lines = [
            #"{"timestamp":"2026-09-11T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":55.0,"window_minutes":300,"resets_in_seconds":3600}}}}"#,
            #"{"timestamp":"2026-09-11T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":1,"total_tokens":11}},"rate_limits":null}}"#,
            #"{"timestamp":"2026-09-11T02:00:01Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":null,"secondary":null}}}"#,
            #"{"timestamp":"2026-09-11T02:00:02Z","type":"event_msg","payload":{"type":"token_co"#, // partial line being written
        ]
        let file = try place(Data(lines.joined(separator: "\n").utf8), day: "2026/09/11", name: "legacy.jsonl", modified: now)
        let scan = reader().scan(file: file, startOfToday: nil, wantRateLimits: true, byteBudget: 1 << 20)
        let event = try XCTUnwrap(scan.rateLimitEvent)
        XCTAssertEqual(event.timestamp, UTC.date("2026-09-11T01:00:00Z"))
        XCTAssertEqual(event.rateLimits?.primary?.resetsAt, UTC.date("2026-09-11T02:00:00Z"))
    }

    func testReverseLineReaderVisitsEveryLineInReverse() throws {
        let text = "first\nsecond line\n\nthird\nlast-without-newline"
        let file = try place(Data(text.utf8), day: "x", name: "lines.txt", modified: now)
        for chunk in [1, 3, 5, 100] {
            var seen: [String] = []
            let outcome = ReverseLineReader.read(url: file, chunkSize: chunk, maxBytes: 1 << 20, marker: nil) { line in
                seen.append(String(decoding: line, as: UTF8.self))
                return true
            }
            XCTAssertEqual(seen, ["last-without-newline", "third", "second line", "first"], "chunk \(chunk)")
            XCTAssertTrue(outcome.reachedStart)
        }
        let limited = ReverseLineReader.read(url: file, chunkSize: 4, maxBytes: 8, marker: nil) { _ in true }
        XCTAssertFalse(limited.reachedStart)
        XCTAssertLessThanOrEqual(limited.bytesRead, 8)
    }

    // MARK: Directory scan

    func testReadPicksNewestFileAndSumsToday() throws {
        try place(Data(contentsOf: Fixtures.url("session-rollout.jsonl")), day: "2026/09/11", name: "rollout-new.jsonl",
                  modified: now.addingTimeInterval(-600))
        let older = [
            #"{"timestamp":"2026-09-11T00:10:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"total_tokens":110}},"rate_limits":{"primary":{"used_percent":90.0,"window_minutes":300,"resets_at":1789099200},"plan_type":"plus"}}}"#,
        ].joined(separator: "\n") + "\n"
        try place(Data(older.utf8), day: "2026/09/11", name: "rollout-old.jsonl", modified: now.addingTimeInterval(-7200))
        // Outside the 7-day window: ignored even though it has limits.
        try place(Data(older.utf8), day: "2026/09/01", name: "rollout-ancient.jsonl", modified: UTC.date("2026-09-01T10:00:00Z"))

        let reader = reader()
        XCTAssertEqual(reader.candidateFiles(now: now).map(\.url.lastPathComponent), ["rollout-new.jsonl", "rollout-old.jsonl"])

        let result = try reader.read(now: now).get()
        XCTAssertEqual(result.latestRateLimits?.rateLimits?.primary?.usedPercent, 12.5)
        XCTAssertEqual(result.todayUsage?.total, 4400 + 110)

        let snapshot = CodexSnapshotBuilder.sessionLogSnapshot(result, now: now)
        XCTAssertEqual(snapshot.trust, .heuristic)
        XCTAssertEqual(snapshot.planLabel, "Pro")
        XCTAssertEqual(snapshot.dataAsOf, UTC.date("2026-09-11T01:00:00Z"))
        XCTAssertEqual(snapshot.tokens, TokenSummary(input: 2100 + 100, output: 400 + 10, cacheCreation: 100, cacheRead: 1800))
        XCTAssertEqual(snapshot.tokens?.total, 4510)

        // Reset in the past → 0 % with a note; future reset untouched.
        XCTAssertEqual(snapshot.windows, [
            QuotaWindow(id: "primary", label: Loc.t("5시간", "5-hour"), usedFraction: 0.125, resetsAt: UTC.date("2026-09-11T04:00:00Z")),
            QuotaWindow(id: "secondary", label: Loc.t("주간", "Weekly"), usedFraction: 0, resetsAt: nil),
        ])
        XCTAssertTrue(snapshot.notes.contains { $0.contains(Loc.t("주간", "Weekly")) })
    }

    func testEmptyDirectoryIsNoRecentData() {
        guard case let .failure(error) = reader().read(now: now) else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .noRecentData)
    }
}
