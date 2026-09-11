import Darwin

/// Runs `body` with a `mach_host_self()` send right and deallocates it afterwards
/// (every call to `mach_host_self()` adds a user reference to the port).
@inline(__always)
func withHostPort<R>(_ body: (host_t) -> R) -> R {
    let host = mach_host_self()
    defer { _ = mach_port_deallocate(mach_task_self_, host) }
    return body(host)
}

enum MonotonicClock {
    /// Nanoseconds on a monotonic clock that keeps counting during sleep.
    @inline(__always)
    static func nanoseconds() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    @inline(__always)
    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? Double(end - start) / 1_000_000_000 : 0
    }
}
