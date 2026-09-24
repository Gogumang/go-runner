import CryptoKit
import Foundation
import Testing
@testable import DeviceTrust

struct DeviceTrustClientTests {
    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { stored } }
        func append(_ request: URLRequest) { lock.withLock { stored.append(request) } }
    }

    private func makeClient(status: Int, body: String, recorder: RequestRecorder) throws -> DeviceTrustClient {
        let signer = try TestKey.signer()
        return DeviceTrustClient(loadSigner: { signer },
                                 transport: { request in
                                     recorder.append(request)
                                     return (Data(body.utf8), httpResponse(request.url!, status: status))
                                 },
                                 now: { Date(timeIntervalSince1970: 1_790_000_000) },
                                 makeJTI: { "fixed-jti" })
    }

    @Test("세션 요청은 DPoP만 싣고 POST로 보낸다") func sessionRequestCarriesOnlyDPoP() async throws {
        // Arrange
        let recorder = RequestRecorder()
        let client = try makeClient(status: 201, body: #"{"handoffCode":"code-1","expiresInSeconds":60}"#, recorder: recorder)

        // Act
        let handoff = try await client.openSession(collectorBaseURL: "https://airflow.gogumang.com/collector/")

        // Assert
        #expect(handoff.handoffCode == "code-1")
        #expect(recorder.requests.count == 1)
        let request = try #require(recorder.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://airflow.gogumang.com/collector/api/device/sessions")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "X-Collector-Token") == nil)
        #expect(request.timeoutInterval == DeviceTrustClient.requestTimeout)
        let proof = try #require(request.value(forHTTPHeaderField: "DPoP"))
        let payload = try jsonObject(proof.split(separator: ".")[1])
        #expect(payload["htu"] as? String == request.url?.absoluteString, "htu must equal the request URL")
        #expect(payload["jti"] as? String == "fixed-jti")
        #expect(payload["iat"] as? Int == 1_790_000_000)
    }

    @Test("등록 요청은 이름을 JSON 본문에 싣고 등록 경로를 htu로 쓴다") func enrollmentSendsNameAndUsesEnrollmentHTU() async throws {
        // Arrange
        let recorder = RequestRecorder()
        let client = try makeClient(status: 202, body: #"{"status":"pending","thumbprint":"t"}"#, recorder: recorder)

        // Act
        let status = try await client.requestEnrollment(collectorBaseURL: "https://airflow.gogumang.com/collector", deviceName: "회사 맥북")

        // Assert
        #expect(status == .pending)
        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://airflow.gogumang.com/collector/api/device/enrollments")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try #require(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(sent["name"] == "회사 맥북")
        let payload = try jsonObject(try #require(request.value(forHTTPHeaderField: "DPoP")).split(separator: ".")[1])
        #expect(payload["htu"] as? String == "https://airflow.gogumang.com/collector/api/device/enrollments")
    }

    @Test("heartbeat는 heartbeat 경로를 htu로 쓴다") func heartbeatUsesHeartbeatHTU() async throws {
        let recorder = RequestRecorder()
        let client = try makeClient(status: 204, body: "", recorder: recorder)

        try await client.sendHeartbeat(collectorBaseURL: "https://airflow.gogumang.com/collector")

        let request = try #require(recorder.requests.first)
        #expect(request.url?.absoluteString == "https://airflow.gogumang.com/collector/api/device/heartbeat")
        let proof = try #require(request.value(forHTTPHeaderField: "DPoP"))
        let payload = try jsonObject(proof.split(separator: ".")[1])
        #expect(payload["htu"] as? String == "https://airflow.gogumang.com/collector/api/device/heartbeat")
    }

    @Test("미등록 기기 응답은 타입있는 오류로 던진다") func unregisteredDeviceThrowsTypedError() async throws {
        let recorder = RequestRecorder()
        let client = try makeClient(status: 401, body: #"{"error":"device_not_registered","message":"no such device"}"#, recorder: recorder)
        await #expect(throws: DeviceTrustError.collector(code: .deviceNotRegistered, message: "no such device", status: 401)) {
            _ = try await client.openSession(collectorBaseURL: "https://airflow.gogumang.com/collector")
        }
    }

    @Test("잘못된 주소면 요청을 보내지 않는다") func invalidBaseSendsNothing() async throws {
        let recorder = RequestRecorder()
        let client = try makeClient(status: 201, body: "{}", recorder: recorder)
        await #expect(throws: DeviceTrustError.invalidBaseURL(field: .collector, value: "not a url")) {
            _ = try await client.openSession(collectorBaseURL: "not a url")
        }
        #expect(recorder.requests.isEmpty, "no request expected, got: \(recorder.requests)")
    }

    @Test("타임아웃은 timedOut으로 매핑한다") func timeoutMapsToTimedOut() async throws {
        let signer = try TestKey.signer()
        let client = DeviceTrustClient(loadSigner: { signer }, transport: { _ in throw URLError(.timedOut) })
        await #expect(throws: DeviceTrustError.timedOut) {
            try await client.sendHeartbeat(collectorBaseURL: "https://airflow.gogumang.com/collector")
        }
    }
}
