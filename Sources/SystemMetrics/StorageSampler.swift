// Metric formulas adapted from Kyome22/SystemInfoKit (Apache-2.0)
// https://github.com/Kyome22/SystemInfoKit — Sources/SystemInfoKit/Repositories/StorageRepository.swift
import Foundation
import GoRunnerCore

enum StorageMath {
    /// Prefers "available for important usage". That key can report 0 (or be missing) on some
    /// macOS/APFS combinations; then fall back to the plain available capacity, using the larger value.
    static func availableBytes(important: Int64?, regular: Int?) -> Double? {
        if let important, important > 0 { return Double(important) }
        guard let regular else { return important.map(Double.init) }
        return max(Double(important ?? 0), Double(regular))
    }
}

enum StorageSampler {
    private static let keys: Set<URLResourceKey> = [
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
    ]

    static func sample() -> StorageInfo? {
        // A fresh URL each time: URL instances cache resource values.
        let url = URL(fileURLWithPath: "/", isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0,
              let available = StorageMath.availableBytes(
                  important: values.volumeAvailableCapacityForImportantUsage,
                  regular: values.volumeAvailableCapacity
              )
        else { return nil }
        return StorageInfo(totalBytes: Double(total), availableBytes: min(available, Double(total)))
    }
}
