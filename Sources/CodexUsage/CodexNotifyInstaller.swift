import Foundation
import GoRunnerCore

// FACADE — the public API below is a contract used by GoRunnerApp and scripts/uninstall.sh. Keep these signatures.

/// Points Codex's top-level `notify` in config.toml at GoRunner's wrapper (`binDirectory/gorunner-codex-notify`), which
/// records the event and then execs the previous notify program with its original arguments. Uninstall restores the
/// exact previous line(s) saved in `backupsDirectory/codex-notify-previous.json` (`{"line": "<original>"}` or
/// `{"line": null}` when there was no notify key).
public struct CodexNotifyInstaller: Sendable {
    public static let standard = CodexNotifyInstaller()

    public static let defaultWrapperName = "gorunner-codex-notify"
    public static let previousLineBackupName = "codex-notify-previous.json"

    public var codexConfigURL: URL
    public var binDirectory: URL
    public var backupsDirectory: URL
    public var eventsFile: URL
    /// Wrapper file name, also how `notify` is recognized. Builds from before the RunAX rename used another name.
    public var wrapperName: String

    public init(codexConfigURL: URL = CodexNotifyInstaller.defaultConfigURL,
                binDirectory: URL = AppPaths.binDirectory,
                backupsDirectory: URL = AppPaths.backupsDirectory,
                eventsFile: URL = AppPaths.agentEventsFile,
                wrapperName: String = CodexNotifyInstaller.defaultWrapperName) {
        self.codexConfigURL = codexConfigURL
        self.binDirectory = binDirectory
        self.backupsDirectory = backupsDirectory
        self.eventsFile = eventsFile
        self.wrapperName = wrapperName
    }

    /// `$CODEX_HOME/config.toml`, defaulting to `~/.codex/config.toml`.
    public static var defaultConfigURL: URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath).appendingPathComponent("config.toml")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    }

    /// True when the top-level `notify` in config.toml references the GoRunner wrapper.
    public var isInstalled: Bool { CodexNotifyInstallation(installer: self).isInstalled }

    /// Installs the recorder and wrapper, backs up config.toml and points the top-level `notify` at the wrapper.
    /// Throws without writing the config when it can't be parsed. Idempotent: the original notify backup is kept.
    public func install() throws { try CodexNotifyInstallation(installer: self).install() }

    /// Restores the saved notify text (or removes the line) when the config still references the wrapper, then
    /// deletes the wrapper and the previous-line backup. Timestamped full backups and the shared recorder are kept.
    public func uninstall() throws { try CodexNotifyInstallation(installer: self).uninstall() }
}
