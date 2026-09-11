import Foundation
import GoRunnerCore
import XCTest
@testable import ClaudeUsage

final class StatuslineSourceTests: XCTestCase {
    /// `receivedAt` in the fixtures (2026-09-11T03:00:00Z); five_hour resets 3 h later, seven_day ~4.7 days later.
    let receivedAt = Date(timeIntervalSince1970: 1_789_095_600)
    let fiveHourReset = Date(timeIntervalSince1970: 1_789_106_400)
    let sevenDayReset = Date(timeIntervalSince1970: 1_789_500_000)

    func testNormalPayload() throws {
        let outcome = ClaudeStatuslineSource.parse(try Fixture.data("statusline-normal.json"), now: receivedAt.addingTimeInterval(120))
        let result = try XCTUnwrap(outcome.result, "\(outcome)")
        XCTAssertEqual(result.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(result.windows[0].label, Loc.t("5시간", "5-hour"))
        XCTAssertEqual(result.windows[0].usedFraction ?? -1, 0.235, accuracy: 1e-9)
        XCTAssertEqual(result.windows[0].resetsAt, fiveHourReset)
        XCTAssertEqual(result.windows[1].label, Loc.t("주간", "Weekly"))
        XCTAssertEqual(result.windows[1].usedFraction ?? -1, 0.412, accuracy: 1e-9)
        XCTAssertEqual(result.windows[1].resetsAt, sevenDayReset)
        XCTAssertEqual(result.dataAsOf, receivedAt)
        XCTAssertEqual(result.notes, [])
    }

    func testResetInPastZeroesWindowWithNote() throws {
        let now = fiveHourReset.addingTimeInterval(60)
        let result = try XCTUnwrap(ClaudeStatuslineSource.parse(try Fixture.data("statusline-normal.json"), now: now).result)
        XCTAssertEqual(result.windows[0].usedFraction, 0)
        XCTAssertNil(result.windows[0].resetsAt)
        XCTAssertEqual(result.windows[1].usedFraction ?? -1, 0.412, accuracy: 1e-9)
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertTrue(result.notes[0].contains(Loc.t("5시간", "5-hour")))
    }

    func testMissingRateLimitsIsFailure() throws {
        let outcome = ClaudeStatuslineSource.parse(try Fixture.data("statusline-no-rate-limits.json"), now: receivedAt)
        let error = try XCTUnwrap(outcome.error)
        XCTAssertEqual(error.kind, .other)
        XCTAssertTrue(error.message.contains("rate_limits"))
        XCTAssertTrue(error.message.contains("Bedrock"))
    }

    func testStaleDataStillReturnedWithNote() throws {
        let now = receivedAt.addingTimeInterval(7 * 3600)
        let result = try XCTUnwrap(ClaudeStatuslineSource.parse(try Fixture.data("statusline-normal.json"), now: now).result)
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows[1].usedFraction ?? -1, 0.412, accuracy: 1e-9)
        XCTAssertEqual(result.dataAsOf, receivedAt)
        XCTAssertTrue(result.notes.contains { $0.contains("Claude Code") }, "\(result.notes)")
    }

    func testMalformedFileIsSchemaChanged() {
        XCTAssertEqual(ClaudeStatuslineSource.parse(Data("not json".utf8), now: receivedAt).error?.kind, .schemaChanged)
    }

    func testMissingFileDependsOnHookInstallation() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("gorunner-missing-\(UUID().uuidString).json")
        XCTAssertEqual(ClaudeStatuslineSource.read(fileURL: missing, hookInstalled: false, now: receivedAt).error?.kind, .notConfigured)
        XCTAssertEqual(ClaudeStatuslineSource.read(fileURL: missing, hookInstalled: true, now: receivedAt).error?.kind, .noRecentData)
    }
}
