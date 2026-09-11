import Foundation
import GoRunnerCore

// FACADE — the public API below is a contract used by GoRunnerApp and scripts/uninstall.sh. Keep these signatures.

/// Adds a GoRunner command to Claude Code's `hooks.Stop` in ~/.claude/settings.json so GoRunner can notify when a turn
/// finishes. Existing hooks are never modified or reordered; uninstall removes only entries whose command contains
/// `AgentEventLog.hookMarker`.
///
/// Settings schema (https://code.claude.com/docs/en/hooks, verified against Claude Code 2.1.268):
/// `"hooks": {"Stop": [{"matcher"?: "…", "hooks": [{"type": "command", "command": "…", "timeout"?: seconds}]}]}`.
/// Stop has no matcher support (a matcher is ignored), and the hook receives JSON on stdin that includes `cwd`.
public struct ClaudeStopHookInstaller: Sendable {
    public static let standard = ClaudeStopHookInstaller()

    public var claudeSettingsURL: URL
    public var binDirectory: URL
    public var backupsDirectory: URL
    public var eventsFile: URL
    /// Recognizes installed entries in `hooks.Stop`. Builds from before the RunAX rename used another marker.
    public var hookMarker: String

    public init(claudeSettingsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
                binDirectory: URL = AppPaths.binDirectory,
                backupsDirectory: URL = AppPaths.backupsDirectory,
                eventsFile: URL = AppPaths.agentEventsFile,
                hookMarker: String = AgentEventLog.hookMarker) {
        self.claudeSettingsURL = claudeSettingsURL
        self.binDirectory = binDirectory
        self.backupsDirectory = backupsDirectory
        self.eventsFile = eventsFile
        self.hookMarker = hookMarker
    }

    /// True when any `hooks.Stop` command contains `hookMarker`.
    public var isInstalled: Bool {
        guard let settings = try? readSettings(), let hooks = try? ClaudeStopHook.hooksObject(in: settings, path: path),
              let stop = try? ClaudeStopHook.stopGroups(in: hooks, path: path)
        else { return false }
        return ClaudeStopHook.containsEntry(stop, marker: hookMarker)
    }

    public func install() throws {
        try install(now: Date())
    }

    public func uninstall() throws {
        guard var settings = try readSettings(),
              var hooks = settings[ClaudeStopHook.hooksKey] as? [String: Any],
              let stop = hooks[ClaudeStopHook.eventKey] as? [Any]
        else { return }

        var removedAny = false
        var remaining: [Any] = []
        for group in stop {
            guard var object = group as? [String: Any], let entries = object[ClaudeStopHook.hooksKey] as? [Any] else {
                remaining.append(group)
                continue
            }
            let kept = entries.filter { !ClaudeStopHook.isEntry($0, marker: hookMarker) }
            guard kept.count != entries.count else {
                remaining.append(group)
                continue
            }
            removedAny = true
            if kept.isEmpty { continue } // GoRunner made this group empty.
            object[ClaudeStopHook.hooksKey] = kept
            remaining.append(object)
        }
        guard removedAny else { return }

        // `stop` was non-empty and only GoRunner entries were removed, so an empty result is GoRunner's doing.
        if remaining.isEmpty {
            hooks.removeValue(forKey: ClaudeStopHook.eventKey)
        } else {
            hooks[ClaudeStopHook.eventKey] = remaining
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: ClaudeStopHook.hooksKey)
        } else {
            settings[ClaudeStopHook.hooksKey] = hooks
        }
        try writeSettings(settings)
        // The recorder script stays: Codex may still use it. The app's full uninstall removes the bin folder.
    }

    // MARK: Internals

    /// Exact `command` value written into `hooks.Stop`.
    var hookCommand: String {
        ClaudeStopHook.command(recorderURL: AgentEventLog.recorderURL(binDirectory: binDirectory))
    }

    private var path: String { claudeSettingsURL.path }
    private var fileManager: FileManager { .default }

    func install(now: Date) throws {
        // Validate everything before any side effect, so a broken settings file is never touched.
        var settings = try readSettings() ?? [:]
        var hooks = try ClaudeStopHook.hooksObject(in: settings, path: path) ?? [:]
        var stop = try ClaudeStopHook.stopGroups(in: hooks, path: path) ?? []

        try AgentEventLog.installRecorder(binDirectory: binDirectory, eventsFile: eventsFile)
        guard !ClaudeStopHook.containsEntry(stop, marker: hookMarker) else { return }

        try fileManager.createDirectory(at: claudeSettingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let original = fileManager.contents(atPath: path) {
            try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
            try backupFullSettings(original, now: now)
        }

        stop.append(ClaudeStopHook.group(command: hookCommand))
        hooks[ClaudeStopHook.eventKey] = stop
        settings[ClaudeStopHook.hooksKey] = hooks
        try writeSettings(settings)
    }

    /// nil when the file is missing or blank. Throws when it exists but is not a JSON object (never overwrite it then).
    func readSettings() throws -> [String: Any]? {
        guard let data = fileManager.contents(atPath: path) else { return nil }
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClaudeStopHookError.settingsNotJSONObject(path)
        }
        return object
    }

    private func backupFullSettings(_ data: Data, now: Date) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        var url = backupsDirectory.appendingPathComponent("claude-settings-\(stamp).json")
        var suffix = 2
        while fileManager.fileExists(atPath: url.path) {
            url = backupsDirectory.appendingPathComponent("claude-settings-\(stamp)-\(suffix).json")
            suffix += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
    }

    private func writeSettings(_ settings: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
        data.append(0x0A)
        // Write through a symlinked settings.json (dotfile managers) instead of replacing the link.
        try data.write(to: claudeSettingsURL.resolvingSymlinksInPath(), options: .atomic)
    }
}

