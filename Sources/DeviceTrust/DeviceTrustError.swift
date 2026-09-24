import Foundation
import GoRunnerCore

/// `error` codes from the collector's `{"error","message"}` body.
public enum CollectorErrorCode: Equatable, Sendable {
    case unauthorized
    case callerNotAllowed
    case invalidDeviceProof
    case deviceNotRegistered
    case deviceSessionRequired
    case invalidHandoff
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "unauthorized": self = .unauthorized
        case "caller_not_allowed": self = .callerNotAllowed
        case "invalid_device_proof": self = .invalidDeviceProof
        case "device_not_registered": self = .deviceNotRegistered
        case "device_session_required": self = .deviceSessionRequired
        case "invalid_handoff": self = .invalidHandoff
        default: self = .other(rawValue)
        }
    }
}

public enum DeviceTrustError: Error, Equatable, LocalizedError, Sendable {
    case secureEnclaveUnavailable
    case keyStorageFailed(String)
    case signingFailed(String)
    case invalidPublicKey
    case invalidBaseURL(field: BaseURLField, value: String)
    case collector(code: CollectorErrorCode, message: String?, status: Int)
    case unexpectedStatus(Int)
    case malformedResponse
    case timedOut
    case network(String)

    public enum BaseURLField: Sendable {
        case collector, admin
    }

    public var errorDescription: String? {
        switch self {
        case .secureEnclaveUnavailable:
            return Loc.t("이 Mac에서 Secure Enclave를 쓸 수 없어 기기 키를 만들 수 없습니다.",
                         "The Secure Enclave is not available on this Mac, so no device key can be created.")
        case .keyStorageFailed(let detail), .signingFailed(let detail):
            return detail
        case .invalidPublicKey:
            return Loc.t("기기 공개키 형식이 올바르지 않습니다.", "The device public key has an unexpected format.")
        case .invalidBaseURL(let field, let value):
            let name = field == .collector ? "collector" : Loc.t("어드민", "admin")
            return Loc.t("\(name) 주소는 https://로 시작하는 주소여야 합니다 (예: https://airflow.gogumang.com/collector), 입력값: \(value)",
                         "The \(name) address must start with https:// (e.g. https://airflow.gogumang.com/collector), got: \(value)")
        case .collector(let code, let message, let status):
            return Self.describe(code: code, serverMessage: message, status: status)
        case .unexpectedStatus(let status):
            return Loc.t("collector가 예상하지 못한 응답을 보냈습니다 (HTTP \(status)).",
                         "The collector returned an unexpected response (HTTP \(status)).")
        case .malformedResponse:
            return Loc.t("collector 응답 형식을 읽을 수 없습니다.", "Could not read the collector response.")
        case .timedOut:
            return Loc.t("collector 응답 시간이 초과되었습니다.", "The collector request timed out.")
        case .network(let detail):
            return Loc.t("collector에 연결하지 못했습니다: \(detail)", "Could not reach the collector: \(detail)")
        }
    }

    private static func describe(code: CollectorErrorCode, serverMessage: String?, status: Int) -> String {
        switch code {
        case .deviceNotRegistered:
            return Loc.t("이 Mac이 collector에 등록되어 있지 않습니다. 설정 > 일반 > 기기 신뢰의 thumbprint를 COLLECTOR_DEVICE_KEYS에 추가하세요.",
                         "This Mac is not registered with the collector. Add the thumbprint from Settings > General > Device Trust to COLLECTOR_DEVICE_KEYS.")
        case .invalidDeviceProof:
            return Loc.t("collector가 기기 서명을 거부했습니다. Mac 시계와 collector 주소를 확인하세요.",
                         "The collector rejected the device proof. Check the Mac's clock and the collector address.")
        default:
            let detail = serverMessage.map { " — \($0)" } ?? ""
            return Loc.t("collector 요청이 거부되었습니다 (HTTP \(status))\(detail)",
                         "The collector refused the request (HTTP \(status))\(detail)")
        }
    }
}
