import AppKit
import ClaudeUsage
import Foundation
import GoRunnerCore
import Security
import ServiceManagement

/// Removes everything go-runner created. Used by the in-app "go-runner 제거…" flow and `--uninstall-cleanup`.
@MainActor
final class UninstallService {
    struct Result: Encodable {
        var ok = true
        var loginItemUnregistered = false
        /// "restored", "notInstalled" or "failed".
        var claudeStatusline = "notInstalled"
        /// Claude Code Stop hook: "removed", "notInstalled" or "failed".
        var claudeStopHook = "notInstalled"
        /// Codex notify: "restored", "notInstalled" or "failed".
        var codexNotify = "notInstalled"
        var keychainItemsDeleted = false
        var defaultsRemoved = false
        var removedPaths: [String] = []
        var appBundleRecycled = false
        var errors: [String] = []
    }

    private let stopMonitors: (() -> Void)?

    init(stopMonitors: (() -> Void)? = nil) {
        self.stopMonitors = stopMonitors
    }

    // MARK: Plan

    nonisolated static var isBundleInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// Human-readable list of everything that will be removed or restored.
    nonisolated static func plan() -> [String] {
        var items: [String] = []
        let fm = FileManager.default
        if isBundleInApplicationsFolder {
            items.append(Bundle.main.bundleURL.path)
        }
        for url in AppPaths.ownedLocations where fm.fileExists(atPath: url.path) {
            items.append(url.path)
        }
        if ClaudeStatuslineInstaller.standard.isInstalled {
            items.append(Loc.t("Claude Code statusline 복원", "Restore the Claude Code statusline"))
        }
        let hooks = AgentHooks.standard
        if hooks.isInstalled(.claude) {
            items.append(Loc.t("Claude Code 작업 완료 훅 제거", "Remove the Claude Code finish hook"))
        }
        if hooks.isInstalled(.codex) {
            items.append(Loc.t("Codex 알림 설정 복원", "Restore the Codex notify setting"))
        }
        if keychainItemsExist() {
            items.append(Loc.t("키체인 항목 (서비스: \(AppIdentity.keychainService))",
                               "Keychain items (service: \(AppIdentity.keychainService))"))
        }
        let status = SMAppService.mainApp.status
        if status == .enabled || status == .requiresApproval {
            items.append(Loc.t("로그인 시 자동 실행 등록", "Launch at login registration"))
        }
        return items
    }

    // MARK: Perform

    func perform(removeAppBundle: Bool, terminate: Bool) async -> Result {
        var result = Result()
        let fm = FileManager.default
        Log.app.notice("Uninstall started (removeAppBundle: \(removeAppBundle))")

        // 1. Login item
        do {
            try await SMAppService.mainApp.unregister()
            result.loginItemUnregistered = true
        } catch {
            // Not registered or not a bundle: nothing to undo.
        }

        // 2. Claude Code statusline
        let installer = ClaudeStatuslineInstaller.standard
        let wasInstalled = installer.isInstalled
        do {
            try installer.uninstall()
            result.claudeStatusline = wasInstalled ? "restored" : "notInstalled"
        } catch {
            result.claudeStatusline = "failed"
            result.errors.append("statusline: \(error.localizedDescription)")
        }

        // 2b. Finish-notification hooks (before step 6 deletes the scripts they point at)
        let hooks = AgentHooks.standard
        for kind in AgentKind.allCases {
            let wasHookInstalled = hooks.isInstalled(kind)
            let outcome: String
            do {
                try hooks.uninstall(kind)
                outcome = wasHookInstalled ? (kind == .claude ? "removed" : "restored") : "notInstalled"
            } catch {
                outcome = "failed"
                result.errors.append("\(kind.rawValue) finish hook: \(error.localizedDescription)")
            }
            switch kind {
            case .claude: result.claudeStopHook = outcome
            case .codex: result.codexNotify = outcome
            }
        }

        // 3. Keychain
        result.keychainItemsDeleted = Self.deleteKeychainItems()

        // 4. Monitors (so nothing writes files again)
        stopMonitors?()

        // 5. Defaults
        UserDefaults.standard.removePersistentDomain(forName: AppIdentity.bundleID)
        UserDefaults.standard.synchronize()
        result.defaultsRemoved = true

        // 6. Owned files and folders
        let home = fm.homeDirectoryForCurrentUser.path + "/"
        for url in AppPaths.ownedLocations {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(home), fm.fileExists(atPath: path) else { continue }
            do {
                try fm.removeItem(atPath: path)
                result.removedPaths.append(path)
            } catch {
                result.errors.append("\(path): \(error.localizedDescription)")
            }
        }

        // 7. App bundle
        if removeAppBundle, Self.isBundleInApplicationsFolder {
            do {
                _ = try await NSWorkspace.shared.recycle([Bundle.main.bundleURL])
                result.appBundleRecycled = true
            } catch {
                result.errors.append("app bundle: \(error.localizedDescription)")
            }
        }

        result.ok = result.errors.isEmpty
        Log.app.notice("Uninstall finished with \(result.errors.count) error(s)")

        // 8. Quit
        if terminate {
            NSApp.terminate(nil)
        }
        return result
    }

    // MARK: Keychain

    private nonisolated static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AppIdentity.keychainService]
    }

    nonisolated static func keychainItemsExist() -> Bool {
        var query = keychainQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Deletes every generic password with GoRunner's service. Returns true when at least one was deleted.
    nonisolated static func deleteKeychainItems() -> Bool {
        var deleted = false
        for _ in 0..<50 {
            let status = SecItemDelete(keychainQuery as CFDictionary)
            guard status == errSecSuccess else { break }
            deleted = true
        }
        return deleted
    }
}

/// `GoRunner --uninstall-cleanup`: everything except moving the app bundle; prints a JSON summary.
enum UninstallCleanupCommand {
    @MainActor
    static func run() async -> Int32 {
        let result = await UninstallService().perform(removeAppBundle: false, terminate: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(result) else { return 1 }
        HeadlessRunner.printJSON(data)
        return 0
    }
}
