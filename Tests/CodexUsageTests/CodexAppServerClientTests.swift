import Foundation
import GoRunnerCore
import XCTest
@testable import CodexUsage

/// Runs `CodexAppServerClient` against tiny `/bin/sh` fake servers that speak newline-delimited JSON-RPC.
final class CodexAppServerClientTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp.remove()
    }

    private func client(_ path: String, timeout: TimeInterval = 10) -> CodexAppServerClient {
        CodexAppServerClient(executableOverride: path, timeout: timeout, environment: ProcessInfo.processInfo.environment)
    }

    /// Answers initialize, holds account/read until rate limits were answered (out-of-order ids),
    /// and mixes in a notification and a non-JSON line. The rate-limit result is the real captured line.
    private func fakeServer(account: String, rateLimitsLine: String) -> String {
        #"""
        #!/bin/sh
        [ "$1" = "app-server" ] || { echo "unexpected args: $*" >&2; exit 2; }
        ACCOUNT_ID=""
        while IFS= read -r line; do
          id=$(printf '%s\n' "$line" | sed -n 's/^.*"id":\([0-9][0-9]*\).*$/\1/p')
          case "$line" in
            *'"method":"initialize"'*)
              printf '%s\n' "{\"id\":$id,\"result\":{\"userAgent\":\"fake/0.153.0\",\"platformOs\":\"macos\"}}" ;;
            *'"method":"initialized"'*) ;;
            *'"method":"account/read"'*) ACCOUNT_ID=$id ;;
            *'"method":"account/rateLimits/read"'*)
              printf '%s\n' '{"method":"remoteControl/status/changed","params":{"status":"disabled"}}'
              printf '%s\n' 'this line is not json'
              RATE_LIMITS_LINE
              printf '%s\n' "{\"id\":$ACCOUNT_ID,\"result\":ACCOUNT_JSON}" ;;
          esac
        done
        """#
        .replacingOccurrences(of: "RATE_LIMITS_LINE", with: rateLimitsLine)
        .replacingOccurrences(of: "ACCOUNT_JSON", with: account.replacingOccurrences(of: "\"", with: "\\\""))
    }

    func testHappyPathAgainstFakeServer() async throws {
        let fixture = Fixtures.url("app-server-live.jsonl").path
        let script = try temp.script("codex", fakeServer(
            account: #"{"account":{"type":"chatgpt","email":"user@example.com","planType":"plus"},"requiresOpenaiAuth":true}"#,
            rateLimitsLine: #"sed -n 4p '\#(fixture)' | sed "s/^{\"id\":3,/{\"id\":$id,/""#))

        let result = await client(script).fetch()
        let value = try result.get()
        XCTAssertEqual(value.account, CodexAccountInfo(kind: .chatgpt, planType: "plus", requiresOpenAIAuth: true))
        XCTAssertEqual(value.rateLimits.main.primary?.usedPercent, 5)
        XCTAssertEqual(value.rateLimits.main.secondary?.windowMinutes, 10_080)

        let snapshot = CodexSnapshotBuilder.appServerSnapshot(value, now: Date(timeIntervalSince1970: 1_789_091_000))
        XCTAssertEqual(snapshot.planLabel, "Plus")
        XCTAssertEqual(snapshot.trust, .openInterface)
        XCTAssertEqual(snapshot.windows, [
            QuotaWindow(id: "primary", label: Loc.t("5시간", "5-hour"), usedFraction: 0.05, resetsAt: Date(timeIntervalSince1970: 1_789_108_699)),
            QuotaWindow(id: "secondary", label: Loc.t("주간", "Weekly"), usedFraction: 0.03, resetsAt: Date(timeIntervalSince1970: 1_789_484_651)),
        ])
    }

    func testNotLoggedInMapsToAuthMissing() async throws {
        let fixture = Fixtures.url("app-server-not-logged-in.jsonl").path
        let script = try temp.script("codex", fakeServer(
            account: #"{"account":null,"requiresOpenaiAuth":true}"#,
            rateLimitsLine: #"sed -n 3p '\#(fixture)' | sed "s/\"id\":3}/\"id\":$id}/""#))

        let result = await client(script).fetch()
        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .authMissing)
        XCTAssertTrue(error.fixHint?.contains("codex login") == true)
    }

    func testUnexpectedShapeMapsToSchemaChanged() async throws {
        let script = try temp.script("codex", fakeServer(
            account: #"{"account":{"type":"chatgpt","planType":"plus"},"requiresOpenaiAuth":true}"#,
            rateLimitsLine: #"printf '%s\n' "{\"id\":$id,\"result\":{\"limits\":[]}}""#))

        let result = await client(script).fetch()
        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .schemaChanged)
    }

    func testMissingExecutableMapsToToolNotFound() async {
        let result = await client(temp.url.appendingPathComponent("nope/codex").path).fetch()
        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .toolNotFound)
        XCTAssertEqual(error.fixHint, Loc.t("Codex CLI를 설치하거나 설정에서 경로를 지정하세요", "Install Codex CLI or set its path in Settings"))
    }

    func testServerThatExitsEarlyFailsFast() async throws {
        let script = try temp.script("codex", "#!/bin/sh\necho 'boom: cannot start' >&2\nexit 3\n")
        let started = Date()
        let result = await client(script, timeout: 10).fetch()
        guard case let .failure(error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.kind, .other)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "EOF must end the wait, not the timeout")
    }

    func testTimeoutTerminatesSilentServer() async throws {
        let pidFile = temp.url.appendingPathComponent("pid")
        let script = try temp.script("codex", "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 60\n")

        let started = Date()
        let result = await client(script, timeout: 1).fetch()
        let elapsed = Date().timeIntervalSince(started)
        guard case let .failure(error) = result else { return XCTFail("expected timeout") }
        XCTAssertEqual(error.kind, .timeout)
        XCTAssertLessThan(elapsed, 4)

        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(waitForProcessExit(pid: pid, timeout: 3), "fake server \(pid) still running")
    }

    func testTimeoutKillsServerThatIgnoresSIGTERM() async throws {
        let pidFile = temp.url.appendingPathComponent("pid")
        let script = try temp.script("codex", "#!/bin/sh\ntrap '' TERM\necho $$ > '\(pidFile.path)'\nwhile :; do sleep 1; done\n")

        let result = await client(script, timeout: 1).fetch()
        guard case let .failure(error) = result else { return XCTFail("expected timeout") }
        XCTAssertEqual(error.kind, .timeout)

        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(waitForProcessExit(pid: pid, timeout: ChildProcessTeardown.killGrace + 3), "SIGKILL escalation failed for \(pid)")
    }
}
