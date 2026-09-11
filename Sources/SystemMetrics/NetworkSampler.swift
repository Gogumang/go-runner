// Metric formulas adapted from Kyome22/SystemInfoKit (Apache-2.0)
// https://github.com/Kyome22/SystemInfoKit — Sources/SystemInfoKit/Repositories/NetworkRepository.swift
// Changes: 64-bit counters via sysctl NET_RT_IFLIST2, loopback excluded, rates use measured elapsed time.
import Darwin
import Foundation
import Network
import GoRunnerCore

struct NetworkCounters: Equatable {
    var inBytes: UInt64
    var outBytes: UInt64
}

enum NetworkMath {
    /// Bytes/second over the measured elapsed time. A counter that went backwards (reset,
    /// interface removed) yields nil for that direction.
    static func rates(previous: NetworkCounters, current: NetworkCounters, elapsedSeconds: Double)
        -> (upload: Double?, download: Double?)
    {
        guard elapsedSeconds > 0, elapsedSeconds.isFinite else { return (nil, nil) }
        let upload = current.outBytes >= previous.outBytes
            ? Double(current.outBytes - previous.outBytes) / elapsedSeconds : nil
        let download = current.inBytes >= previous.inBytes
            ? Double(current.inBytes - previous.inBytes) / elapsedSeconds : nil
        return (upload, download)
    }

    static func connectionType(isSatisfied: Bool, usesInterfaceType: (NWInterface.InterfaceType) -> Bool)
        -> NetworkConnectionType
    {
        guard isSatisfied else { return .none }
        if usesInterfaceType(.wifi) { return .wifi }
        if usesInterfaceType(.wiredEthernet) { return .ethernet }
        if usesInterfaceType(.cellular) { return .cellular }
        if usesInterfaceType(.loopback) { return .loopback }
        return .other
    }

    /// Sums `if_data64` byte counters of every `RTM_IFINFO2` record, skipping loopback interfaces.
    static func sumCounters(_ buffer: UnsafeRawBufferPointer) -> NetworkCounters {
        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0
        let message2Size = MemoryLayout<if_msghdr2>.size
        var offset = 0
        // Every routing message starts with u_short msglen, u_char version, u_char type.
        while offset + 4 <= buffer.count {
            let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard length > 0 else { break }
            let type = Int32(buffer.load(fromByteOffset: offset + 3, as: UInt8.self))
            if type == RTM_IFINFO2, offset + message2Size <= buffer.count {
                let message = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                if message.ifm_flags & IFF_LOOPBACK == 0 {
                    inBytes &+= message.ifm_data.ifi_ibytes
                    outBytes &+= message.ifm_data.ifi_obytes
                }
            }
            offset += length
        }
        return NetworkCounters(inBytes: inBytes, outBytes: outBytes)
    }
}

/// Not thread-safe; `SystemMonitor` serializes access. Reuses one sysctl buffer.
final class NetworkSampler {
    private var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    private var buffer: UnsafeMutableRawPointer
    private var capacity: Int
    private var previous: NetworkCounters?
    private var previousNanos: UInt64 = 0

    init() {
        capacity = 32 * 1024
        buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        rebaseline()
    }

    deinit {
        buffer.deallocate()
    }

    func rebaseline() {
        previous = readCounters()
        previousNanos = MonotonicClock.nanoseconds()
    }

    func sample(path: NetworkPathObserver.PathState?) -> NetworkInfo {
        var info = NetworkInfo(connection: path?.connection ?? .none, interfaceName: path?.interfaceName)
        if let name = path?.interfaceName {
            info.localIP = Self.ipv4Address(interface: name)
        }
        let now = MonotonicClock.nanoseconds()
        if let current = readCounters() {
            if let previous {
                let rates = NetworkMath.rates(previous: previous, current: current,
                                              elapsedSeconds: MonotonicClock.seconds(from: previousNanos, to: now))
                info.uploadBytesPerSecond = rates.upload
                info.downloadBytesPerSecond = rates.download
            }
            previous = current
            previousNanos = now
        }
        return info
    }

    func readCounters() -> NetworkCounters? {
        var length = capacity
        if sysctlCall(buffer, &length) != 0 {
            guard errno == ENOMEM else { return nil }
            var needed = 0
            guard sysctlCall(nil, &needed) == 0, needed > 0 else { return nil }
            buffer.deallocate()
            capacity = needed + needed / 2
            buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
            length = capacity
            guard sysctlCall(buffer, &length) == 0 else { return nil }
        }
        return NetworkMath.sumCounters(UnsafeRawBufferPointer(start: buffer, count: length))
    }

    private func sysctlCall(_ output: UnsafeMutableRawPointer?, _ length: inout Int) -> Int32 {
        let count = UInt32(mib.count)
        return mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, count, output, &length, nil, 0) }
    }

    /// IPv4 address of `interface` via getifaddrs + getnameinfo(NI_NUMERICHOST).
    static func ipv4Address(interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        return interface.withCString { name -> String? in
            var cursor = head
            while let entry = cursor {
                defer { cursor = entry.pointee.ifa_next }
                guard let address = entry.pointee.ifa_addr,
                      address.pointee.sa_family == UInt8(AF_INET),
                      strcmp(entry.pointee.ifa_name, name) == 0
                else { continue }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            return nil
        }
    }
}

/// Keeps an `NWPathMonitor` running on a utility queue and caches the latest path.
final class NetworkPathObserver: @unchecked Sendable {
    struct PathState: Equatable {
        var connection: NetworkConnectionType
        var interfaceName: String?
    }

    private let condition = NSCondition()
    private let queue = DispatchQueue(label: "GoRunner.SystemMetrics.path", qos: .utility)
    private var monitor: NWPathMonitor?
    private var latest: PathState?

    var isRunning: Bool {
        condition.lock()
        defer { condition.unlock() }
        return monitor != nil
    }

    var current: PathState? {
        condition.lock()
        defer { condition.unlock() }
        return latest
    }

    func start() {
        condition.lock()
        defer { condition.unlock() }
        guard monitor == nil else { return }
        let newMonitor = NWPathMonitor()
        newMonitor.pathUpdateHandler = { [weak self, weak newMonitor] path in
            guard let self else { return }
            let state = PathState(
                connection: NetworkMath.connectionType(isSatisfied: path.status == .satisfied,
                                                       usesInterfaceType: { path.usesInterfaceType($0) }),
                interfaceName: path.status == .satisfied ? path.availableInterfaces.first?.name : nil
            )
            self.condition.lock()
            if let newMonitor, self.monitor === newMonitor {
                self.latest = state
                self.condition.broadcast()
            }
            self.condition.unlock()
        }
        monitor = newMonitor
        latest = nil
        newMonitor.start(queue: queue)
    }

    func stop() {
        condition.lock()
        let old = monitor
        monitor = nil
        latest = nil
        condition.broadcast()
        condition.unlock()
        old?.cancel()
    }

    /// Blocks up to `timeout` seconds until the running monitor delivered its first path.
    func waitForFirstPath(timeout: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        while latest == nil, monitor != nil {
            if !condition.wait(until: deadline) { break }
        }
        condition.unlock()
    }

    deinit {
        monitor?.cancel()
    }
}
