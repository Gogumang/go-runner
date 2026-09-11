// Metric formulas adapted from Kyome22/SystemInfoKit (Apache-2.0)
// https://github.com/Kyome22/SystemInfoKit — Sources/SystemInfoKit/Repositories/MemoryRepository.swift
import Darwin
import Foundation
import GoRunnerCore

/// Page counts from `HOST_VM_INFO64`.
struct VMPageCounts: Equatable {
    var active: UInt64
    var inactive: UInt64
    var speculative: UInt64
    var wired: UInt64
    var compressed: UInt64
    var purgeable: UInt64
    var external: UInt64
}

enum MemoryMath {
    /// cached = purgeable + external; app = active + inactive + speculative − cached;
    /// pressure = wired + compressed; usage = min((app + pressure)·page / max_mem, 0.999).
    static func info(pages: VMPageCounts, pageSize: UInt64, physicalBytes: UInt64) -> MemoryInfo? {
        guard pageSize > 0, physicalBytes > 0 else { return nil }
        let page = Double(pageSize)
        let physical = Double(physicalBytes)
        let cached = Double(pages.purgeable) + Double(pages.external)
        // Clamped at 0: purgeable/external can briefly exceed the anonymous page counts.
        let app = max(0, Double(pages.active) + Double(pages.inactive) + Double(pages.speculative) - cached)
        let pressure = Double(pages.wired) + Double(pages.compressed)
        return MemoryInfo(
            usage: max(0, min((app + pressure) * page / physical, 0.999)),
            pressure: pressure * page / physical,
            appBytes: app * page,
            wiredBytes: Double(pages.wired) * page,
            compressedBytes: Double(pages.compressed) * page,
            physicalBytes: physical
        )
    }
}

/// Not thread-safe; `SystemMonitor` serializes access. Page size and physical memory are read once.
final class MemorySampler {
    private lazy var pageSize: UInt64 = Self.readPageSize()
    private lazy var physicalBytes: UInt64 = Self.readMaxMemory()

    func sample() -> MemoryInfo? {
        guard let pages = Self.readPageCounts() else { return nil }
        return MemoryMath.info(pages: pages, pageSize: pageSize, physicalBytes: physicalBytes)
    }

    static func readPageCounts() -> VMPageCounts? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { raw in
                withHostPort { host_statistics64($0, HOST_VM_INFO64, raw, &count) }
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMPageCounts(
            active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count),
            speculative: UInt64(stats.speculative_count),
            wired: UInt64(stats.wire_count),
            compressed: UInt64(stats.compressor_page_count),
            purgeable: UInt64(stats.purgeable_count),
            external: UInt64(stats.external_page_count)
        )
    }

    static func readPageSize() -> UInt64 {
        var size: vm_size_t = 0
        let result = withHostPort { host_page_size($0, &size) }
        return result == KERN_SUCCESS && size > 0 ? UInt64(size) : UInt64(vm_kernel_page_size)
    }

    static func readMaxMemory() -> UInt64 {
        var info = host_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_basic_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) { raw in
                withHostPort { host_info($0, HOST_BASIC_INFO, raw, &count) }
            }
        }
        if result == KERN_SUCCESS, info.max_mem > 0 { return info.max_mem }
        return ProcessInfo.processInfo.physicalMemory
    }
}
