import Foundation

/// Address the menu's "어드민 열기" opens. The type and the `deviceTrust` settings key keep their old names so saved
/// settings still load; the device-proof flow (Secure Enclave key + collector heartbeats) was removed on 2026-09-27.
public struct DeviceTrustSettings: Codable, Equatable, Sendable {
    public static let defaultAdminBaseURL = "https://grep-admin.gogumang.com"

    /// grep-admin base URL.
    public var adminBaseURL = DeviceTrustSettings.defaultAdminBaseURL

    public init() {}

    /// Blank falls back to the default. Settings saved before the admin default existed stored "" here, and a stored
    /// value always wins over a new default when settings are merged, so the default alone would never reach them.
    public var effectiveAdminBaseURL: String { Self.nonBlank(adminBaseURL) ?? Self.defaultAdminBaseURL }

    private static func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
