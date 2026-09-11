import Foundation
import GoRunnerCore
import XCTest
@testable import ClaudeUsage

/// Read-only check against this Mac's real ~/.claude data: `GORUNNER_LIVE=1 swift test --filter ClaudeLiveTests`.
/// OAuth stays off (no Keychain, no network) and nothing is installed into ~/.claude/settings.json.
final class ClaudeLiveTests: XCTestCase {
    private struct Printable: Encodable {
        var coldSeconds: Double
        var warmSeconds: Double
        var snapshot: QuotaSnapshot?
        var error: ProviderError?
        var attempts: [SourceAttempt]
    }

    func testLiveReadOnlySnapshot() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GORUNNER_LIVE"] == "1", "set GORUNNER_LIVE=1 to read this Mac's ~/.claude logs")
        var settings = QuotaSettings()
        settings.claudeOAuthSource = false
        let settingsURL = ClaudeStatuslineInstaller.standard.claudeSettingsURL
        let settingsBefore = try? Data(contentsOf: settingsURL)

        let provider = ClaudeUsageProvider()
        let coldStart = Date()
        let report = await provider.fetch(settings: settings)
        let cold = Date().timeIntervalSince(coldStart)
        let warmStart = Date()
        _ = await provider.fetch(settings: settings)
        let warm = Date().timeIntervalSince(warmStart)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(Printable(coldSeconds: cold, warmSeconds: warm, snapshot: report.snapshot,
                                                error: report.error, attempts: report.attempts))
        print("=== GORUNNER_LIVE Claude report ===\n" + String(decoding: json, as: UTF8.self))

        XCTAssertLessThan(cold, 30)
        XCTAssertFalse(report.attempts.contains { $0.source == "oauth-usage" })
        XCTAssertEqual(try? Data(contentsOf: settingsURL), settingsBefore, "~/.claude/settings.json must be untouched")
    }
}
