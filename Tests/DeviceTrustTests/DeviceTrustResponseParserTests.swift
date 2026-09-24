import Foundation
import Testing
@testable import DeviceTrust

struct DeviceTrustResponseParserTests {
    @Test("세션 201 응답에서 handoffCode를 읽는다") func parsesSessionResponse() throws {
        let body = Data(#"{"handoffCode":"q1w2e3_r4-T5","expiresInSeconds":60}"#.utf8)
        let handoff = try DeviceTrustResponseParser.parseSession(status: 201, body: body)
        #expect(handoff == DeviceSessionHandoff(handoffCode: "q1w2e3_r4-T5", expiresInSeconds: 60))
    }

    @Test("handoffCode가 없거나 JSON이 아니면 형식 오류", arguments: [#"{"expiresInSeconds":60}"#, #"{"handoffCode":""}"#, "<html>ok</html>", ""])
    func malformedSessionBody(body: String) {
        #expect(throws: DeviceTrustError.malformedResponse) {
            try DeviceTrustResponseParser.parseSession(status: 201, body: Data(body.utf8))
        }
    }

    @Test("collector 오류 코드를 타입으로 매핑한다", arguments: [
        ("unauthorized", CollectorErrorCode.unauthorized),
        ("caller_not_allowed", .callerNotAllowed),
        ("invalid_device_proof", .invalidDeviceProof),
        ("device_not_registered", .deviceNotRegistered),
        ("device_session_required", .deviceSessionRequired),
        ("invalid_handoff", .invalidHandoff),
        ("something_new", .other("something_new")),
    ])
    func mapsCollectorErrorCodes(raw: String, expected: CollectorErrorCode) {
        let body = Data(#"{"error":"\#(raw)","message":"detail for \#(raw)"}"#.utf8)
        #expect(throws: DeviceTrustError.collector(code: expected, message: "detail for \(raw)", status: 401)) {
            try DeviceTrustResponseParser.parseSession(status: 401, body: body)
        }
    }

    @Test("오류 본문이 JSON이 아니면 상태코드만 보고한다") func nonJSONErrorBodyReportsStatus() {
        let error = DeviceTrustResponseParser.collectorError(status: 502, body: Data("<html>Bad Gateway</html>".utf8))
        #expect(error == .unexpectedStatus(502))
    }

    @Test("heartbeat 204는 성공이고 401은 오류") func heartbeatStatusMapping() throws {
        try DeviceTrustResponseParser.parseHeartbeat(status: 204, body: Data())
        let body = Data(#"{"error":"device_not_registered","message":"unknown device"}"#.utf8)
        let error = #expect(throws: DeviceTrustError.self) {
            try DeviceTrustResponseParser.parseHeartbeat(status: 401, body: body)
        }
        #expect(error == .collector(code: .deviceNotRegistered, message: "unknown device", status: 401))
        #expect(error?.errorDescription?.contains("COLLECTOR_DEVICE_KEYS") == true, "description: \(String(describing: error?.errorDescription))")
    }
}

struct DeviceEnrollmentParserTests {
    @Test("202 pending 과 200 registered 를 구분한다") func distinguishesPendingAndRegistered() throws {
        #expect(try DeviceTrustResponseParser.parseEnrollment(status: 202, body: Data(#"{"status":"pending","thumbprint":"t"}"#.utf8)) == .pending)
        #expect(try DeviceTrustResponseParser.parseEnrollment(status: 200, body: Data(#"{"status":"registered","thumbprint":"t"}"#.utf8)) == .registered)
    }

    @Test("모르는 status 는 잘못된 응답이다") func unknownStatusIsMalformed() {
        #expect(throws: DeviceTrustError.malformedResponse) {
            try DeviceTrustResponseParser.parseEnrollment(status: 202, body: Data(#"{"status":"approved"}"#.utf8))
        }
    }

    @Test("요청이 너무 많으면 collector 오류로 올린다") func tooManyRequestsIsCollectorError() {
        let body = Data(#"{"error":"too_many_enrollment_requests","message":"대기 중인 등록 요청이 너무 많습니다"}"#.utf8)
        #expect(throws: DeviceTrustError.collector(code: .other("too_many_enrollment_requests"), message: "대기 중인 등록 요청이 너무 많습니다", status: 429)) {
            try DeviceTrustResponseParser.parseEnrollment(status: 429, body: body)
        }
    }
}
