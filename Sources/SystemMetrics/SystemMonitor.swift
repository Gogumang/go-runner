import Darwin
import Foundation
import GoRunnerCore

// FACADE — the public API below is a contract used by GoRunnerApp. Keep these signatures; add more if needed.

public final class SystemMonitor: SystemMetricsProviding, @unchecked Sendable {
    /// Minimum time between the CPU baseline and a sample, so the first delta is meaningful.
    static let warmupSeconds: Double = 0.25

    private let queue = DispatchQueue(label: "GoRunner.SystemMetrics.sampler", qos: .utility)
    private let path = NetworkPathObserver()

    // Everything below is guarded by `lock`.
    private let lock = NSLock()
    private var options = MetricsOptions()
    private var timer: DispatchSourceTimer?
    private var onUpdate: ((SystemSnapshot) -> Void)?
    private var generation = 0
    private let cpu = CPUSampler()          // baseline taken here
    private let memory = MemorySampler()
    private let network = NetworkSampler()  // counter baseline taken here

    public init() {}

    deinit {
        timer?.cancel()
        path.stop()
    }

    public func start(options: MetricsOptions, onUpdate: @escaping (SystemSnapshot) -> Void) {
        lock.lock()
        timer?.cancel()
        generation &+= 1
        let token = generation
        self.options = options
        self.onUpdate = onUpdate

        let interval = Self.clampedInterval(options.interval)
        // After a long pause (e.g. stop on sleep), start fresh instead of averaging over the gap.
        let now = MonotonicClock.nanoseconds()
        if MonotonicClock.seconds(from: cpu.lastReadNanos, to: now) > max(2 * interval, 10) {
            cpu.rebaseline()
            network.rebaseline()
        }
        if options.network { path.start() } else { path.stop() }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + cpu.remainingWarmup(minimum: Self.warmupSeconds),
                        repeating: interval, leeway: Self.leeway(for: interval))
        source.setEventHandler { [weak self] in self?.tick(token: token) }
        timer = source
        lock.unlock()
        source.resume()
    }

    public func update(options newOptions: MetricsOptions) {
        lock.lock()
        defer { lock.unlock() }
        let old = options
        options = newOptions
        if !old.network, newOptions.network {
            network.rebaseline()
        }
        guard let timer else { return }
        let interval = Self.clampedInterval(newOptions.interval)
        if interval != Self.clampedInterval(old.interval) {
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: Self.leeway(for: interval))
        }
        if newOptions.network { path.start() } else { path.stop() }
    }

    public func stop() {
        lock.lock()
        generation &+= 1
        timer?.cancel()
        timer = nil
        onUpdate = nil
        path.stop()
        lock.unlock()
    }

    public func sampleNow() -> SystemSnapshot {
        lock.lock()
        let current = options
        if current.network { path.start() }
        let wait = cpu.remainingWarmup(minimum: Self.warmupSeconds)
        lock.unlock()

        if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        if current.network { path.waitForFirstPath(timeout: 0.3) }

        lock.lock()
        let snapshot = sampleLocked(options: current)
        if timer == nil, current.network { path.stop() }  // only keep the path monitor while monitoring
        lock.unlock()
        return snapshot
    }

    // MARK: - Private

    private func tick(token: Int) {
        lock.lock()
        guard token == generation else { lock.unlock(); return }
        let waitForPath = options.network
        lock.unlock()

        if waitForPath { path.waitForFirstPath(timeout: Self.warmupSeconds) }

        lock.lock()
        guard token == generation, let callback = onUpdate else { lock.unlock(); return }
        let snapshot = sampleLocked(options: options)
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            callback(snapshot)
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == generation
    }

    /// Caller must hold `lock`. CPU is always sampled; disabled metrics are nil.
    private func sampleLocked(options: MetricsOptions) -> SystemSnapshot {
        SystemSnapshot(
            date: Date(),
            cpu: cpu.sample(),
            memory: options.memory ? memory.sample() : nil,
            storage: options.storage ? StorageSampler.sample() : nil,
            battery: options.battery ? BatterySampler.sample() : nil,
            network: options.network ? network.sample(path: path.current) : nil
        )
    }

    static func clampedInterval(_ interval: TimeInterval) -> TimeInterval {
        interval.isFinite ? max(interval, 1) : 5
    }

    private static func leeway(for interval: TimeInterval) -> DispatchTimeInterval {
        .milliseconds(Int(min(interval * 0.1, 0.5) * 1000))
    }
}
