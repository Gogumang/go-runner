import Foundation
import GoRunnerCore
import XCTest
@testable import ClaudeUsage

final class OAuthUsageTests: XCTestCase {
    /// Before the fixture credential's expiry (1_789_200_000).
    let now = utcDate("2026-09-11T10:00:00Z")

    func testParsesUsageResponse() throws {
        let outcome = ClaudeOAuthUsageParser.parse(try Fixture.data("oauth-usage.json"), now: now)
        let result = try XCTUnwrap(outcome.result, "\(outcome)")
        // seven_day_sonnet is null; the "Opus" limits[] entry duplicates seven_day_opus and is skipped.
        XCTAssertEqual(result.windows.map(\.id), ["five_hour", "seven_day", "seven_day_opus", "seven_day_fable", "extra_usage"])
        XCTAssertEqual(result.windows[0].usedFraction ?? -1, 0.42, accuracy: 1e-9)
        XCTAssertEqual(result.windows[0].resetsAt, utcDate("2026-09-11T14:30:00Z"))
        XCTAssertEqual(result.windows[1].usedFraction ?? -1, 0.18, accuracy: 1e-9)
        XCTAssertEqual(result.windows[1].resetsAt, utcDate("2026-09-15T09:00:00Z"))
        XCTAssertEqual(result.windows[2].label, Loc.t("Opus 주간", "Opus weekly"))
        XCTAssertEqual(result.windows[2].usedFraction ?? -1, 0.30, accuracy: 1e-9)
        XCTAssertEqual(result.windows[3].label, Loc.t("Fable 주간", "Fable weekly"))
        XCTAssertEqual(result.windows[3].usedFraction ?? -1, 0.12, accuracy: 1e-9)
        let extra = result.windows[4]
        XCTAssertEqual(extra.usedFraction ?? -1, 0.2468, accuracy: 1e-9)
        XCTAssertEqual(extra.detail, "$12.34 / $50.00")
        XCTAssertNil(extra.resetsAt)
        XCTAssertEqual(result.dataAsOf, now)
    }

