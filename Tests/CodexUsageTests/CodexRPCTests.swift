import Foundation
import GoRunnerCore
import XCTest
@testable import CodexUsage

final class CodexRPCTests: XCTestCase {
    // MARK: Framing

    func testRequestIsOneLineWithoutJSONRPCField() throws {
        let data = CodexRPC.request(id: 1, method: CodexRPC.initialize,
                                    params: CodexRPC.initializeParams(clientName: "gorunner", clientVersion: "0.1.0"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(text, #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"gorunner","title":"go-runner","version":"0.1.0"}}}"# + "\n")
        XCTAssertFalse(text.contains("jsonrpc"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
    }

    func testRateLimitsRequestHasNoParamsAndNotificationHasNoID() {
        XCTAssertEqual(String(decoding: CodexRPC.request(id: 3, method: CodexRPC.rateLimitsRead), as: UTF8.self),
                       #"{"id":3,"method":"account/rateLimits/read"}"# + "\n")
        XCTAssertEqual(String(decoding: CodexRPC.request(id: 2, method: CodexRPC.accountRead, params: [:]), as: UTF8.self),
                       #"{"id":2,"method":"account/read","params":{}}"# + "\n")
        XCTAssertEqual(String(decoding: CodexRPC.notification(method: CodexRPC.initialized), as: UTF8.self),
                       #"{"method":"initialized"}"# + "\n")
    }

    func testNewlinesInsideStringsStayEscaped() {
        let data = CodexRPC.request(id: 9, method: "x", params: ["text": "a\nb"])
        XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1)
        XCTAssertEqual(data.last, 0x0A)
    }

    func testLineBufferSplitsAcrossChunksAndStripsCR() {
        var buffer = LineBuffer()
        var result = buffer.append(Data(#"{"id":1,"res"#.utf8))
        XCTAssertTrue(result.lines.isEmpty)
        result = buffer.append(Data("ult\":{}}\r\n\n{\"method\":\"x\"}\n{\"id\":".utf8))
        XCTAssertEqual(result.lines.map { String(decoding: $0, as: UTF8.self) }, [#"{"id":1,"result":{}}"#, #"{"method":"x"}"#])
        result = buffer.append(Data("2,\"result\":{}}\n".utf8))
        XCTAssertEqual(result.lines.map { String(decoding: $0, as: UTF8.self) }, [#"{"id":2,"result":{}}"#])
        XCTAssertFalse(result.overflow)
    }

    func testLineBufferOverflow() {
        var buffer = LineBuffer(maxLineBytes: 8)
        let result = buffer.append(Data("0123456789".utf8))
        XCTAssertTrue(result.overflow)
        XCTAssertEqual(buffer.append(Data("ok\n".utf8)).lines, [Data("ok".utf8)])
    }

    // MARK: Captured app-server output (codex-cli 0.153.0, scrubbed)

    func testDecodeLiveCapture() throws {
        let lines = try Fixtures.lines("app-server-live.jsonl")
        XCTAssertEqual(lines.count, 4)

        guard case let .response(id1, initResult) = CodexRPC.decode(lines[0]) else { return XCTFail("initialize response") }
        XCTAssertEqual(id1, 1)
        XCTAssertNotNil(initResult.value["userAgent"] as? String)

        guard case let .notification(method) = CodexRPC.decode(lines[1]) else { return XCTFail("notification") }
        XCTAssertEqual(method, "remoteControl/status/changed")

        guard case let .response(id2, accountResult) = CodexRPC.decode(lines[2]) else { return XCTFail("account response") }
        XCTAssertEqual(id2, 2)
        let account = try CodexResponseParser.account(fromResult: accountResult.value)
        XCTAssertEqual(account, CodexAccountInfo(kind: .chatgpt, planType: "plus", requiresOpenAIAuth: true))

        guard case let .response(id3, limitsResult) = CodexRPC.decode(lines[3]) else { return XCTFail("rate limits response") }
        XCTAssertEqual(id3, 3)
        let limits = try CodexResponseParser.rateLimits(fromResult: limitsResult.value)
        XCTAssertEqual(limits.main.limitID, "codex")
        XCTAssertEqual(limits.main.planType, "plus")
        XCTAssertEqual(limits.main.primary, CodexRateLimitWindow(usedPercent: 5, windowMinutes: 300,
                                                                 resetsAt: Date(timeIntervalSince1970: 1_789_108_699)))
        XCTAssertEqual(limits.main.secondary, CodexRateLimitWindow(usedPercent: 3, windowMinutes: 10_080,
                                                                   resetsAt: Date(timeIntervalSince1970: 1_789_484_651)))
        XCTAssertEqual(limits.additional, [], "the codex bucket in rateLimitsByLimitId is not duplicated")
    }

    func testDecodeNotLoggedInCapture() throws {
        let lines = try Fixtures.lines("app-server-not-logged-in.jsonl")
        guard case let .error(id, code, message) = CodexRPC.decode(lines[2]) else { return XCTFail("error line") }
        XCTAssertEqual(id, 3)
        XCTAssertEqual(code, -32600)
        let error = CodexErrors.rpcError(code: code, message: message, method: CodexRPC.rateLimitsRead)
        XCTAssertEqual(error.kind, .authMissing)
        XCTAssertTrue(error.fixHint?.contains("codex login") == true)

        guard case let .response(_, result) = CodexRPC.decode(lines[3]) else { return XCTFail("account line") }
        let account = try CodexResponseParser.account(fromResult: result.value)
        XCTAssertNil(account.kind)
        XCTAssertEqual(CodexErrors.accountProblem(account)?.kind, .authMissing)
    }

    func testDecodeIgnoresGarbage() {
        guard case .unparseable = CodexRPC.decode(Data("not json".utf8)) else { return XCTFail() }
        guard case .unparseable = CodexRPC.decode(Data("[1,2]".utf8)) else { return XCTFail() }
        guard case let .serverRequest(id, method) = CodexRPC.decode(Data(#"{"id":"7","method":"item/approve"}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(id, 7)
        XCTAssertEqual(method, "item/approve")
    }

    func testRateLimitsSchemaChanges() {
        XCTAssertThrowsError(try CodexResponseParser.rateLimits(fromResult: ["unexpected": true])) { error in
            XCTAssertEqual((error as? ProviderError)?.kind, .schemaChanged)
        }
        XCTAssertThrowsError(try CodexResponseParser.rateLimits(fromResult: ["rateLimits": ["primary": ["windowDurationMins": 300]]])) { error in
            XCTAssertEqual((error as? ProviderError)?.kind, .schemaChanged)
        }
    }

    func testAdditionalBucketsAndDateFormats() throws {
        let result: [String: Any] = [
            "rateLimits": ["limitId": "codex", "primary": ["usedPercent": 10, "windowDurationMins": 300, "resetsAt": "2026-09-11T04:00:00Z"],
                           "secondary": NSNull(), "planType": "pro"],
            "rateLimitsByLimitId": [
                "codex": ["limitId": "codex", "primary": ["usedPercent": 10, "windowDurationMins": 300]],
                "gpt-luna": ["limitName": "Luna", "primary": ["usedPercent": 50, "windowDurationMins": 10_080, "resetsAt": 1_789_484_651_000]],
            ],
        ]
        let limits = try CodexResponseParser.rateLimits(fromResult: result)
        XCTAssertEqual(limits.main.primary?.resetsAt, UTC.date("2026-09-11T04:00:00Z"))
        XCTAssertNil(limits.main.secondary)
        XCTAssertEqual(limits.additional.count, 1)
        XCTAssertEqual(limits.additional[0].limitID, "gpt-luna")
        XCTAssertEqual(limits.additional[0].primary?.resetsAt, Date(timeIntervalSince1970: 1_789_484_651), "milliseconds accepted")

        let (windows, _) = CodexSnapshotBuilder.quotaWindows(for: limits, now: UTC.date("2026-09-11T03:00:00Z"), zeroPastResets: false)
        XCTAssertEqual(windows.map(\.id), ["primary", "gpt-luna.primary"])
        XCTAssertEqual(windows[1].label, "Luna · " + Loc.t("주간", "Weekly"))
        XCTAssertEqual(windows[1].usedFraction, 0.5)
    }

    func testErrorMapping() {
        XCTAssertEqual(CodexErrors.rpcError(code: -32600, message: "chatgpt authentication required to read rate limits", method: "m").kind, .authMissing)
        XCTAssertEqual(CodexErrors.rpcError(code: -32601, message: "Method not found", method: "m").kind, .schemaChanged)
        XCTAssertEqual(CodexErrors.rpcError(code: -32600, message: "Invalid request: invalid type: map, expected unit", method: "m").kind, .schemaChanged)
        XCTAssertEqual(CodexErrors.rpcError(code: -32603, message: "failed to fetch codex rate limits: error sending request", method: "m").kind, .network)
        XCTAssertEqual(CodexErrors.accountProblem(CodexAccountInfo(kind: .apiKey, planType: nil, requiresOpenAIAuth: true))?.kind, .authMissing)
        XCTAssertNil(CodexErrors.accountProblem(CodexAccountInfo(kind: .chatgpt, planType: "plus", requiresOpenAIAuth: true)))
    }
}
