import BedrockUsage
import ClaudeUsage
import CodexUsage
import Foundation
import GoRunnerCore
import RunnerArt
import RunnerKit
import SystemMetrics

/// `GoRunner --smoke-test`: headless self-check. Contract: docs/ralph/TASKS.md ("Smoke test JSON").
/// No status item, no windows, no Keychain, no writes to ~/.claude or the real settings domain.
enum SmokeTest {
    static let settingsSuite = "dev.gorunner.GoRunner.smoketest"
    static let providerTimeout: TimeInterval = 35

    @MainActor
    static func run() async -> Int32 {
        // Providers take the longest, so start them first and sample metrics meanwhile.
        var stored = SettingsStore.decodeMerged(data: UserDefaults.standard.data(forKey: SettingsStore.defaultsKey),
                                                defaults: AppSettings())
        stored.quota.claudeOAuthSource = false
        let quotaSettings = stored.quota
        let providers: [any UsageProvider] = [ClaudeUsageProvider(), CodexUsageProvider(), BedrockUsageProvider()]
        let timeout = providerTimeout
        let providerTask = Task.detached { () -> [ProviderReport] in
            await withTaskGroup(of: ProviderReport.self) { group in
                for provider in providers {
                    group.addTask { await ProviderFetch.fetch(provider, settings: quotaSettings, timeout: timeout) }
                }
                var reports: [ProviderReport] = []
                for await report in group { reports.append(report) }
                return reports
            }
        }

        // Read-only: detection and isInstalled never install or uninstall anything.
        let agentHooksTask = Task.detached { SmokeAgentHooks(AgentHooks.standard) }

        let monitor = SystemMonitor()
        _ = monitor.sampleNow()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let snapshot = monitor.sampleNow()
        monitor.stop()

        let runners = sampleRunners()
        let roundTrip = settingsRoundTrip()
        let reports = await providerTask.value
        let order = ProviderID.allCases
        let providerDTOs = reports
            .sorted { (order.firstIndex(of: $0.provider) ?? 0) < (order.firstIndex(of: $1.provider) ?? 0) }
            .map(SmokeProvider.init)

        let report = SmokeReport(
            ok: true,
            version: AppIdentity.version,
            metrics: SmokeMetrics(snapshot),
            speedCurve: SmokeSpeedCurve(cpu0: SpeedCurve.speed(cpuUsage: 0, invert: false),
                                        cpu50: SpeedCurve.speed(cpuUsage: 0.5, invert: false),
                                        cpu100: SpeedCurve.speed(cpuUsage: 1, invert: false)),
            runners: runners,
            providers: providerDTOs,
            settingsRoundTrip: roundTrip,
            uninstallPlan: AppPaths.ownedLocations.map(\.path),
            agentHooks: await agentHooksTask.value,
            slack: SmokeSlack())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            HeadlessRunner.printJSON(try encoder.encode(report))
            return 0
        } catch {
            let message = String(describing: error).replacingOccurrences(of: "\"", with: "'")
            HeadlessRunner.printJSON(Data("{\"ok\": false, \"error\": \"\(message)\"}".utf8))
            return 1
        }
    }

    @MainActor
    private static func sampleRunners() -> [SmokeRunner] {
        let catalog = RunnerCatalog(builtIns: RunnerArtCatalog.all)
        return catalog.allRunners().map { descriptor in
            var runner = SmokeRunner(descriptor)
            do {
                let frames = try catalog.frames(for: descriptor.id)
                runner.renderedFrames = frames.images.count
                runner.pixelWidth = frames.images.first?.width ?? 0
                runner.pixelHeight = frames.images.first?.height ?? 0
            } catch {
                runner.error = error.localizedDescription
            }
            return runner
        }
    }

    @MainActor
    private static func settingsRoundTrip() -> Bool {
        guard let defaults = UserDefaults(suiteName: settingsSuite) else { return false }
        defaults.removePersistentDomain(forName: settingsSuite)
        defer { defaults.removePersistentDomain(forName: settingsSuite) }

        let first = SettingsStore(defaults: defaults)
        first.settings.runnerID = "gorunner.smoketest"
        first.settings.invertSpeed = true
        first.settings.fpsMaxLimit = .fps20
        first.settings.monitorNetwork = false
        first.settings.updateIntervalSeconds = 10
        first.settings.quota.bedrockModelIDs = ["anthropic.claude-test", "amazon.nova-test"]
        first.save()

        let second = SettingsStore(defaults: defaults)
        return second.settings == first.settings && second.settings != AppSettings()
    }
}
