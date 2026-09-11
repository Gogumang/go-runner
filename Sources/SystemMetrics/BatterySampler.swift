// Metric formulas adapted from Kyome22/SystemInfoKit (Apache-2.0)
// https://github.com/Kyome22/SystemInfoKit — Sources/SystemInfoKit/Repositories/BatteryRepository.swift
import Foundation
import IOKit
import GoRunnerCore

enum BatteryParser {
    /// Parses `AppleSmartBattery` registry properties. `pack` is the optional `AppleSmartBatteryPack`
    /// properties, only consulted for temperature when the top-level `Temperature` key is missing.
    static func parse(battery dict: [String: Any], pack: [String: Any]?) -> BatteryInfo {
        guard int(dict["BatteryInstalled"]) == 1 else { return BatteryInfo(isInstalled: false) }

        var info = BatteryInfo(isInstalled: true)
        let data = dict["BatteryData"] as? [String: Any]

        // Percentage: newer `BatteryData` layout first, then the legacy top-level keys.
        if let current = number(data?["CurrentCapacity"]) {
            info.percentage = fraction(current: current, maximum: 100)
        } else if let current = number(dict["CurrentCapacity"]) {
            info.percentage = fraction(current: current, maximum: number(dict["MaxCapacity"]))
        }

        // Max capacity (health).
        if let full = number(data?["FullChargeCapacity"]), let design = number(data?["DesignCapacity"]), design > 0 {
            info.maxCapacity = min(max(full / design, 0), 1)
        } else if let raw = number(dict["AppleRawMaxCapacity"]),
                  let design = number(dict["DesignCapacity"]) ?? number(data?["DesignCapacity"]), design > 0 {
            info.maxCapacity = min(max(raw / design, 0), 1)
        }

        let packData = pack?["BatteryData"] as? [String: Any]
        if let hundredths = number(dict["Temperature"]) ?? number(packData?["Temperature"]) ?? number(data?["Temperature"]) {
            info.temperatureCelsius = hundredths / 100
        }

        info.isCharging = int(dict["IsCharging"]) == 1
        info.isExternalPowerConnected = int(dict["ExternalConnected"]) == 1
        info.cycleCount = int(dict["CycleCount"]) ?? int(data?["CycleCount"])

        if info.isExternalPowerConnected {
            let adapter = dict["AdapterDetails"] as? [String: Any]
            if let name = adapter?["Name"] as? String, !name.isEmpty {
                info.adapterName = name
            } else if let watts = int(adapter?["Watts"]), watts > 0 {
                info.adapterName = Loc.t("\(watts)W 전원 어댑터", "\(watts)W Power Adapter")
            }
        }
        return info
    }

    static func needsPackTemperature(_ dict: [String: Any]) -> Bool {
        int(dict["BatteryInstalled"]) == 1 && number(dict["Temperature"]) == nil
    }

    /// `current / maximum`; if that exceeds 1, `CurrentCapacity` is treated as a raw percent.
    static func fraction(current: Double, maximum: Double?) -> Double? {
        var value = (maximum ?? 0) > 0 ? current / maximum! : current / 100
        if value > 1 { value = current / 100 }
        guard value.isFinite, value >= 0 else { return nil }
        return min(value, 1)
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let v as Int: return Double(v)
        case let v as Double: return v
        case let v as Bool: return v ? 1 : 0
        case let v as NSNumber: return v.doubleValue
        default: return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        number(value).flatMap { $0.isFinite ? Int($0) : nil }
    }
}

enum BatterySampler {
    static func sample() -> BatteryInfo {
        guard let battery = properties(serviceName: "AppleSmartBattery") else {
            return BatteryInfo(isInstalled: false)
        }
        let pack = BatteryParser.needsPackTemperature(battery) ? properties(serviceName: "AppleSmartBatteryPack") : nil
        return BatteryParser.parse(battery: battery, pack: pack)
    }

    static func properties(serviceName: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching(serviceName))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props
        else { return nil }
        return props.takeRetainedValue() as? [String: Any]
    }
}
