import GoRunnerCore
import XCTest
@testable import BedrockUsage

/// Runs `BedrockUsageProvider.fetch` against a fake `aws` shell script that returns fixtures based on its arguments.
final class BedrockProviderEndToEndTests: XCTestCase {
    let now = Fixtures.iso("2026-09-11T03:10:30Z")
    let models = ["us.anthropic.claude-sonnet-4-5-20250929-v1:0", "amazon.nova-pro-v1:0", "meta.llama3-1-70b-instruct-v1:0"]
    var workDir: URL!
    var scriptURL: URL!
    var logURL: URL!
    var cacheDir: URL!

    override func setUpWithError() throws {
        workDir = try makeTempDirectory()
        cacheDir = workDir.appendingPathComponent("cache", isDirectory: true)
        logURL = workDir.appendingPathComponent("aws-calls", isDirectory: true)
        scriptURL = workDir.appendingPathComponent("aws")
        let fix = Fixtures.directory.path
        let script = """
        #!/bin/sh
        FIX='\(fix)'
        mkdir -p "$FAKE_LOG" && printf '%s PAGER=[%s]\\n' "$*" "${AWS_PAGER-unset}" > "$(mktemp "$FAKE_LOG/call.XXXXXX")"
        case "$*" in
          *"sts get-caller-identity"*)
            if [ "$FAKE_MODE" = "expired" ]; then
              echo "" >&2
              echo "An error occurred (ExpiredToken) when calling the GetCallerIdentity operation: The security token included in the request is expired" >&2
              exit 254
            fi
            echo '{"UserId":"AIDAEXAMPLE","Account":"111122223333","Arn":"arn:aws:iam::111122223333:user/test"}' ;;
          *"list-metrics"*"--recently-active"*)
            if [ "$FAKE_MODE" = "quiet" ]; then echo '{"Metrics":[]}'; else cat "$FIX/list-metrics.json"; fi ;;
          *"list-metrics"*)
            cat "$FIX/list-metrics.json" ;;
          *"get-metric-data"*)
            if [ "$FAKE_MODE" = "denied" ]; then
              echo "An error occurred (AccessDenied) when calling the GetMetricData operation: User: arn:aws:iam::111122223333:user/test is not authorized to perform: cloudwatch:GetMetricData" >&2
              exit 254
            fi
            case "$*" in
              *"--start-time 2026-09-11T00:00:00Z"*) cat "$FIX/get-metric-data-today.json" ;;
              *) cat "$FIX/get-metric-data-recent.json" ;;
            esac ;;
          *"list-service-quotas"*"--starting-token"*)
            cat "$FIX/list-service-quotas-page2.json" ;;
          *"list-service-quotas"*)
            cat "$FIX/list-service-quotas-page1.json" ;;
          *"ce get-cost-and-usage"*)
            cat "$FIX/get-cost-and-usage.json" ;;
          *)
            echo "unexpected: $*" >&2
            exit 2 ;;
        esac
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func provider(mode: String = "ok") -> BedrockUsageProvider {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let fixedNow = now
        return BedrockUsageProvider(cacheDirectory: cacheDir, now: { fixedNow }, calendar: utc,
                                    baseEnvironment: ["PATH": "/usr/bin:/bin", "FAKE_LOG": logURL.path, "FAKE_MODE": mode])
    }

    private func settings(cost: Bool = false, models: [String] = []) -> QuotaSettings {
        var s = QuotaSettings()
        s.bedrockEnabled = true
        s.awsProfile = "work"
        s.awsRegion = "us-west-2"
        s.bedrockCostExplorer = cost
        s.bedrockModelIDs = models
        s.awsExecutablePath = scriptURL.path
        return s
    }

    /// One file per fake `aws` call, so concurrent calls can't interleave their log lines.
    /// Files are read in creation order, so sequential calls keep their call order.
    private func logLines() -> [String] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: logURL, includingPropertiesForKeys: keys)) ?? [])
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast
                return l == r ? lhs.lastPathComponent < rhs.lastPathComponent : l < r
            }
        return files.flatMap { file in
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    func testHappyPathWithQuotasCostAndCaching() async throws {
        let report = await provider().fetch(settings: settings(cost: true))
        XCTAssertNil(report.error, "\(String(describing: report.error)) \(report.attempts)")
        let snapshot = try XCTUnwrap(report.snapshot)
        XCTAssertEqual(snapshot.windows.map(\.id), models.map { "tpm:\($0)" })
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[0].usedFraction), 0.175, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[1].usedFraction), 0.007, accuracy: 1e-9)
        XCTAssertNil(snapshot.windows[2].usedFraction)
        XCTAssertEqual(snapshot.tokens?.total, 736_000 + 7_000 + 1_500)
        XCTAssertEqual(snapshot.spend.count, 1)
        XCTAssertEqual(try XCTUnwrap(snapshot.spend.first).amountUSD, 42.8456, accuracy: 0.0001)
        XCTAssertEqual(snapshot.spend.first?.isEstimate, false)
        XCTAssertEqual(snapshot.sourceName, "CloudWatch + Service Quotas + Cost Explorer")
        XCTAssertEqual(snapshot.planLabel, "us-west-2 · work")
        XCTAssertEqual(snapshot.notes.count, 2, "\(snapshot.notes)") // throttles + Cost Explorer lag
        XCTAssertTrue(report.attempts.allSatisfy(\.succeeded), "\(report.attempts)")
        XCTAssertFalse(report.attempts.contains { ($0.message ?? "").contains("111122223333") })

        let lines = logLines()
        XCTAssertTrue(lines.allSatisfy { $0.contains("--profile work") && $0.contains("--output json") && $0.hasSuffix("PAGER=[]") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("sts get-caller-identity") })
        XCTAssertTrue(lines.contains { $0.contains("list-metrics") && $0.contains("--recently-active PT3H") && $0.contains("--region us-west-2") })
        XCTAssertEqual(lines.filter { $0.contains("get-metric-data") }.count, 2)
        XCTAssertTrue(lines.contains { $0.contains("--starting-token page-2-token") })
        let ce = try XCTUnwrap(lines.first { $0.contains("ce get-cost-and-usage") })
        XCTAssertTrue(ce.contains("--region us-east-1"))
        XCTAssertTrue(ce.contains("Start=2026-09-01,End=2026-09-12"))
        XCTAssertTrue(ce.contains("Type=DIMENSION,Key=SERVICE"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("bedrock-quotas-work-us-west-2.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("bedrock-cost-work.json").path))

        // Second refresh: quotas (24 h) and cost (6 h) come from the cache.
        let second = await provider().fetch(settings: settings(cost: true))
        XCTAssertNil(second.error)
        XCTAssertEqual(second.snapshot?.windows.count, 3)
        XCTAssertTrue(second.attempts.contains { $0.source == "Service Quotas (cache)" })
        XCTAssertTrue(second.attempts.contains { $0.source == "Cost Explorer (cache)" })
        let after = logLines()
        XCTAssertEqual(after.filter { $0.contains("list-service-quotas") }.count, 2)
        XCTAssertEqual(after.filter { $0.contains("ce get-cost-and-usage") }.count, 1)
    }

    func testExpiredCredentialsStopAfterIdentity() async {
        let report = await provider(mode: "expired").fetch(settings: settings(cost: true))
        XCTAssertNil(report.snapshot)
        XCTAssertEqual(report.error?.kind, .authExpired)
        XCTAssertTrue(report.error?.fixHint?.contains("aws sso login --profile work") == true)
        XCTAssertEqual(report.attempts.last?.source, "STS GetCallerIdentity")
        XCTAssertEqual(report.attempts.last?.succeeded, false)
        XCTAssertEqual(logLines().count, 1)
    }

    func testDisabledRunsNothing() async {
        var s = settings()
        s.bedrockEnabled = false
        let report = await provider().fetch(settings: s)
        XCTAssertEqual(report.error?.kind, .notConfigured)
        XCTAssertNil(report.snapshot)
        XCTAssertTrue(logLines().isEmpty)
    }

    func testMissingExecutable() async {
        var s = settings()
        s.awsExecutablePath = workDir.appendingPathComponent("does-not-exist").path
        let report = await provider().fetch(settings: s)
        XCTAssertEqual(report.error?.kind, .toolNotFound)
        XCTAssertEqual(report.attempts.first?.succeeded, false)
    }

    func testConfiguredModelsSkipDiscovery() async throws {
        let report = await provider().fetch(settings: settings(models: models))
        XCTAssertNil(report.error)
        XCTAssertEqual(report.snapshot?.windows.count, 3)
        XCTAssertFalse(logLines().contains { $0.contains("list-metrics") })
        XCTAssertFalse(logLines().contains { $0.contains("ce get-cost-and-usage") }, "Cost Explorer is off by default")
    }

    func testRecentlyActiveEmptyFallsBackToFullListAndCaches() async throws {
        let report = await provider(mode: "quiet").fetch(settings: settings())
        XCTAssertNil(report.error)
        XCTAssertEqual(report.snapshot?.windows.count, 3)
        let listCalls = logLines().filter { $0.contains("list-metrics") }
        XCTAssertEqual(listCalls.count, 2)
        XCTAssertFalse(listCalls[1].contains("--recently-active"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.appendingPathComponent("bedrock-models-work-us-west-2.json").path))

        let second = await provider(mode: "quiet").fetch(settings: settings())
        XCTAssertTrue(second.attempts.contains { $0.source == "CloudWatch ListMetrics (cache)" })
        XCTAssertEqual(logLines().filter { $0.contains("list-metrics") }.count, 3, "only the 3h probe runs again")
    }

    func testMetricAccessDenied() async {
        let report = await provider(mode: "denied").fetch(settings: settings())
        XCTAssertNil(report.snapshot)
        XCTAssertEqual(report.error?.kind, .permissionDenied)
        XCTAssertTrue(report.error?.message.contains("cloudwatch:GetMetricData") == true)
        XCTAssertFalse(report.error?.message.contains("111122223333") == true)
        XCTAssertTrue(report.attempts.contains { $0.source == "Service Quotas" && $0.succeeded })
    }
}
