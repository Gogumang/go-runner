import Network
import GoRunnerCore
import XCTest
@testable import SystemMetrics

final class CPUMathTests: XCTestCase {
    func testDeltaMath() throws {
        let previous = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
        let current = CPUTicks(user: 160, system: 70, idle: 900, nice: 70)  // Δ 60, 20, 100, 20 → total 200
        let info = try XCTUnwrap(CPUMath.info(previous: previous, current: current))
        XCTAssertEqual(info.usage, 0.4, accuracy: 1e-9)
        XCTAssertEqual(info.user, 0.3, accuracy: 1e-9)
        XCTAssertEqual(info.system, 0.1, accuracy: 1e-9)
        XCTAssertEqual(info.idle, 0.5, accuracy: 1e-9)
    }

    func testUInt32Wraparound() throws {
        let previous = CPUTicks(user: UInt32.max - 9, system: UInt32.max, idle: 10, nice: 0)
        let current = CPUTicks(user: 10, system: 19, idle: 70, nice: 0)  // Δ 20, 20, 60
        let info = try XCTUnwrap(CPUMath.info(previous: previous, current: current))
        XCTAssertEqual(info.user, 0.2, accuracy: 1e-9)
        XCTAssertEqual(info.system, 0.2, accuracy: 1e-9)
        XCTAssertEqual(info.idle, 0.6, accuracy: 1e-9)
        XCTAssertEqual(info.usage, 0.4, accuracy: 1e-9)
    }

    func testClampAndNoTicks() throws {
        let ticks = CPUTicks(user: 1, system: 1, idle: 1, nice: 1)
        XCTAssertNil(CPUMath.info(previous: ticks, current: ticks))
        let busy = try XCTUnwrap(CPUMath.info(previous: ticks, current: CPUTicks(user: 51, system: 51, idle: 1, nice: 1)))
        XCTAssertEqual(busy.usage, 0.999)
        XCTAssertEqual(busy.idle, 0)
    }
}

final class MemoryMathTests: XCTestCase {
    func testFormulaWithFixedPages() throws {
        let pages = VMPageCounts(active: 100, inactive: 50, speculative: 10, wired: 40,
                                 compressed: 20, purgeable: 5, external: 15)
        let page: UInt64 = 16384
        let info = try XCTUnwrap(MemoryMath.info(pages: pages, pageSize: page, physicalBytes: 1000 * page))
        // cached 20, app 140, pressure 60 → usage 200/1000
        XCTAssertEqual(info.usage, 0.2, accuracy: 1e-12)
        XCTAssertEqual(info.pressure, 0.06, accuracy: 1e-12)
        XCTAssertEqual(info.appBytes, 140 * 16384)
        XCTAssertEqual(info.wiredBytes, 40 * 16384)
        XCTAssertEqual(info.compressedBytes, 20 * 16384)
        XCTAssertEqual(info.physicalBytes, 1000 * 16384)
    }

    func testUsageClampAndInvalidInput() throws {
        let pages = VMPageCounts(active: 900, inactive: 0, speculative: 0, wired: 200,
                                 compressed: 100, purgeable: 0, external: 0)
        let info = try XCTUnwrap(MemoryMath.info(pages: pages, pageSize: 4096, physicalBytes: 1000 * 4096))
        XCTAssertEqual(info.usage, 0.999)
        XCTAssertNil(MemoryMath.info(pages: pages, pageSize: 4096, physicalBytes: 0))
    }
}

final class StorageMathTests: XCTestCase {
    func testPrefersImportantUsage() {
        XCTAssertEqual(StorageMath.availableBytes(important: 500, regular: 300), 500)
        XCTAssertEqual(StorageMath.availableBytes(important: 200, regular: 300), 200)
    }

    func testFallbackWhenImportantIsZeroOrMissing() {
        XCTAssertEqual(StorageMath.availableBytes(important: 0, regular: 300), 300)
        XCTAssertEqual(StorageMath.availableBytes(important: nil, regular: 300), 300)
        XCTAssertEqual(StorageMath.availableBytes(important: 0, regular: nil), 0)
        XCTAssertNil(StorageMath.availableBytes(important: nil, regular: nil))
    }
}

final class NetworkMathTests: XCTestCase {
    func testRateUsesElapsedTime() {
        let previous = NetworkCounters(inBytes: 1_000, outBytes: 500)
        let current = NetworkCounters(inBytes: 3_000, outBytes: 1_500)
        let rates = NetworkMath.rates(previous: previous, current: current, elapsedSeconds: 2)
        XCTAssertEqual(rates.download, 1_000)
        XCTAssertEqual(rates.upload, 500)
        let slow = NetworkMath.rates(previous: previous, current: current, elapsedSeconds: 0.5)
        XCTAssertEqual(slow.download, 4_000)
    }

    func testCounterResetIsNil() {
        let previous = NetworkCounters(inBytes: 10_000, outBytes: 500)
        let current = NetworkCounters(inBytes: 200, outBytes: 700)
        let rates = NetworkMath.rates(previous: previous, current: current, elapsedSeconds: 1)
        XCTAssertNil(rates.download)
        XCTAssertEqual(rates.upload, 200)
        let zero = NetworkMath.rates(previous: previous, current: previous, elapsedSeconds: 0)
        XCTAssertNil(zero.download)
        XCTAssertNil(zero.upload)
    }

