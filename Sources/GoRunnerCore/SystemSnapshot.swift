import Foundation

// MARK: - Metric models (fractions are 0...1, byte counts are Double bytes)

public struct CPUInfo: Sendable, Equatable {
    /// (Δuser + Δsystem) / Σticks, clamped to 0.999 (SystemInfoKit semantics).
    public var usage: Double
    public var system: Double
    public var user: Double
    public var idle: Double

    public init(usage: Double, system: Double, user: Double, idle: Double) {
        self.usage = usage
        self.system = system
        self.user = user
        self.idle = idle
    }
}

public struct MemoryInfo: Sendable, Equatable {
    /// (app + wired + compressed) / physical, clamped to 0.999.
    public var usage: Double
    /// (wired + compressed) / physical. A ratio, not the kernel pressure level.
    public var pressure: Double
    public var appBytes: Double
    public var wiredBytes: Double
    public var compressedBytes: Double
    public var physicalBytes: Double

    public init(usage: Double, pressure: Double, appBytes: Double, wiredBytes: Double, compressedBytes: Double, physicalBytes: Double) {
        self.usage = usage
        self.pressure = pressure
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.physicalBytes = physicalBytes
    }
}

public struct StorageInfo: Sendable, Equatable {
    public var totalBytes: Double
    public var availableBytes: Double

    public init(totalBytes: Double, availableBytes: Double) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedBytes: Double { max(0, totalBytes - availableBytes) }
    public var usage: Double { totalBytes > 0 ? min(usedBytes / totalBytes, 0.999) : 0 }
}

public struct BatteryInfo: Sendable, Equatable {
    public var isInstalled: Bool
    /// 0...1
    public var percentage: Double?
    public var isCharging: Bool
    public var isExternalPowerConnected: Bool
    /// e.g. "140W USB-C Power Adapter"; nil when on battery.
    public var adapterName: String?
    /// 0...1
    public var maxCapacity: Double?
    public var cycleCount: Int?
    public var temperatureCelsius: Double?

    public init(isInstalled: Bool, percentage: Double? = nil, isCharging: Bool = false, isExternalPowerConnected: Bool = false,
                adapterName: String? = nil, maxCapacity: Double? = nil, cycleCount: Int? = nil, temperatureCelsius: Double? = nil) {
        self.isInstalled = isInstalled
        self.percentage = percentage
        self.isCharging = isCharging
        self.isExternalPowerConnected = isExternalPowerConnected
        self.adapterName = adapterName
        self.maxCapacity = maxCapacity
        self.cycleCount = cycleCount
        self.temperatureCelsius = temperatureCelsius
    }
}

public enum NetworkConnectionType: String, Sendable, Equatable, Codable {
    case wifi, ethernet, cellular, loopback, other, none
}

public struct NetworkInfo: Sendable, Equatable {
    public var connection: NetworkConnectionType
    public var interfaceName: String?
    public var localIP: String?
    public var uploadBytesPerSecond: Double?
    public var downloadBytesPerSecond: Double?

    public init(connection: NetworkConnectionType, interfaceName: String? = nil, localIP: String? = nil,
                uploadBytesPerSecond: Double? = nil, downloadBytesPerSecond: Double? = nil) {
        self.connection = connection
        self.interfaceName = interfaceName
        self.localIP = localIP
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
    }
}

public struct SystemSnapshot: Sendable, Equatable {
    public var date: Date
    public var cpu: CPUInfo
    public var memory: MemoryInfo?
    public var storage: StorageInfo?
    public var battery: BatteryInfo?
    public var network: NetworkInfo?

    public init(date: Date = Date(), cpu: CPUInfo, memory: MemoryInfo? = nil, storage: StorageInfo? = nil,
                battery: BatteryInfo? = nil, network: NetworkInfo? = nil) {
        self.date = date
        self.cpu = cpu
        self.memory = memory
        self.storage = storage
        self.battery = battery
        self.network = network
    }
}

// MARK: - Sampling contract (implemented by SystemMetrics.SystemMonitor)

public struct MetricsOptions: Sendable, Equatable {
    /// Seconds between samples (RunCat Neo offers 3 / 5 / 10, default 5). Minimum 1.
    public var interval: TimeInterval
    public var memory: Bool
    public var storage: Bool
    public var battery: Bool
    public var network: Bool

    public init(interval: TimeInterval = 5, memory: Bool = true, storage: Bool = true, battery: Bool = true, network: Bool = true) {
        self.interval = interval
        self.memory = memory
        self.storage = storage
        self.battery = battery
        self.network = network
    }
}

public protocol SystemMetricsProviding: AnyObject {
    /// Starts periodic sampling. Emits one snapshot immediately, then every `options.interval`.
    /// `onUpdate` is called on the main queue.
    func start(options: MetricsOptions, onUpdate: @escaping (SystemSnapshot) -> Void)
    /// Changes interval / enabled metrics without losing CPU and network deltas.
    func update(options: MetricsOptions)
    /// Stops sampling (used on sleep). `start` may be called again.
    func stop()
    /// Takes one synchronous sample using the current options (used by --smoke-test).
    func sampleNow() -> SystemSnapshot
}
