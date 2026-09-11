import GoRunnerCore
import XCTest
@testable import BedrockUsage

final class BedrockUsageMathTests: XCTestCase {
    let now = Fixtures.iso("2026-09-11T03:10:30Z")

    private func p(_ time: String, _ value: Double) -> MetricPoint {
        MetricPoint(timestamp: Fixtures.iso("2026-09-11T\(time)Z"), value: value)
    }

    func testBurndownFormulaPerMinute() {
        let perMinute = BedrockUsageMath.quotaTokensPerMinute(
            input: [p("03:09:00", 10_000)], cacheWrite: [p("03:09:00", 2_000)], output: [p("03:09:00", 1_000)], burndown: 15)
        XCTAssertEqual(perMinute[Fixtures.iso("2026-09-11T03:09:00Z")], 10_000 + 2_000 + 15_000)
    }

    func testPeakIsMaxOverLastFiveMinutesOnly() {
        let model = "us.anthropic.claude-opus-4-8" // 15× burndown
        var data = BedrockMetricData()
        data.series[model] = [
            .inputTokens: [p("03:02:00", 900_000), p("03:05:00", 1_000), p("03:08:00", 4_000), p("03:10:00", 500)],
            .outputTokens: [p("03:02:00", 90_000), p("03:05:00", 2_000), p("03:08:00", 100)],
            .cacheReadTokens: [p("03:08:00", 1_000_000)],
        ]
        let peak = BedrockUsageMath.peakTPM(modelID: model, data: data, now: now)
        // 03:05 = 1,000 + 2,000×15 = 31,000 (window starts at 03:05); 03:02 is outside; cache reads never count.
        XCTAssertEqual(peak.value, 31_000)
        XCTAssertFalse(peak.fromEstimate)
    }

    func testEstimatedMetricWinsWhenPresent() {
        let model = "global.anthropic.claude-opus-5"
        var data = BedrockMetricData()
        data.series[model] = [
            .inputTokens: [p("03:09:00", 1_000_000)],
            .estimatedTPM: [p("03:01:00", 9_999_999), p("03:07:00", 42_000), p("03:09:00", 12_000)],
        ]
        let peak = BedrockUsageMath.peakTPM(modelID: model, data: data, now: now)
        XCTAssertEqual(peak.value, 42_000)
        XCTAssertTrue(peak.fromEstimate)
    }

    func testCompactFormatting() {
        XCTAssertEqual(BedrockUsageMath.compact(950), "950")
        XCTAssertEqual(BedrockUsageMath.compact(12_400), "12.4K")
        XCTAssertEqual(BedrockUsageMath.compact(200_000), "200K")
        XCTAssertEqual(BedrockUsageMath.compact(1_234_567), "1.2M")
    }

    func testSnapshotBuilderWithFixtures() throws {
        let models = ["us.anthropic.claude-sonnet-4-5-20250929-v1:0", "amazon.nova-pro-v1:0", "meta.llama3-1-70b-instruct-v1:0"]
        let recent = try BedrockParsing.parseMetricData(Fixtures.data("get-metric-data-recent.json"), models: models)
        let today = try BedrockParsing.parseMetricData(Fixtures.data("get-metric-data-today.json"), models: models)
        let quotas = try BedrockParsing.parseQuotas(Fixtures.data("list-service-quotas-page1.json"))
            + BedrockParsing.parseQuotas(Fixtures.data("list-service-quotas-page2.json"))
        let results = BedrockFetchResults(profile: "work", region: "us-west-2", models: models, recent: recent, today: today,
                                          quotas: quotas, monthToDateUSD: nil)
        let snapshot = BedrockSnapshotBuilder.build(results, now: now)

        XCTAssertEqual(snapshot.windows.map(\.id), models.map { "tpm:\($0)" })
        let sonnet = snapshot.windows[0]
        // Peak 03:07 = 20,000 + 0 + 3,000×5 = 35,000 of the 200K cross-region quota.
        XCTAssertEqual(try XCTUnwrap(sonnet.usedFraction), 0.175, accuracy: 1e-9)
        XCTAssertEqual(sonnet.label, "TPM · Sonnet 4.5 (us)")
        XCTAssertTrue(sonnet.detail?.contains("35K / 200K TPM") == true, sonnet.detail ?? "")
        XCTAssertTrue(sonnet.detail?.contains("7 / 200 RPM") == true, sonnet.detail ?? "")
        XCTAssertTrue(sonnet.detail?.contains("736K") == true, sonnet.detail ?? "")
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[1].usedFraction), 0.007, accuracy: 1e-9)
        XCTAssertNil(snapshot.windows[2].usedFraction, "no Llama quota → tokens only")
        XCTAssertTrue(snapshot.windows[2].detail?.contains("1.5K") == true)

        XCTAssertEqual(snapshot.tokens, TokenSummary(input: 636_200, output: 56_300, cacheCreation: 2_000, cacheRead: 50_000))
        XCTAssertEqual(snapshot.planLabel, "us-west-2 · work")
        XCTAssertEqual(snapshot.trust, .official)
        XCTAssertEqual(snapshot.sourceName, "CloudWatch + Service Quotas")
        XCTAssertTrue(snapshot.spend.isEmpty)
        XCTAssertEqual(snapshot.dataAsOf, Fixtures.iso("2026-09-11T03:09:00Z"))
        XCTAssertEqual(snapshot.notes.count, 1, "\(snapshot.notes)")
        XCTAssertTrue(snapshot.notes[0].contains("Sonnet 4.5 (us) 2"))
    }
}

