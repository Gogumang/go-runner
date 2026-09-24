import Foundation

/// 201 body of POST /api/device/sessions.
public struct DeviceSessionHandoff: Equatable, Sendable {
    public let handoffCode: String
    public let expiresInSeconds: Int
}

/// Pure mapping from (status, body) to results or typed errors, kept apart from the network code for tests.
public enum DeviceTrustResponseParser {
    public static func parseSession(status: Int, body: Data) throws -> DeviceSessionHandoff {
        guard (200..<300).contains(status) else { throw collectorError(status: status, body: body) }
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let code = root["handoffCode"] as? String, !code.isEmpty
        else {
            throw DeviceTrustError.malformedResponse
        }
        let expiresIn = (root["expiresInSeconds"] as? NSNumber)?.intValue ?? 0
        return DeviceSessionHandoff(handoffCode: code, expiresInSeconds: expiresIn)
    }

    public static func parseHeartbeat(status: Int, body: Data) throws {
        guard (200..<300).contains(status) else { throw collectorError(status: status, body: body) }
    }

    /// `{"error","message"}` becomes `.collector`; anything else (proxy HTML pages, empty bodies) is `.unexpectedStatus`.
    public static func collectorError(status: Int, body: Data) -> DeviceTrustError {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let code = root["error"] as? String, !code.isEmpty
        else {
            return .unexpectedStatus(status)
        }
        return .collector(code: CollectorErrorCode(rawValue: code), message: root["message"] as? String, status: status)
    }
}