    func testConnectionTypeMapping() {
        XCTAssertEqual(NetworkMath.connectionType(isSatisfied: false, usesInterfaceType: { _ in true }), NetworkConnectionType.none)
        XCTAssertEqual(NetworkMath.connectionType(isSatisfied: true, usesInterfaceType: { $0 == .wifi }), .wifi)
        XCTAssertEqual(NetworkMath.connectionType(isSatisfied: true, usesInterfaceType: { $0 == .wiredEthernet }), .ethernet)
        XCTAssertEqual(NetworkMath.connectionType(isSatisfied: true, usesInterfaceType: { $0 == .cellular }), .cellular)
        XCTAssertEqual(NetworkMath.connectionType(isSatisfied: true, usesInterfaceType: { $0 == .loopback }), .loopback)
        XCTAssertEqual(NetworkMath.connectionType(isSatisfied: true, usesInterfaceType: { _ in false }), .other)
    }

    func testLiveCountersAreReadable() {
        XCTAssertNotNil(NetworkSampler().readCounters())
    }
}

final class BatteryParserTests: XCTestCase {
    func testBatteryDataLayout() throws {
        let dict: [String: Any] = [
            "BatteryInstalled": true,
            "IsCharging": true,
            "ExternalConnected": true,
            "CycleCount": 120,
            "AdapterDetails": ["Name": "140W USB-C Power Adapter", "Watts": 140],
            "BatteryData": ["CurrentCapacity": 87, "FullChargeCapacity": 4500, "DesignCapacity": 5000] as [String: Any],
        ]
        let pack: [String: Any] = ["BatteryData": ["Temperature": 3150]]
        let info = BatteryParser.parse(battery: dict, pack: pack)
        XCTAssertTrue(info.isInstalled)
        XCTAssertEqual(try XCTUnwrap(info.percentage), 0.87, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(info.maxCapacity), 0.9, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(info.temperatureCelsius), 31.5, accuracy: 1e-9)
        XCTAssertTrue(info.isCharging)
        XCTAssertTrue(info.isExternalPowerConnected)
        XCTAssertEqual(info.cycleCount, 120)
        XCTAssertEqual(info.adapterName, "140W USB-C Power Adapter")
        XCTAssertTrue(BatteryParser.needsPackTemperature(dict))
    }

    func testLegacyLayout() throws {
        // Mirrors this MacBook on macOS 15.6 (ioreg AppleSmartBattery), as bridged NSNumbers.
        let dict: [String: Any] = [
            "BatteryInstalled": NSNumber(value: true),
            "CurrentCapacity": NSNumber(value: 93),
            "MaxCapacity": NSNumber(value: 100),
            "AppleRawMaxCapacity": NSNumber(value: 8232),
            "DesignCapacity": NSNumber(value: 8579),
            "Temperature": NSNumber(value: 3076),
            "IsCharging": NSNumber(value: false),
            "ExternalConnected": NSNumber(value: false),
            "CycleCount": NSNumber(value: 89),
            "AdapterDetails": ["FamilyCode": 0],
            "BatteryData": ["DesignCapacity": 8579],
        ]
        let info = BatteryParser.parse(battery: dict, pack: nil)
        XCTAssertTrue(info.isInstalled)
        XCTAssertEqual(try XCTUnwrap(info.percentage), 0.93, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(info.maxCapacity), 8232.0 / 8579.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(info.temperatureCelsius), 30.76, accuracy: 1e-9)
        XCTAssertFalse(info.isCharging)
        XCTAssertFalse(info.isExternalPowerConnected)
        XCTAssertNil(info.adapterName)
        XCTAssertEqual(info.cycleCount, 89)
        XCTAssertFalse(BatteryParser.needsPackTemperature(dict))
    }

    func testLegacyRawPercentSanityAndWattsAdapter() throws {
        // MaxCapacity smaller than CurrentCapacity → CurrentCapacity is a raw percent.
        let dict: [String: Any] = [
            "BatteryInstalled": 1,
            "CurrentCapacity": 80,
            "MaxCapacity": 50,
            "ExternalConnected": 1,
            "AdapterDetails": ["Watts": 65],
        ]
        let info = BatteryParser.parse(battery: dict, pack: nil)
        XCTAssertEqual(try XCTUnwrap(info.percentage), 0.8, accuracy: 1e-9)
        XCTAssertEqual(info.adapterName, Loc.t("65W 전원 어댑터", "65W Power Adapter"))
        XCTAssertNil(info.temperatureCelsius)
    }

    func testNotInstalled() {
        XCTAssertEqual(BatteryParser.parse(battery: ["BatteryInstalled": false, "CurrentCapacity": 50], pack: nil),
                       BatteryInfo(isInstalled: false))
        XCTAssertEqual(BatteryParser.parse(battery: [:], pack: nil), BatteryInfo(isInstalled: false))
    }
}
