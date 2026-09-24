import Foundation

public enum DeviceTrustEndpoints {
    public static let sessionsPath = "/api/device/sessions"
    public static let heartbeatPath = "/api/device/heartbeat"
    public static let enrollmentsPath = "/api/device/enrollments"
    public static let adminConnectPath = "/device/connect"

    /// Base URL plus path. The result is also the DPoP `htu`, so the base is normalized to have no trailing slash,
    /// no query and no fragment. Plain http is only accepted for loopback hosts (local collector).
    public static func url(base: String, path: String, field: DeviceTrustError.BaseURLField = .collector) throws -> URL {
        let normalized = try normalizedBase(base, field: field)
        guard let url = URL(string: normalized + path) else {
            throw DeviceTrustError.invalidBaseURL(field: field, value: base)
        }
        return url
    }

    /// `<adminBase>/device/connect?code=<percent-encoded handoff code>`.
    public static func adminConnectURL(adminBase: String, handoffCode: String) throws -> URL {
        let normalized = try normalizedBase(adminBase, field: .admin)
        let encodedCode = handoffCode.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
        guard let url = URL(string: normalized + adminConnectPath + "?code=" + encodedCode) else {
            throw DeviceTrustError.invalidBaseURL(field: .admin, value: adminBase)
        }
        return url
    }

    /// RFC 3986 unreserved characters only, so '+', '&' and '=' in a code can never change the query.
    private static let queryValueAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    static func normalizedBase(_ base: String, field: DeviceTrustError.BaseURLField) throws -> String {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil
        else {
            throw DeviceTrustError.invalidBaseURL(field: field, value: base)
        }
        let isAllowedScheme = scheme == "https" || (scheme == "http" && loopbackHosts.contains(host.lowercased()))
        guard isAllowedScheme else { throw DeviceTrustError.invalidBaseURL(field: field, value: base) }
        return trimmed
    }
}
