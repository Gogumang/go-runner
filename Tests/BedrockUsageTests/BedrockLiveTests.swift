import GoRunnerCore
import XCTest
@testable import BedrockUsage

/// Real AWS call, only with `GORUNNER_LIVE=1`. Cost Explorer stays off (it bills $0.01 per request).
/// Prints a sanitized summary (no account ids or ARNs).
final class BedrockLiveTests: XCTestCase {
    func testLiveDefaultProfile() async throws {
        guard ProcessInfo.processInfo.environment["GORUNNER_LIVE"] == "1" else {
            throw XCTSkip("set GORUNNER_LIVE=1 to run the live AWS check")
        }
        var settings = QuotaSettings()
        settings.bedrockEnabled = true
        settings.awsProfile = "default"
        settings.awsRegion = "us-east-1"
        settings.bedrockCostExplorer = false

        let cache = try makeTempDirectory("gorunner-bedrock-live")
        defer { try? FileManager.default.removeItem(at: cache) }
        let started = Date()
        let report = await BedrockUsageProvider(cacheDirectory: cache).fetch(settings: settings)
        let elapsed = Date().timeIntervalSince(started)

        var lines = ["[LIVE] elapsed \(String(format: "%.1f", elapsed)) s"]
        if let error = report.error {
            lines.append("[LIVE] error kind=\(error.kind.rawValue) message=\(AWSErrorMapper.sanitize(error.message)) hint=\(AWSErrorMapper.sanitize(error.fixHint ?? "-"))")
        }
        for attempt in report.attempts {
            lines.append("[LIVE] attempt \(attempt.source) ok=\(attempt.succeeded) \(AWSErrorMapper.sanitize(attempt.message ?? ""))")
        }
        if let snapshot = report.snapshot {
            lines.append("[LIVE] plan=\(snapshot.planLabel ?? "-") source=\(snapshot.sourceName) windows=\(snapshot.windows.count) tokens=\(snapshot.tokens?.total ?? -1)")
            for window in snapshot.windows {
                lines.append("[LIVE] window \(window.label) fraction=\(window.usedFraction.map { String(format: "%.4f", $0) } ?? "nil") \(window.detail ?? "")")
            }
            for note in snapshot.notes { lines.append("[LIVE] note \(note)") }
        }
        print(lines.joined(separator: "\n"))

        XCTAssertLessThan(elapsed, 35)
        XCTAssertFalse(report.attempts.contains { $0.source.hasPrefix("Cost Explorer") })
        XCTAssertTrue(report.snapshot != nil || report.error != nil)
    }
}
