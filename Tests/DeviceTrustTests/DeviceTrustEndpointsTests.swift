import Foundation
import Testing
@testable import DeviceTrust

struct DeviceTrustEndpointsTests {
    @Test("끝 슬래시와 공백을 떼고 경로를 붙인다") func trimsBaseAndAppendsPath() throws {
        let url = try DeviceTrustEndpoints.url(base: "  https://airflow.gogumang.com/collector//\n", path: DeviceTrustEndpoints.heartbeatPath)
        #expect(url.absoluteString == "https://airflow.gogumang.com/collector/api/device/heartbeat")
    }

    @Test("https가 아니거나 쿼리가 있으면 거부한다", arguments: ["", "airflow.gogumang.com/collector", "http://airflow.gogumang.com/collector",
                      "https://airflow.gogumang.com/collector?x=1", "ftp://example.com"])
    func rejectsNonHTTPSOrQuery(base: String) {
        #expect(throws: DeviceTrustError.invalidBaseURL(field: .collector, value: base)) {
            try DeviceTrustEndpoints.url(base: base, path: "/api")
        }
    }

    @Test("로컬 collector는 http를 허용한다") func allowsHTTPForLoopback() throws {
        let url = try DeviceTrustEndpoints.url(base: "http://localhost:8080", path: DeviceTrustEndpoints.sessionsPath)
        #expect(url.absoluteString == "http://localhost:8080/api/device/sessions")
    }

    @Test("어드민 연결 주소는 코드를 퍼센트 인코딩한다") func adminConnectURLPercentEncodesCode() throws {
        let plain = try DeviceTrustEndpoints.adminConnectURL(adminBase: "https://admin.example.com/", handoffCode: "abc_DEF-123")
        #expect(plain.absoluteString == "https://admin.example.com/device/connect?code=abc_DEF-123")

        let tricky = try DeviceTrustEndpoints.adminConnectURL(adminBase: "https://admin.example.com", handoffCode: "a+b/c=&d")
        #expect(tricky.absoluteString == "https://admin.example.com/device/connect?code=a%2Bb%2Fc%3D%26d")
        #expect(URLComponents(url: tricky, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "a+b/c=&d")
    }

    @Test("어드민 주소가 비어 있으면 거부한다") func rejectsEmptyAdminBase() {
        #expect(throws: DeviceTrustError.invalidBaseURL(field: .admin, value: "  ")) {
            try DeviceTrustEndpoints.adminConnectURL(adminBase: "  ", handoffCode: "x")
        }
    }
}
