// Metric formulas adapted from Kyome22/SystemInfoKit (Apache-2.0)
// https://github.com/Kyome22/SystemInfoKit — Sources/SystemInfoKit/Repositories/CPURepository.swift
import Darwin
import GoRunnerCore

/// Cumulative `HOST_CPU_LOAD_INFO` ticks (all CPUs).
struct CPUTicks: Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

enum CPUMath {
    /// `usage = (Δuser + Δsystem) / (Δuser + Δsystem + Δidle + Δnice)`, clamped to 0.999.
    /// Uses wrapping subtraction so a UInt32 counter wrap yields the right delta.
    /// Returns nil when no ticks elapsed.
    static func info(previous: CPUTicks, current: CPUTicks) -> CPUInfo? {
        let user = Double(current.user &- previous.user)
        let system = Double(current.system &- previous.system)
        let idle = Double(current.idle &- previous.idle)
        let nice = Double(current.nice &- previous.nice)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        let systemFraction = system / total
        let userFraction = user / total
        return CPUInfo(
            usage: min(systemFraction + userFraction, 0.999),
            system: systemFraction,
            user: userFraction,
            idle: idle / total
        )
    }
}

/// Not thread-safe; `SystemMonitor` serializes access.
final class CPUSampler {
    private var previous: CPUTicks?
    private(set) var lastReadNanos: UInt64 = 0
    private var last = CPUInfo(usage: 0, system: 0, user: 0, idle: 1)

    init() {
        rebaseline()
    }

    /// Records the current ticks so the next `sample()` is a real delta.
    func rebaseline() {
        previous = Self.readTicks()
        lastReadNanos = MonotonicClock.nanoseconds()
    }

    /// Seconds still needed until `minimum` has elapsed since the last tick reading.
    func remainingWarmup(minimum: Double, now: UInt64 = MonotonicClock.nanoseconds()) -> Double {
        max(0, minimum - MonotonicClock.seconds(from: lastReadNanos, to: now))
    }

    func sample() -> CPUInfo {
        guard let current = Self.readTicks() else { return last }
        let now = MonotonicClock.nanoseconds()
        guard let previous else {
            self.previous = current
            lastReadNanos = now
            return last
        }
        // Keep the old baseline when no tick elapsed, so the next call still gets a delta.
        if let info = CPUMath.info(previous: previous, current: current) {
            last = info
            self.previous = current
            lastReadNanos = now
        }
        return last
    }

    static func readTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { raw in
                withHostPort { host_statistics64($0, HOST_CPU_LOAD_INFO, raw, &count) }
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks order: CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE
        return CPUTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }
}
