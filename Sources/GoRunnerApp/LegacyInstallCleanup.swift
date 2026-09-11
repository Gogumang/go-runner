import ClaudeUsage
import CodexUsage
import Foundation
import GoRunnerCore

/// Undoes what builds from before the RunAX → GoRunner rename left on this Mac: their Claude Code statusline and Stop
/// hook and their Codex notify line (each restored from that build's own backups), then their folders and defaults.
///
/// Runs before anything installs a hook. Otherwise a new hook would save the old hook as the "previous command" it
/// chains to, and that command breaks as soon as the old folder is gone.
struct LegacyInstallCleanup {
    static let legacyBundleID = "dev.runax.RunAX"
    static let legacyFolderName = "RunAX"

    var home: URL
    var claudeSettingsURL: URL
    var codexConfigURL: URL

    static var standard: LegacyInstallCleanup {
        LegacyInstallCleanup(home: FileManager.default.homeDirectoryForCurrentUser,
                             claudeSettingsURL: ClaudeStopHookInstaller.standard.claudeSettingsURL,
                             codexConfigURL: CodexNotifyInstaller.defaultConfigURL)
    }

    struct Result {
        var restored: [String] = []
        var removedPaths: [String] = []
        var errors: [String] = []
    }

    // MARK: Old layout

    private var support: URL {
        home.appendingPathComponent("Library/Application Support/\(Self.legacyFolderName)", isDirectory: true)
    }
    private var binDirectory: URL { support.appendingPathComponent("bin", isDirectory: true) }
    private var backupsDirectory: URL { support.appendingPathComponent("Backups", isDirectory: true) }

    var ownedLocations: [URL] {
        [
            support,
            home.appendingPathComponent("Library/Caches/\(Self.legacyBundleID)", isDirectory: true),
            home.appendingPathComponent("Library/Logs/\(Self.legacyFolderName)", isDirectory: true),
            home.appendingPathComponent("Library/HTTPStorages/\(Self.legacyBundleID)"),
            home.appendingPathComponent("Library/Saved Application State/\(Self.legacyBundleID).savedState"),
        ]
    }

    /// The old build's backups of the user's settings files are kept here instead of being deleted.
    var keptBackupsDirectory: URL {
        home.appendingPathComponent("Library/Application Support/GoRunner/Backups/\(Self.legacyFolderName)", isDirectory: true)
    }

    var statuslineInstaller: ClaudeStatuslineInstaller {
        ClaudeStatuslineInstaller(claudeSettingsURL: claudeSettingsURL, binDirectory: binDirectory,
                                  backupsDirectory: backupsDirectory,
                                  statuslineFile: support.appendingPathComponent("claude-statusline.json"),
                                  commandMarker: "\(Self.legacyFolderName)/bin/claude-statusline")
    }

    var stopHookInstaller: ClaudeStopHookInstaller {
        ClaudeStopHookInstaller(claudeSettingsURL: claudeSettingsURL, binDirectory: binDirectory,
                                backupsDirectory: backupsDirectory,
                                eventsFile: support.appendingPathComponent("agent-events.jsonl"),
                                hookMarker: "\(Self.legacyFolderName)/bin/runax-agent-event")
    }

    var codexNotifyInstaller: CodexNotifyInstaller {
        CodexNotifyInstaller(codexConfigURL: codexConfigURL, binDirectory: binDirectory, backupsDirectory: backupsDirectory,
                             eventsFile: support.appendingPathComponent("agent-events.jsonl"),
                             wrapperName: "runax-codex-notify")
    }

    // MARK: Run

    @discardableResult
    func run() -> Result {
        var result = Result()
        let fileManager = FileManager.default
        // A Mac that never ran an old build (or was already cleaned) has none of these: no settings file is touched.
        guard ownedLocations.contains(where: { fileManager.fileExists(atPath: $0.path) }) else { return result }

        restore("Claude Code statusline", wasInstalled: statuslineInstaller.isInstalled, into: &result) {
            try statuslineInstaller.uninstall()
        }
        restore("Claude Code Stop hook", wasInstalled: stopHookInstaller.isInstalled, into: &result) {
            try stopHookInstaller.uninstall()
        }
        restore("Codex notify", wasInstalled: codexNotifyInstaller.isInstalled, into: &result) {
            try codexNotifyInstaller.uninstall()
        }
        // The restores read their backups from the old folder, so it stays until every one of them succeeded.
        guard result.errors.isEmpty else {
            log(result)
            return result
        }

        if fileManager.fileExists(atPath: backupsDirectory.path) {
            do {
                try fileManager.createDirectory(at: keptBackupsDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: backupsDirectory, to: keptBackupsDirectory)
            } catch {
                result.errors.append("backups: \(error.localizedDescription)")
                log(result)
                return result
            }
        }

        for url in ownedLocations where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
                result.removedPaths.append(url.path)
            } catch {
                result.errors.append("\(url.path): \(error.localizedDescription)")
            }
        }
        if UserDefaults.standard.persistentDomain(forName: Self.legacyBundleID) != nil {
            UserDefaults.standard.removePersistentDomain(forName: Self.legacyBundleID)
        }
        log(result)
        return result
    }

    private func restore(_ name: String, wasInstalled: Bool, into result: inout Result, _ uninstall: () throws -> Void) {
        do {
            try uninstall()
            if wasInstalled { result.restored.append(name) }
        } catch {
            result.errors.append("\(name): \(error.localizedDescription)")
        }
    }

    private func log(_ result: Result) {
        Log.app.notice("""
            Legacy RunAX cleanup: restored [\(result.restored.joined(separator: ", "), privacy: .public)], \
            removed \(result.removedPaths.count) path(s), \(result.errors.count) error(s)
            """)
        for error in result.errors {
            Log.app.error("Legacy RunAX cleanup failed: \(error, privacy: .public)")
        }
    }
}
