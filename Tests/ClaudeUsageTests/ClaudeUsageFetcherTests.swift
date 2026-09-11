import Foundation
import GoRunnerCore
import XCTest
@testable import ClaudeUsage

final class ClaudeUsageFetcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func environment(now: Date, projects: [URL], oauth: ClaudeOAuthClient? = nil,
                             timeout: TimeInterval = 27) -> ClaudeUsageEnvironment {
        ClaudeUsageEnvironment(installer: makeInstaller(root: root), projectsRoots: projects, logIndex: ClaudeLogIndex(),
                               oauthGate: ClaudeOAuthGate(),
                               oauthClient: oauth ?? makeOAuthClient(credential: nil, recorder: CallRecorder()),
                               now: { now }, sourceTimeout: timeout, calendar: utcCalendar)
    }

    private func writeStatusline(_ fixture: String) throws {
        let url = makeInstaller(root: root).statuslineFile
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Fixture.data(fixture).write(to: url)
    }

    private var missingProjects: URL { root.appendingPathComponent("no-such-projects") }

    func testDisabledProvider() async {
        var settings = QuotaSettings()
        settings.claudeEnabled = false
        let report = await ClaudeUsageProvider(environment: environment(now: Date(), projects: [missingProjects])).fetch(settings: settings)
        XCTAssertNil(report.snapshot)
        XCTAssertEqual(report.error?.kind, .notConfigured)
        XCTAssertEqual(report.error?.message, Loc.t("비활성화됨", "Disabled"))
        XCTAssertEqual(report.attempts, [])
    }

    func testMergesStatuslineOAuthAndLogs() async throws {
        try writeStatusline("statusline-normal.json")
        let now = Date(timeIntervalSince1970: 1_789_095_720) // 2 min after receivedAt
        let oauth = makeOAuthClient(credential: try Fixture.data("credentials.json"), body: try Fixture.data("oauth-usage.json"),
                                    recorder: CallRecorder())
        var settings = QuotaSettings()
        settings.claudeOAuthSource = true

        let report = await ClaudeUsageProvider(environment: environment(now: now, projects: [Fixture.url("projects")], oauth: oauth))
            .fetch(settings: settings)

        XCTAssertNil(report.error)
        let snapshot = try XCTUnwrap(report.snapshot)
        // statusline windows win; OAuth adds only ids statusline lacks.
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "seven_day_opus", "seven_day_fable", "extra_usage"])
        XCTAssertEqual(snapshot.windows[0].usedFraction ?? -1, 0.235, accuracy: 1e-9)
        XCTAssertEqual(snapshot.sourceName, ["statusline", "OAuth", Loc.t("로컬 로그", "local logs")].joined(separator: " + "))
        XCTAssertEqual(snapshot.trust, .official)
        XCTAssertEqual(snapshot.planLabel, "Max 20x")
        XCTAssertEqual(snapshot.dataAsOf, Date(timeIntervalSince1970: 1_789_095_600))
        XCTAssertEqual(snapshot.tokens?.total, 0, "no log entries on 2026-09-11 (UTC)")
        XCTAssertEqual(snapshot.spend.count, 2)
        XCTAssertEqual(snapshot.spend[1].amountUSD, 0.13505, accuracy: 1e-9)
        XCTAssertEqual(report.attempts.map(\.source), ["statusline", "oauth-usage", "local-logs"])
        XCTAssertEqual(report.attempts.map(\.trust), [.official, .undocumented, .heuristic])
        XCTAssertTrue(report.attempts.allSatisfy(\.succeeded))
    }

    func testNothingAvailableSuggestsInstallingHook() async {
        let report = await ClaudeUsageProvider(environment: environment(now: Date(), projects: [missingProjects])).fetch(settings: QuotaSettings())
        XCTAssertNil(report.snapshot)
        XCTAssertEqual(report.error?.kind, .notConfigured)
        XCTAssertEqual(report.error?.fixHint, Loc.t("설정 → AI 서비스에서 statusline 훅을 설치하세요", "Install the statusline hook in Settings → AI Services"))
        XCTAssertEqual(report.attempts.map(\.source), ["statusline", "local-logs"], "disabled OAuth is not attempted")
        XCTAssertFalse(report.attempts.contains(where: \.succeeded))
    }

    func testLogsOnlyFallback() async throws {
        let now = utcDate("2026-09-10T15:00:00Z")
        let report = await ClaudeUsageProvider(environment: environment(now: now, projects: [Fixture.url("projects")])).fetch(settings: QuotaSettings())
        let snapshot = try XCTUnwrap(report.snapshot)
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour_block"])
        XCTAssertEqual(snapshot.trust, .heuristic)
        XCTAssertEqual(snapshot.sourceName, Loc.t("로컬 로그", "local logs"))
        XCTAssertEqual(snapshot.tokens?.total, 20_820)
        XCTAssertEqual(snapshot.dataAsOf, utcDate("2026-09-10T14:30:00Z"))
        XCTAssertEqual(snapshot.notes.count, 2, "unpriced model + install-hook suggestion")
        XCTAssertEqual(report.attempts.map(\.succeeded), [false, true])
    }

    func testStatuslineWithoutRateLimitsFallsBackToLogs() async throws {
        try writeStatusline("statusline-no-rate-limits.json")
        let now = utcDate("2026-09-10T15:00:00Z")
        let report = await ClaudeUsageProvider(environment: environment(now: now, projects: [Fixture.url("projects")])).fetch(settings: QuotaSettings())
        XCTAssertEqual(report.snapshot?.trust, .heuristic)
        XCTAssertEqual(report.attempts.first?.succeeded, false)
        XCTAssertTrue(report.attempts.first?.message?.contains("rate_limits") ?? false)
    }

    func testExpiredOAuthIsReportedWhenNothingElseWorks() async throws {
        var settings = QuotaSettings()
        settings.claudeStatuslineSource = false
        settings.claudeLocalLogsSource = false
        settings.claudeOAuthSource = true
        let oauth = makeOAuthClient(credential: try Fixture.data("credentials.json"), recorder: CallRecorder())
        let report = await ClaudeUsageProvider(environment: environment(now: Date(timeIntervalSince1970: 1_789_300_000), projects: [], oauth: oauth))
            .fetch(settings: settings)
        XCTAssertEqual(report.error?.kind, .authExpired)
        XCTAssertEqual(report.error?.fixHint, Loc.t("Claude Code를 한 번 실행해 토큰을 갱신하세요", "Run Claude Code once to refresh the token"))
        XCTAssertEqual(report.attempts.map(\.source), ["oauth-usage"])
    }

    func testSlowSourceHitsDeadline() async throws {
        var settings = QuotaSettings()
        settings.claudeStatuslineSource = false
        settings.claudeLocalLogsSource = false
        settings.claudeOAuthSource = true
        let oauth = makeOAuthClient(credential: try Fixture.data("credentials.json"), body: try Fixture.data("oauth-usage.json"),
                                    recorder: CallRecorder(), delay: 5)
        let provider = ClaudeUsageProvider(environment: environment(now: utcDate("2026-09-11T10:00:00Z"), projects: [], oauth: oauth, timeout: 0.3))
        let start = Date()
        let report = await provider.fetch(settings: settings)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(report.error?.kind, .timeout)
        XCTAssertEqual(report.attempts.first?.succeeded, false)
    }

    func testDefaultProjectsRoots() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let roots = ClaudeUsageEnvironment.defaultProjectsRoots(environment: ["CLAUDE_CONFIG_DIR": "/tmp/cfg-a, /tmp/cfg-b"], home: home)
        XCTAssertEqual(roots.map(\.path), ["/tmp/cfg-a/projects", "/tmp/cfg-b/projects", "/Users/someone/.claude/projects",
                                           "/Users/someone/.config/claude/projects"])
    }
}