    func testUnexpectedResponseIsSchemaChanged() {
        XCTAssertEqual(ClaudeOAuthUsageParser.parse(Data(#"{"error":{"type":"x"}}"#.utf8), now: now).error?.kind, .schemaChanged)
        XCTAssertEqual(ClaudeOAuthUsageParser.parse(Data("<html>".utf8), now: now).error?.kind, .schemaChanged)
    }

    func testCredentialParsingAndExpiry() throws {
        let credential = try ClaudeOAuthCredential.parse(try Fixture.data("credentials.json")).get()
        XCTAssertEqual(credential.accessToken, "sk-ant-oat01-FAKE-TEST-TOKEN")
        XCTAssertEqual(credential.expiresAt, Date(timeIntervalSince1970: 1_789_200_000))
        XCTAssertEqual(credential.subscriptionType, "max")
        XCTAssertEqual(credential.planLabel, "Max 20x")
        XCTAssertFalse(credential.description.contains("FAKE"), "token must never appear in descriptions")
        XCTAssertFalse(credential.isExpired(now: Date(timeIntervalSince1970: 1_789_199_999)))
        XCTAssertTrue(credential.isExpired(now: Date(timeIntervalSince1970: 1_789_200_000)))

        XCTAssertEqual(ClaudeOAuthCredential.planLabel(subscriptionType: "max", rateLimitTier: nil), "Max")
        XCTAssertEqual(ClaudeOAuthCredential.planLabel(subscriptionType: "pro", rateLimitTier: "default_claude_ai"), "Pro")
        XCTAssertNil(ClaudeOAuthCredential.planLabel(subscriptionType: nil, rateLimitTier: nil))

        // Trailing newline from `security -w`.
        var withNewline = try Fixture.data("credentials.json")
        withNewline.append(0x0A)
        XCTAssertNoThrow(try ClaudeOAuthCredential.parse(withNewline).get())
    }

    func testCredentialWithoutClaudeAiOauth() throws {
        guard case .failure(let missing) = ClaudeOAuthCredential.parse(try Fixture.data("credentials-mcp-only.json")) else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(missing.kind, .authMissing)
        guard case .failure(let garbage) = ClaudeOAuthCredential.parse(Data("garbage".utf8)) else { return XCTFail("expected failure") }
        XCTAssertEqual(garbage.kind, .schemaChanged)
    }

    func testExpiredTokenIsNeverSent() async throws {
        let recorder = CallRecorder()
        let client = makeOAuthClient(credential: try Fixture.data("credentials.json"), body: try Fixture.data("oauth-usage.json"), recorder: recorder)
        let outcome = await client.fetchUsage(now: Date(timeIntervalSince1970: 1_789_300_000))
        XCTAssertEqual(outcome.error?.kind, .authExpired)
        XCTAssertEqual(outcome.error?.fixHint, Loc.t("Claude Code를 한 번 실행해 토큰을 갱신하세요", "Run Claude Code once to refresh the token"))
        XCTAssertEqual(recorder.count, 0)
    }

    func testRequestShapeAndSuccess() async throws {
        let recorder = CallRecorder()
        let client = makeOAuthClient(credential: try Fixture.data("credentials.json"), body: try Fixture.data("oauth-usage.json"), recorder: recorder)
        let outcome = await client.fetchUsage(now: now)
        let result = try XCTUnwrap(outcome.result, "\(outcome)")
        XCTAssertEqual(result.planLabel, "Max 20x")
        XCTAssertEqual(result.windows.count, 5)

        let request = try XCTUnwrap(recorder.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-FAKE-TEST-TOKEN")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GoRunner/9.9.9")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertNil(request.httpBody)
    }

    func testHTTPStatusMapping() async throws {
        let cases: [(Int, ProviderError.Kind)] = [(401, .authExpired), (403, .permissionDenied), (429, .rateLimited), (500, .network)]
        for (status, kind) in cases {
            let client = makeOAuthClient(credential: try Fixture.data("credentials.json"), status: status, recorder: CallRecorder())
            let outcome = await client.fetchUsage(now: now)
            XCTAssertEqual(outcome.error?.kind, kind, "HTTP \(status)")
        }
    }

    func testGateServesCacheForFiveMinutes() async throws {
        let gate = ClaudeOAuthGate()
        let recorder = CallRecorder()
        let client = makeOAuthClient(credential: try Fixture.data("credentials.json"), body: try Fixture.data("oauth-usage.json"), recorder: recorder)
        let start = now

        let first = await gate.fetch(now: start) { await client.fetchUsage(now: start) }
        XCTAssertNotNil(first.result)
        XCTAssertEqual(recorder.count, 1)

        let soon = start.addingTimeInterval(60)
        let cached = await gate.fetch(now: soon) { await client.fetchUsage(now: soon) }
        XCTAssertEqual(cached.result?.windows, first.result?.windows)
        XCTAssertEqual(recorder.count, 1, "served from cache")

        let later = start.addingTimeInterval(301)
        _ = await gate.fetch(now: later) { await client.fetchUsage(now: later) }
        XCTAssertEqual(recorder.count, 2)
    }

    func testGateSkipsForTenMinutesAfter429() async throws {
        let gate = ClaudeOAuthGate()
        let recorder = CallRecorder()
        let client = makeOAuthClient(credential: try Fixture.data("credentials.json"), status: 429, recorder: recorder)
        let start = now

        let first = await gate.fetch(now: start) { await client.fetchUsage(now: start) }
        XCTAssertEqual(first.error?.kind, .rateLimited)
        XCTAssertEqual(recorder.count, 1)

        let afterCache = start.addingTimeInterval(400) // past the 5-minute cache, inside the 10-minute cooldown
        let skipped = await gate.fetch(now: afterCache) { await client.fetchUsage(now: afterCache) }
        XCTAssertEqual(skipped.error?.kind, .rateLimited)
        XCTAssertEqual(recorder.count, 1)

        let afterCooldown = start.addingTimeInterval(601)
        _ = await gate.fetch(now: afterCooldown) { await client.fetchUsage(now: afterCooldown) }
        XCTAssertEqual(recorder.count, 2)
    }
}