final class AWSErrorMapperTests: XCTestCase {
    private func map(_ stderr: String, permission: String? = nil) -> ProviderError {
        AWSErrorMapper.map(stderr: stderr, exitCode: 254, profile: "work", permission: permission)
    }

    func testExpiredTokens() {
        let sts = map("\nAn error occurred (ExpiredToken) when calling the GetCallerIdentity operation: The security token included in the request is expired\n")
        XCTAssertEqual(sts.kind, .authExpired)
        XCTAssertTrue(sts.fixHint?.contains("aws sso login --profile work") == true)
        XCTAssertEqual(map("Error when retrieving token from sso: Token has expired and refresh failed").kind, .authExpired)
        XCTAssertEqual(map("The SSO session associated with this profile has expired or is otherwise invalid. To refresh this SSO session run aws sso login with the corresponding profile.").kind, .authExpired)
    }

    func testMissingCredentials() {
        let missing = map("\nUnable to locate credentials. You can configure credentials by running \"aws configure\".\n")
        XCTAssertEqual(missing.kind, .authMissing)
        XCTAssertTrue(missing.fixHint?.contains("aws configure --profile work") == true)
        XCTAssertEqual(map("\nThe config profile (work) could not be found\n").kind, .authMissing)
        XCTAssertEqual(map("An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.").kind, .authMissing)
    }

    func testAccessDeniedNamesPermissionAndHidesAccount() {
        let denied = map("\nAn error occurred (AccessDenied) when calling the GetMetricData operation: User: arn:aws:iam::111122223333:user/dev is not authorized to perform: cloudwatch:GetMetricData because no identity-based policy allows the cloudwatch:GetMetricData action\n",
                         permission: "cloudwatch:GetMetricData")
        XCTAssertEqual(denied.kind, .permissionDenied)
        XCTAssertTrue(denied.message.contains("cloudwatch:GetMetricData"))
        XCTAssertFalse(denied.message.contains("111122223333"))
        XCTAssertFalse((denied.fixHint ?? "").contains("arn:"))

        let quotas = map("An error occurred (AccessDeniedException) when calling the ListServiceQuotas operation: Access denied",
                         permission: "servicequotas:ListServiceQuotas")
        XCTAssertEqual(quotas.kind, .permissionDenied)
        XCTAssertTrue(quotas.message.contains("servicequotas:ListServiceQuotas"))
    }

    func testNetworkThrottleAndOther() {
        XCTAssertEqual(map("\nCould not connect to the endpoint URL: \"https://monitoring.us-east-1.amazonaws.com/\"\n").kind, .network)
        XCTAssertEqual(map("An error occurred (Throttling) when calling the GetMetricData operation (reached max retries: 2): Rate exceeded").kind, .rateLimited)
        XCTAssertEqual(map("aws: error: argument --recently-active: Invalid choice, valid choices are: PT3H").kind, .schemaChanged)
        let other = map("Something odd for account 111122223333 at arn:aws:iam::111122223333:role/x")
        XCTAssertEqual(other.kind, .other)
        XCTAssertFalse(other.message.contains("111122223333"))
        XCTAssertEqual(AWSErrorMapper.toolNotFound().kind, .toolNotFound)
    }

    func testSanitize() {
        XCTAssertEqual(AWSErrorMapper.sanitize("key AKIAABCDEFGHIJKLMNOP acct 111122223333"), "key <key> acct <account>")
    }
}
