import Combine
import Foundation

/// All user settings. Persisted as one JSON blob; unknown/missing keys fall back to defaults.
public struct AppSettings: Codable, Equatable, Sendable {
    // Runner (Classic General tab)
    /// Personal build default: Claude Code's Clawd. Change to a non-brand runner such as "gopher" before any public
    /// distribution (see THIRD_PARTY_NOTICES.md).
    public var runnerID = "clawd"
    public var invertSpeed = false
    public var flipHorizontally = false
    public var useSystemAccentColor = false
    public var randomRunnerEnabled = false
    public var randomRunnerMonochromeOnly = false
    public var runnerStopped = false
    public var fpsMaxLimit: FPSMaxLimit = .fps40

    // Menu bar
    /// Classic "Show CPU Usage": text left of the runner.
    public var showCPUText = false

    // System info (Classic System Info tab / Neo Metrics tab)
    public var updateIntervalSeconds = 5
    public var monitorMemory = true
    public var monitorStorage = true
    public var monitorBattery = true
    public var monitorNetwork = true

    // General
    public var hasCompletedOnboarding = false

    // AI usage
    public var quota = QuotaSettings()

    // Agent finish notifications (opt-in; turning one on installs a hook, see AgentEvents.swift)
    /// macOS notification when a Claude Code turn finishes (Claude Code `Stop` hook).
    public var notifyOnClaudeFinish = false
    /// macOS notification when a Codex turn finishes (Codex `notify` program).
    public var notifyOnCodexFinish = false
    /// macOS notification when Slack's Dock badge count goes up (needs Accessibility permission).
    public var notifyOnSlackMessage = true

    public init() {}

    public var metricsOptions: MetricsOptions {
        MetricsOptions(interval: TimeInterval(max(1, updateIntervalSeconds)), memory: monitorMemory,
                       storage: monitorStorage, battery: monitorBattery, network: monitorNetwork)
    }
}

@MainActor
public final class SettingsStore: ObservableObject {
    public static let defaultsKey = "GORUNNER_SETTINGS_V1"

    @Published public var settings: AppSettings {
        didSet { if settings != oldValue { save() } }
    }

    private let defaults: UserDefaults

    /// Stored settings revision; one-time changes for earlier revisions run in `init`.
    public static let revisionKey = "GORUNNER_SETTINGS_REVISION"
    public static let currentRevision = 2

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var loaded = Self.decodeMerged(data: defaults.data(forKey: Self.defaultsKey), defaults: AppSettings())
        let revision = defaults.integer(forKey: Self.revisionKey)
        if revision < 2 {
            // Revision 2: the menu shows remaining limits, not token or cost estimates, so parsing Claude Code's local
            // logs (the heaviest refresh work, hundreds of MB) is off unless the user turns it back on in Settings.
            loaded.quota.claudeLocalLogsSource = false
        }
        settings = loaded
        if revision < Self.currentRevision {
            defaults.set(Self.currentRevision, forKey: Self.revisionKey)
            save()
        }
    }

    public func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// Decodes stored JSON on top of the encoded defaults so new fields never break old data.
    public static func decodeMerged<T: Codable>(data: Data?, defaults: T) -> T {
        guard let data,
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(defaults),
              var base = try? JSONSerialization.jsonObject(with: defaultData) as? [String: Any]
        else { return defaults }
        merge(into: &base, from: stored)
        guard let mergedData = try? JSONSerialization.data(withJSONObject: base),
              let value = try? JSONDecoder().decode(T.self, from: mergedData)
        else { return defaults }
        return value
    }

    private static func merge(into base: inout [String: Any], from stored: [String: Any]) {
        for (key, value) in stored {
            if let nested = value as? [String: Any], var baseNested = base[key] as? [String: Any] {
                merge(into: &baseNested, from: nested)
                base[key] = baseNested
            } else {
                base[key] = value
            }
        }
    }
}
