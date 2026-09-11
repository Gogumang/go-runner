import Foundation
import GoRunnerCore
import XCTest
@testable import CodexUsage

final class CodexProviderTests: XCTestCase {
    private var temp: TempDirectory!
    private let now = UTC.date("2026-09-11T03:00:00Z")

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp.remove()
    }

    // MARK: Window labels

    func testWindowLabels() {
        XCTAssertEqual(CodexWindowLabel.label(minutes: 300), Loc.t("5시간", "5-hour"))
        XCTAssertEqual(CodexWindowLabel.label(minutes: 10_080), Loc.t("주간", "Weekly"))
        XCTAssertEqual(CodexWindowLabel.label(minutes: 60), Loc.t("1시간", "1-hour"))
        XCTAssertEqual(CodexWindowLabel.label(minutes: 1440), Loc.t("24시간", "24-hour"))
        XCTAssertEqual(CodexWindowLabel.label(minutes: 90), Loc.t("90분", "90-min"))
        XCTAssertEqual(CodexWindowLabel.label(minutes: 45), Loc.t("45분", "45-min"))
        XCTAssertEqual(CodexWindowLabel.label(minutes: nil), Loc.t("한도", "Limit"))
        XCTAssertEqual(CodexWindowLabel.label(minutes: 0), Loc.t("한도", "Limit"))
    }

    func testPlanLabels() {
        XCTAssertEqual(CodexSnapshotBuilder.planLabel("plus"), "Plus")
        XCTAssertEqual(CodexSnapshotBuilder.planLabel("pro"), "Pro")
        XCTAssertEqual(CodexSnapshotBuilder.planLabel("team"), "Team")
        XCTAssertEqual(CodexSnapshotBuilder.planLabel("prolite"), "Pro Lite")
        XCTAssertEqual(CodexSnapshotBuilder.planLabel("self_serve_business_usage_based"), "Self Serve Business Usage Based")
        XCTAssertNil(CodexSnapshotBuilder.planLabel("unknown"))
        XCTAssertNil(CodexSnapshotBuilder.planLabel(""))
        XCTAssertNil(CodexSnapshotBuilder.planLabel(nil))
    }

    // MARK: Provider

    private func provider(codexPath: String, sessionsRoot: URL) -> CodexUsageProvider {
        var reader = CodexSessionLogReader(sessionsRoot: sessionsRoot)
        reader.calendar = UTC.calendar
        return CodexUsageProvider(
            appServerClient: { _ in
                CodexAppServerClient(executableOverride: codexPath, timeout: 5, environment: ProcessInfo.processInfo.environment)
            },
            sessionLogReader: reader,
            now: { [now] in now })
    }

    private func placeFixtureSession() throws -> URL {
        let root = temp.url.appendingPathComponent("sessions")
        let dir = root.appendingPathComponent("2026/09/11", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout.jsonl")
        try Data(contentsOf: Fixtures.url("session-rollout.jsonl")).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: file.path)
        return root
    }

    func testDisabledIsNotConfigured() async {
        var settings = QuotaSettings()
        settings.codexEnabled = false
        let report = await CodexUsageProvider().fetch(settings: settings)
        XCTAssertEqual(report.provider, .codex)
        XCTAssertNil(report.snapshot)
        XCTAssertEqual(report.error?.kind, .notConfigured)
        XCTAssertEqual(report.attempts, [])
    }

    func testFallsBackToSessionLogsWhenAppServerMissing() async throws {
        let root = try placeFixtureSession()
        let report = await provider(codexPath: temp.url.appendingPathComponent("missing/codex").path, sessionsRoot: root)
            .fetch(settings: QuotaSettings())

        XCTAssertNil(report.error)
        XCTAssertEqual(report.attempts.map(\.source), [CodexSnapshotBuilder.appServerSourceName, CodexSnapshotBuilder.sessionLogsSourceName])
        XCTAssertEqual(report.attempts.map(\.succeeded), [false, true])
        let snapshot = try XCTUnwrap(report.snapshot)
        XCTAssertEqual(snapshot.trust, .heuristic)
        XCTAssertEqual(snapshot.dataAsOf, UTC.date("2026-09-11T01:00:00Z"))
        XCTAssertEqual(snapshot.windows.map(\.usedFraction), [0.125, 0])
        XCTAssertEqual(snapshot.tokens?.total, 4400)
        XCTAssertTrue(snapshot.notes.contains { $0.hasPrefix(Loc.t("app-server 사용 불가", "app-server unavailable")) })
    }

    /// App-server has limit windows, so the session logs are not read at all (battery: no log scan per refresh).
    func testPrefersAppServerWithoutReadingSessionLogs() async throws {
        let root = try placeFixtureSession()
        let fixture = Fixtures.url("app-server-live.jsonl").path
        let script = try temp.script("codex", #"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) sed -n 1p '\#(fixture)' ;;
            *'"method":"account/read"'*) sed -n 3p '\#(fixture)' ;;
            *'"method":"account/rateLimits/read"'*) sed -n 4p '\#(fixture)' ;;
          esac
        done
        """#)
        let report = await provider(codexPath: script, sessionsRoot: root).fetch(settings: QuotaSettings())

        XCTAssertNil(report.error)
        XCTAssertEqual(report.attempts.map(\.source), [CodexSnapshotBuilder.appServerSourceName])
        XCTAssertEqual(report.attempts.map(\.succeeded), [true])
        let snapshot = try XCTUnwrap(report.snapshot)
        XCTAssertEqual(snapshot.trust, .openInterface)
        XCTAssertEqual(snapshot.sourceName, "codex app-server")
        XCTAssertEqual(snapshot.planLabel, "Plus")
        XCTAssertEqual(snapshot.windows.map(\.usedFraction), [0.05, 0.03])
        XCTAssertNil(snapshot.tokens)
    }

    func testBothSourcesFailingReturnsAppServerError() async {
        let report = await provider(codexPath: temp.url.appendingPathComponent("missing/codex").path,
                                    sessionsRoot: temp.url.appendingPathComponent("nothing"))
            .fetch(settings: QuotaSettings())
        XCTAssertNil(report.snapshot)
        XCTAssertEqual(report.error?.kind, .toolNotFound)
        XCTAssertEqual(report.attempts.count, 2)
    }

    func testOnlySessionLogsEnabled() async throws {
        let root = try placeFixtureSession()
        var settings = QuotaSettings()
        settings.codexAppServerSource = false
        let report = await provider(codexPath: "/definitely/not/used", sessionsRoot: root).fetch(settings: settings)
        XCTAssertEqual(report.attempts.map(\.source), [CodexSnapshotBuilder.sessionLogsSourceName])
        XCTAssertEqual(report.snapshot?.trust, .heuristic)
    }

    // MARK: Live (read-only)

    /// `GORUNNER_LIVE=1 swift test --filter CodexUsageTests.CodexProviderTests/testLiveFetch`
    /// Uses the real codex CLI: `initialize`, `account/read`, `account/rateLimits/read` only — never starts a turn.
    func testLiveFetch() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GORUNNER_LIVE"] == "1", "set GORUNNER_LIVE=1")
        let started = Date()
        let report = await CodexUsageProvider().fetch(settings: QuotaSettings())
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 30)

        var lines = ["=== Codex live report (\(String(format: "%.1f", elapsed)) s) ==="]
        if let s = report.snapshot {
            lines.append("source: \(s.sourceName) · trust: \(s.trust) · plan: \(s.planLabel ?? "-")")
            lines.append("fetchedAt: \(s.fetchedAt) · dataAsOf: \(s.dataAsOf.map { "\($0)" } ?? "-")")
            for w in s.windows {
                lines.append("  [\(w.id)] \(w.label): \(w.usedFraction.map { MetricFormat.percent($0) } ?? "-") · resets \(w.resetsAt.map { "\($0) (\(MetricFormat.resetDescription($0)))" } ?? "-")")
            }
            if let t = s.tokens {
                lines.append("  today tokens: total \(t.total) (input \(t.input), cacheRead \(t.cacheRead), cacheWrite \(t.cacheCreation), output \(t.output))")
            }
            for note in s.notes { lines.append("  note: \(note)") }
        }
        if let e = report.error { lines.append("error: \(e.kind) — \(e.message) — hint: \(e.fixHint ?? "-")") }
        for a in report.attempts {
            lines.append("attempt: \(a.source) [\(a.trust)] \(a.succeeded ? "ok" : "failed") — \(a.message ?? "")")
        }
        print(lines.joined(separator: "\n"))
    }
}
