import Foundation

/// Addresses used by the device-trust flow ("어드민 열기"). The device key itself lives in `AppPaths.deviceSigningKeyFile`.
public struct DeviceTrustSettings: Codable, Equatable, Sendable {
    public static let defaultCollectorBaseURL = "https://airflow.gogumang.com/collector"
    public static let defaultAdminBaseURL = "https://grep-admin.vercel.app"

    /// Collector base URL without a trailing slash; the DPoP `htu` is this plus the endpoint path.
    public var collectorBaseURL = DeviceTrustSettings.defaultCollectorBaseURL
    /// grep-admin base URL.
    public var adminBaseURL = DeviceTrustSettings.defaultAdminBaseURL

    public init() {}

    /// Blank falls back to the default. Settings saved before the admin default existed stored "" here, and a stored
    /// value always wins over a new default when settings are merged, so the default alone would never reach them.
    public var effectiveCollectorBaseURL: String { Self.nonBlank(collectorBaseURL) ?? Self.defaultCollectorBaseURL }
    public var effectiveAdminBaseURL: String { Self.nonBlank(adminBaseURL) ?? Self.defaultAdminBaseURL }

    private static func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
