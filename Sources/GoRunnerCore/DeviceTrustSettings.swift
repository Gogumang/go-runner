import Foundation

/// Addresses used by the device-trust flow ("어드민 열기"). The device key itself lives in `AppPaths.deviceSigningKeyFile`.
public struct DeviceTrustSettings: Codable, Equatable, Sendable {
    public static let defaultCollectorBaseURL = "https://airflow.gogumang.com/collector"

    /// Collector base URL without a trailing slash; the DPoP `htu` is this plus the endpoint path.
    public var collectorBaseURL = DeviceTrustSettings.defaultCollectorBaseURL
    /// grep-admin base URL. Empty until the user enters it; the menu item stays disabled while empty.
    public var adminBaseURL = ""

    public init() {}

    public var isAdminConfigured: Bool {
        !adminBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