enum ClaudeStopHook {
    static let hooksKey = "hooks"
    static let eventKey = "Stop"
    /// Seconds. The recorder only appends one line, so this is a safety net that never blocks the agent for long.
    static let timeoutSeconds = 10

    static func command(recorderURL: URL) -> String {
        AgentEventLog.shellSingleQuoted(recorderURL.path) + " claude stop"
    }

    static func group(command: String) -> [String: Any] {
        [hooksKey: [["type": "command", "command": command, "timeout": timeoutSeconds] as [String: Any]]]
    }

    static func isEntry(_ entry: Any, marker: String) -> Bool {
        ((entry as? [String: Any])?["command"] as? String)?.contains(marker) ?? false
    }

    static func containsEntry(_ stop: [Any], marker: String) -> Bool {
        stop.contains { group in
            ((group as? [String: Any])?[hooksKey] as? [Any])?.contains { isEntry($0, marker: marker) } ?? false
        }
    }

    /// nil when `hooks` is absent. Throws when it is present but not an object.
    static func hooksObject(in settings: [String: Any], path: String) throws -> [String: Any]? {
        guard let value = settings[hooksKey] else { return nil }
        guard let object = value as? [String: Any] else {
            throw ClaudeStopHookError.unexpectedShape(path: path, key: hooksKey)
        }
        return object
    }

    /// nil when `hooks.Stop` is absent. Throws when it is present but not an array.
    static func stopGroups(in hooks: [String: Any], path: String) throws -> [Any]? {
        guard let value = hooks[eventKey] else { return nil }
        guard let array = value as? [Any] else {
            throw ClaudeStopHookError.unexpectedShape(path: path, key: "\(hooksKey).\(eventKey)")
        }
        return array
    }
}

enum ClaudeStopHookError: LocalizedError, Equatable {
    case settingsNotJSONObject(String)
    case unexpectedShape(path: String, key: String)

    var errorDescription: String? {
        switch self {
        case .settingsNotJSONObject(let path):
            Loc.t("\(path) 파일이 올바른 JSON 객체가 아니어서 수정하지 않았습니다",
                  "\(path) is not a valid JSON object, so it was left unchanged")
        case .unexpectedShape(let path, let key):
            Loc.t("\(path)의 \(key) 값이 예상한 형식이 아니어서 수정하지 않았습니다",
                  "\(key) in \(path) has an unexpected format, so it was left unchanged")
        }
    }
}
