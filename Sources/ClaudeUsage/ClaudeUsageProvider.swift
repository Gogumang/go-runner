import Foundation
import GoRunnerCore

// FACADE — the public API below is a contract used by GoRunnerApp. Keep these signatures; add more if needed.
//
// Implementation (internal):
//   ClaudeUsageFetcher.swift       runs the enabled sources concurrently with deadlines and merges them
//   ClaudeModels.swift             shared source/window types and helpers
//   StatuslineSource.swift         reads the payload written by the hook                  (trust: official)
//   StatuslineInstallation.swift   hook script + ~/.claude/settings.json backup / edit / restore
//   OAuthUsageSource.swift         opt-in GET /api/oauth/usage with Claude Code's token   (trust: undocumented)
//   LocalLogIndex.swift            incremental ~/.claude/projects/**/*.jsonl parser
//   LocalLogSummary.swift          ccusage-style 5 h blocks, today / 7-day totals          (trust: heuristic)
//   ClaudePricing.swift            per-model USD price table

public struct ClaudeUsageProvider: UsageProvider {
    public let id = ProviderID.claude

    let environment: ClaudeUsageEnvironment

    public init() {
        environment = .live
    }

    init(environment: ClaudeUsageEnvironment) {
        self.environment = environment
    }

    public func fetch(settings: QuotaSettings) async -> ProviderReport {
        await ClaudeUsageFetcher(environment: environment).fetch(settings: settings)
    }
}

/// Installs a Claude Code statusline hook that records `rate_limits` for GoRunner and then runs the
/// user's previous statusline command unchanged. Uninstall restores the previous `statusLine` exactly.
public struct ClaudeStatuslineInstaller: Sendable {
    public static let standard = ClaudeStatuslineInstaller()

    /// Present in `statusLine.command` iff the GoRunner hook is installed (also grepped by `scripts/uninstall.sh`).
    public static let defaultCommandMarker = "GoRunner/bin/claude-statusline"

    public var claudeSettingsURL: URL
    public var binDirectory: URL
    public var backupsDirectory: URL
    public var statuslineFile: URL
    /// Recognizes the installed hook in `statusLine.command`. Builds from before the RunAX rename used another marker.
    public var commandMarker: String

    public init(claudeSettingsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
                binDirectory: URL = AppPaths.binDirectory,
                backupsDirectory: URL = AppPaths.backupsDirectory,
                statuslineFile: URL = AppPaths.claudeStatuslineFile,
                commandMarker: String = ClaudeStatuslineInstaller.defaultCommandMarker) {
        self.claudeSettingsURL = claudeSettingsURL
        self.binDirectory = binDirectory
        self.backupsDirectory = backupsDirectory
        self.statuslineFile = statuslineFile
        self.commandMarker = commandMarker
    }

    /// `binDirectory/claude-statusline.sh` — the command Claude Code runs.
    public var hookScriptURL: URL { binDirectory.appendingPathComponent(StatuslineHook.scriptName) }

    /// `binDirectory/claude-statusline-previous-command` — the user's previous command the hook chains to.
    public var previousCommandURL: URL { binDirectory.appendingPathComponent(StatuslineHook.previousCommandName) }

    /// `backupsDirectory/claude-statusline-previous.json` — previous `statusLine` object or `null`
    /// (also read by `scripts/uninstall.sh`).
    public var previousStatusLineBackupURL: URL {
        backupsDirectory.appendingPathComponent(StatuslineHook.previousObjectBackupName)
    }

    /// True when `statusLine.command` in the Claude settings points at the GoRunner hook.
    public var isInstalled: Bool { StatuslineInstallation(installer: self).isInstalled }

    public func install() throws {
        try StatuslineInstallation(installer: self).install()
    }

    public func uninstall() throws {
        try StatuslineInstallation(installer: self).uninstall()
    }
}
