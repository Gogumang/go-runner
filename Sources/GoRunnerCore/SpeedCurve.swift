import Foundation

/// RunCat 365's "FPS Max Limit" option. `rate` scales the CPU-derived speed.
public enum FPSMaxLimit: String, CaseIterable, Codable, Sendable, Identifiable {
    case fps40, fps30, fps20, fps10

    public var id: String { rawValue }

    public var rate: Double {
        switch self {
        case .fps40: 1.0
        case .fps30: 0.75
        case .fps20: 0.5
        case .fps10: 0.25
        }
    }

    public var label: String {
        switch self {
        case .fps40: "40fps"
        case .fps30: "30fps"
        case .fps20: "20fps"
        case .fps10: "10fps"
        }
    }
}

/// The RunCat speed curve (Classic 12.x / RunCat Neo `RunnerService.updateRunnerSpeed`).
///
///     base  = clamp(cpu% / 5 × fpsRate, 1, 20)
///     speed = invert ? 0.5 × (21 − base) : base
///     frame = 0.5 s / speed        (CALayer.speed = speed, keyframe duration = frameCount / 2)
public enum SpeedCurve {
    /// Duration of one frame at speed 1.
    public static let baseFrameDuration: TimeInterval = 0.5

    /// - Parameter cpuUsage: CPU usage as a fraction in 0...1.
    public static func speed(cpuUsage: Double?, invert: Bool, fpsLimit: FPSMaxLimit = .fps40) -> Double {
        let percent = max(0, min(100, (cpuUsage ?? 0) * 100))
        let base = max(1.0, min(20.0, percent / 5.0 * fpsLimit.rate))
        return invert ? 0.5 * (21.0 - base) : base
    }

    public static func frameDuration(speed: Double) -> TimeInterval {
        baseFrameDuration / max(speed, 0.0001)
    }
}
