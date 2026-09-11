import ApplicationServices
import Foundation
import GoRunnerCore

// Encodable DTOs for the smoke-test JSON. Wrappers (instead of Encodable extensions on Core types) so a later
// Codable conformance in GoRunnerCore can't conflict. Optional values are encoded as explicit nulls.

struct SmokeReport: Encodable {
    var ok: Bool
    var version: String
    var metrics: SmokeMetrics
    var speedCurve: SmokeSpeedCurve
    var runners: [SmokeRunner]
    var providers: [SmokeProvider]
    var settingsRoundTrip: Bool
    var uninstallPlan: [String]
    var agentHooks: SmokeAgentHooks
    var slack: SmokeSlack
}

/// `"slack": {"installed": bool, "accessibilityTrusted": bool}`. Read-only: `AXIsProcessTrusted()` never prompts.
struct SmokeSlack: Encodable {
    var installed: Bool
    var accessibilityTrusted: Bool

    init() {
        installed = SlackDockBadgeReader.isSlackInstalled
        accessibilityTrusted = AXIsProcessTrusted()
    }
}

/// `"agentHooks": {"claude": {"present": bool, "installed": bool}, "codex": {…}}`
struct SmokeAgentHooks: Encodable {
    struct Hook: Encodable {
        var present: Bool
        var installed: Bool
    }

    var claude: Hook
    var codex: Hook

    init(_ hooks: AgentHooks) {
        claude = Hook(present: hooks.isToolPresent(.claude), installed: hooks.isInstalled(.claude))
        codex = Hook(present: hooks.isToolPresent(.codex), installed: hooks.isInstalled(.codex))
    }
}

struct SmokeSpeedCurve: Encodable {
    var cpu0: Double
    var cpu50: Double
    var cpu100: Double
}

struct SmokeMetrics: Encodable {
    let snapshot: SystemSnapshot

    init(_ snapshot: SystemSnapshot) { self.snapshot = snapshot }

    private enum Keys: String, CodingKey { case date, cpu, memory, storage, battery, network }
    private enum CPUKeys: String, CodingKey { case usage, system, user, idle }
    private enum MemoryKeys: String, CodingKey { case usage, pressure, appBytes, wiredBytes, compressedBytes, physicalBytes }
    private enum StorageKeys: String, CodingKey { case totalBytes, availableBytes, usedBytes, usage }
    private enum BatteryKeys: String, CodingKey {
        case isInstalled, percentage, isCharging, isExternalPowerConnected, adapterName, maxCapacity, cycleCount, temperatureCelsius
    }
    private enum NetworkKeys: String, CodingKey { case connection, interfaceName, localIP, uploadBytesPerSecond, downloadBytesPerSecond }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(snapshot.date, forKey: .date)

        var cpu = c.nestedContainer(keyedBy: CPUKeys.self, forKey: .cpu)
        try cpu.encode(snapshot.cpu.usage, forKey: .usage)
        try cpu.encode(snapshot.cpu.system, forKey: .system)
        try cpu.encode(snapshot.cpu.user, forKey: .user)
        try cpu.encode(snapshot.cpu.idle, forKey: .idle)

        if let memory = snapshot.memory {
            var m = c.nestedContainer(keyedBy: MemoryKeys.self, forKey: .memory)
            try m.encode(memory.usage, forKey: .usage)
            try m.encode(memory.pressure, forKey: .pressure)
            try m.encode(memory.appBytes, forKey: .appBytes)
            try m.encode(memory.wiredBytes, forKey: .wiredBytes)
            try m.encode(memory.compressedBytes, forKey: .compressedBytes)
            try m.encode(memory.physicalBytes, forKey: .physicalBytes)
        } else {
            try c.encodeNil(forKey: .memory)
        }

        if let storage = snapshot.storage {
            var s = c.nestedContainer(keyedBy: StorageKeys.self, forKey: .storage)
            try s.encode(storage.totalBytes, forKey: .totalBytes)
            try s.encode(storage.availableBytes, forKey: .availableBytes)
            try s.encode(storage.usedBytes, forKey: .usedBytes)
            try s.encode(storage.usage, forKey: .usage)
        } else {
            try c.encodeNil(forKey: .storage)
        }

        if let battery = snapshot.battery {
            var b = c.nestedContainer(keyedBy: BatteryKeys.self, forKey: .battery)
            try b.encode(battery.isInstalled, forKey: .isInstalled)
            try b.encode(battery.percentage, forKey: .percentage)
            try b.encode(battery.isCharging, forKey: .isCharging)
            try b.encode(battery.isExternalPowerConnected, forKey: .isExternalPowerConnected)
            try b.encode(battery.adapterName, forKey: .adapterName)
            try b.encode(battery.maxCapacity, forKey: .maxCapacity)
            try b.encode(battery.cycleCount, forKey: .cycleCount)
            try b.encode(battery.temperatureCelsius, forKey: .temperatureCelsius)
        } else {
            try c.encodeNil(forKey: .battery)
        }

        if let network = snapshot.network {
            var n = c.nestedContainer(keyedBy: NetworkKeys.self, forKey: .network)
            try n.encode(network.connection.rawValue, forKey: .connection)
            try n.encode(network.interfaceName, forKey: .interfaceName)
            try n.encode(network.localIP, forKey: .localIP)
            try n.encode(network.uploadBytesPerSecond, forKey: .uploadBytesPerSecond)
            try n.encode(network.downloadBytesPerSecond, forKey: .downloadBytesPerSecond)
        } else {
            try c.encodeNil(forKey: .network)
        }
    }
}

struct SmokeRunner: Encodable {
    var id: String
    var name: String
    var source: String
    var isTemplate: Bool
    var frameCount: Int
    var renderedFrames = 0
    var pixelWidth = 0
    var pixelHeight = 0
    var license: String
    var credit: String?
    var isBrandInspired: Bool
    var error: String?

    init(_ descriptor: RunnerDescriptor) {
        id = descriptor.id
        name = descriptor.displayName
        switch descriptor.source {
        case .builtIn: source = "builtIn"
        }
        isTemplate = descriptor.isTemplate
        frameCount = descriptor.frameCount
        license = descriptor.license
        credit = descriptor.credit
        isBrandInspired = descriptor.isBrandInspired
    }

    private enum Keys: String, CodingKey {
        case id, name, source, isTemplate, frameCount, renderedFrames, pixelWidth, pixelHeight, license, credit, isBrandInspired, error
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(source, forKey: .source)
        try c.encode(isTemplate, forKey: .isTemplate)
        try c.encode(frameCount, forKey: .frameCount)
        try c.encode(renderedFrames, forKey: .renderedFrames)
        try c.encode(pixelWidth, forKey: .pixelWidth)
        try c.encode(pixelHeight, forKey: .pixelHeight)
        try c.encode(license, forKey: .license)
        try c.encode(credit, forKey: .credit)
        try c.encode(isBrandInspired, forKey: .isBrandInspired)
        try c.encodeIfPresent(error, forKey: .error)
    }
}

struct SmokeProvider: Encodable {
    let report: ProviderReport

    init(_ report: ProviderReport) { self.report = report }

    private enum Keys: String, CodingKey { case provider, snapshot, error, attempts }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(report.provider, forKey: .provider)
        try c.encode(report.snapshot, forKey: .snapshot)
        try c.encode(report.error, forKey: .error)
        try c.encode(report.attempts, forKey: .attempts)
    }
}
