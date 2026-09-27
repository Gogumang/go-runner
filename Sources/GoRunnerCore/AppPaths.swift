import Foundation
import os

public enum AppIdentity {
    public static let bundleID = "dev.gorunner.GoRunner"
    /// User-visible name. Bundle id, executable and data folders use "GoRunner"; builds before the rename used "RunAX".
    public static let appName = "go-runner"
    public static let keychainService = "dev.gorunner.GoRunner"

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Every location GoRunner writes to. The uninstaller removes exactly these (plus the app bundle and defaults).
public enum AppPaths {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// ~/Library/Application Support/GoRunner
    public static var applicationSupport: URL {
        home.appendingPathComponent("Library/Application Support/GoRunner", isDirectory: true)
    }

    /// Backups of files GoRunner modified outside its own folders (e.g. ~/.claude/settings.json).
    public static var backupsDirectory: URL { applicationSupport.appendingPathComponent("Backups", isDirectory: true) }

    /// Helper scripts installed by GoRunner (e.g. the Claude statusline hook).
    public static var binDirectory: URL { applicationSupport.appendingPathComponent("bin", isDirectory: true) }

    /// Latest Claude Code statusline payload written by the hook.
    public static var claudeStatuslineFile: URL { applicationSupport.appendingPathComponent("claude-statusline.json") }

    /// Agent finish events appended by `gorunner-agent-event` (one JSON object per line; no prompts or messages).
    public static var agentEventsFile: URL { applicationSupport.appendingPathComponent("agent-events.jsonl") }

    /// Last good provider snapshots (no secrets).
    public static var quotaCacheFile: URL { cacheDirectory.appendingPathComponent("quota-cache.json") }

    /// ~/Library/Caches/dev.gorunner.GoRunner
    public static var cacheDirectory: URL {
        home.appendingPathComponent("Library/Caches/\(AppIdentity.bundleID)", isDirectory: true)
    }

    /// ~/Library/Logs/GoRunner
    public static var logsDirectory: URL { home.appendingPathComponent("Library/Logs/GoRunner", isDirectory: true) }

    public static var preferencesFile: URL {
        home.appendingPathComponent("Library/Preferences/\(AppIdentity.bundleID).plist")
    }

    /// Folders/files owned entirely by GoRunner (safe to delete on uninstall).
    /// `applicationSupport` is removed as a whole, which also covers leftovers from earlier builds
    /// (e.g. the old `Runners` folder for imported runner packs).
    public static var ownedLocations: [URL] {
        [
            applicationSupport,
            cacheDirectory,
            logsDirectory,
            preferencesFile,
            home.appendingPathComponent("Library/HTTPStorages/\(AppIdentity.bundleID)"),
            home.appendingPathComponent("Library/Saved Application State/\(AppIdentity.bundleID).savedState"),
        ]
    }

    public static func ensureDirectories() {
        for url in [applicationSupport, backupsDirectory, binDirectory, cacheDirectory, logsDirectory] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

public enum Log {
    public static let app = Logger(subsystem: AppIdentity.bundleID, category: "app")
    public static let metrics = Logger(subsystem: AppIdentity.bundleID, category: "metrics")
    public static let runner = Logger(subsystem: AppIdentity.bundleID, category: "runner")
    public static let quota = Logger(subsystem: AppIdentity.bundleID, category: "quota")
}
