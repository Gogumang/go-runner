import Foundation
import GoRunnerCore

/// The user-visible app name from the bundle (`CFBundleDisplayName`, then `CFBundleName`), so renaming the app in
/// Info.plist shows up in the UI and notifications. Falls back to `AppIdentity.appName` for the unbundled binary.
enum AppDisplayName {
    static let current: String = {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = Bundle.main.object(forInfoDictionaryKey: key) as? String,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name
            }
        }
        return AppIdentity.appName
    }()
}
