import BedrockUsage
import ClaudeUsage
import CodexUsage
import Combine
import Foundation
import GoRunnerCore

/// Schedules provider refreshes, merges results with the on-disk cache and publishes reports for the UI.
/// To save battery there is no refresh timer: providers refresh when the menu opens (data older than a minute), and
/// Claude also when its statusline record changes.
@MainActor
final class QuotaCoordinator: ObservableObject {
    static let fetchTimeout: TimeInterval = 35
    static let statuslinePollInterval: TimeInterval = 15

    @Published private(set) var reports: [ProviderID: ProviderReport] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshingProviders: Set<ProviderID> = []
    /// Providers currently showing cached data that no refresh has confirmed yet.
    @Published private(set) var staleProviders: Set<ProviderID> = []
    @Published private(set) var lastAttemptAt: [ProviderID: Date] = [:]

    private let settingsStore: SettingsStore
    private let providers: [ProviderID: any UsageProvider]
    private var quotaSettings: QuotaSettings
    private var cache: [ProviderID: QuotaSnapshot] = [:]
    private var lastStatuslineMTime: Date?
    private var pendingSettingsRefresh: Set<ProviderID> = []
    private var started = false
    private var stopped = false

    private var statuslineTimer: AnyCancellable?
    private var settingsDebounce: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    init(settingsStore: SettingsStore,
         providers: [any UsageProvider] = [ClaudeUsageProvider(), CodexUsageProvider(), BedrockUsageProvider()]) {
        self.settingsStore = settingsStore
        self.providers = Dictionary(providers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        quotaSettings = settingsStore.settings.quota
    }

    static func isEnabled(_ id: ProviderID, in settings: QuotaSettings) -> Bool {
        switch id {
        case .claude: settings.claudeEnabled
        case .codex: settings.codexEnabled
        case .bedrock: settings.bedrockEnabled
        }
    }

    func start() {
        guard !started else { return }
        started = true
        quotaSettings = settingsStore.settings.quota

        cache = QuotaCache.load()
        for (id, snapshot) in cache {
            reports[id] = ProviderReport(provider: id, snapshot: snapshot, error: nil, attempts: [])
            staleProviders.insert(id)
        }

        lastStatuslineMTime = Self.modificationDate(of: AppPaths.claudeStatuslineFile)
        statuslineTimer = Timer.publish(every: Self.statuslinePollInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkStatuslineFile() }

        settingsStore.$settings
            .map(\.quota)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] quota in self?.quotaSettingsChanged(quota) }
            .store(in: &cancellables)
    }

    func stop() {
        stopped = true
        statuslineTimer = nil
        settingsDebounce = nil
        cancellables.removeAll()
    }

    /// Refreshes the given providers (default: all enabled). Providers already in flight are skipped.
    func refresh(_ ids: Set<ProviderID>? = nil) {
        guard !stopped else { return }
        let settings = quotaSettings
        let targets = (ids ?? Set(ProviderID.allCases))
            .filter { Self.isEnabled($0, in: settings) && !refreshingProviders.contains($0) }
        let work = targets.compactMap { providers[$0] }
        guard !work.isEmpty else { return }

        refreshingProviders.formUnion(work.map(\.id))
        isRefreshing = true
        let timeout = Self.fetchTimeout
        Log.quota.info("Refreshing \(work.map(\.id.rawValue).joined(separator: ","), privacy: .public)")

        Task { @MainActor [weak self] in
            await withTaskGroup(of: ProviderReport.self) { group in
                for provider in work {
                    group.addTask { await ProviderFetch.fetch(provider, settings: settings, timeout: timeout) }
                }
                for await report in group {
                    self?.apply(report)
                }
            }
        }
    }

    /// Menu opened: refreshes the enabled providers whose last attempt is older than `maxAge`.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        let now = Date()
        let stale = ProviderID.allCases.filter { id in
            guard let last = lastAttemptAt[id] else { return true }
            return now.timeIntervalSince(last) > maxAge
        }
        if !stale.isEmpty { refresh(Set(stale)) }
    }

    private func apply(_ report: ProviderReport) {
        let id = report.provider
        refreshingProviders.remove(id)
        isRefreshing = !refreshingProviders.isEmpty
        guard !stopped else { return }
        if !isRefreshing {
            // Parsing leaves freed pages dirty in malloc's zones; hand them back so the footprint drops after a refresh.
            DispatchQueue.main.async { _ = malloc_zone_pressure_relief(nil, 0) }
        }
        lastAttemptAt[id] = Date()

        if let snapshot = report.snapshot {
            cache[id] = snapshot
            staleProviders.remove(id)
            reports[id] = report
            QuotaCache.save(cache)
        } else if let cached = cache[id] {
            // Keep the last good data visible next to the new error.
            reports[id] = ProviderReport(provider: id, snapshot: cached, error: report.error, attempts: report.attempts)
            staleProviders.insert(id)
        } else {
            reports[id] = report
        }
        if let error = report.error {
            Log.quota.notice("\(id.rawValue, privacy: .public): \(error.kind.rawValue, privacy: .public) \(error.message, privacy: .public)")
        }
    }

    private func checkStatuslineFile() {
        let mtime = Self.modificationDate(of: AppPaths.claudeStatuslineFile)
        defer { lastStatuslineMTime = mtime }
        guard let mtime, mtime != lastStatuslineMTime else { return }
        if quotaSettings.claudeEnabled, quotaSettings.claudeStatuslineSource {
            refresh([.claude])
        }
    }

    private func quotaSettingsChanged(_ new: QuotaSettings) {
        let old = quotaSettings
        quotaSettings = new

        if new.claudeEnabled != old.claudeEnabled || new.claudeStatuslineSource != old.claudeStatuslineSource
            || new.claudeOAuthSource != old.claudeOAuthSource || new.claudeLocalLogsSource != old.claudeLocalLogsSource {
            pendingSettingsRefresh.insert(.claude)
        }
        if new.codexEnabled != old.codexEnabled || new.codexAppServerSource != old.codexAppServerSource
            || new.codexSessionLogsSource != old.codexSessionLogsSource || new.codexExecutablePath != old.codexExecutablePath {
            pendingSettingsRefresh.insert(.codex)
        }
        if new.bedrockEnabled != old.bedrockEnabled || new.awsProfile != old.awsProfile || new.awsRegion != old.awsRegion
            || new.bedrockModelIDs != old.bedrockModelIDs || new.bedrockCostExplorer != old.bedrockCostExplorer
            || new.awsExecutablePath != old.awsExecutablePath {
            pendingSettingsRefresh.insert(.bedrock)
        }
        guard !pendingSettingsRefresh.isEmpty else { return }

        // Debounce so typing a path or toggling several sources triggers one refresh.
        settingsDebounce = Just(())
            .delay(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let ids = self.pendingSettingsRefresh
                self.pendingSettingsRefresh = []
                self.refresh(ids)
            }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

// MARK: - Fetch with a hard timeout

enum ProviderFetch {
    /// Runs `provider.fetch` but returns a timeout report after `timeout` seconds even if the provider ignores cancellation.
    static func fetch(_ provider: any UsageProvider, settings: QuotaSettings, timeout: TimeInterval) async -> ProviderReport {
        let id = provider.id
        let gate = ResumeGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<ProviderReport, Never>) in
            let work = Task.detached {
                let report = await provider.fetch(settings: settings)
                if gate.claim() { continuation.resume(returning: report) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if gate.claim() {
                    work.cancel()
                    let error = ProviderError(kind: .timeout,
                                              message: Loc.t("\(Int(timeout))초 안에 응답이 없습니다", "No response within \(Int(timeout)) s"),
                                              fixHint: nil)
                    continuation.resume(returning: ProviderReport(provider: id, snapshot: nil, error: error, attempts: []))
                }
            }
        }
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}

// MARK: - Cache

enum QuotaCache {
    static func load(from url: URL = AppPaths.quotaCacheFile) -> [ProviderID: QuotaSnapshot] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? decoder.decode([String: QuotaSnapshot].self, from: data) else {
            Log.quota.error("Quota cache unreadable; ignoring")
            return [:]
        }
        var result: [ProviderID: QuotaSnapshot] = [:]
        for (key, snapshot) in raw {
            if let id = ProviderID(rawValue: key) { result[id] = snapshot }
        }
        return result
    }

    static func save(_ cache: [ProviderID: QuotaSnapshot], to url: URL = AppPaths.quotaCacheFile) {
        let raw = Dictionary(uniqueKeysWithValues: cache.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(raw).write(to: url, options: .atomic)
        } catch {
            Log.quota.error("Quota cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
