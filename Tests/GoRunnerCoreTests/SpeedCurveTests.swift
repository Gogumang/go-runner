import XCTest
@testable import GoRunnerCore

final class SpeedCurveTests: XCTestCase {
    // Values pinned by RunCat Neo's RunnerServiceTests.
    func testNeoParity() {
        XCTAssertEqual(SpeedCurve.speed(cpuUsage: 0.5, invert: false), 10, accuracy: 0.0001)
        XCTAssertEqual(SpeedCurve.speed(cpuUsage: nil, invert: false), 1, accuracy: 0.0001)
        XCTAssertEqual(SpeedCurve.speed(cpuUsage: 1.0, invert: false), 20, accuracy: 0.0001)
        XCTAssertEqual(SpeedCurve.speed(cpuUsage: 0.5, invert: true), 5.5, accuracy: 0.0001)
    }

    func testFrameDurations() {
        XCTAssertEqual(SpeedCurve.frameDuration(speed: SpeedCurve.speed(cpuUsage: 0.0, invert: false)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SpeedCurve.frameDuration(speed: SpeedCurve.speed(cpuUsage: 0.25, invert: false)), 0.1, accuracy: 0.0001)
        XCTAssertEqual(SpeedCurve.frameDuration(speed: SpeedCurve.speed(cpuUsage: 1.0, invert: false)), 0.025, accuracy: 0.0001)
        XCTAssertEqual(SpeedCurve.frameDuration(speed: SpeedCurve.speed(cpuUsage: 1.0, invert: true)), 1.0, accuracy: 0.0001)
    }

    func testFPSMaxLimit() {
        XCTAssertEqual(SpeedCurve.speed(cpuUsage: 1.0, invert: false, fpsLimit: .fps20), 10, accuracy: 0.0001)
        XCTAssertEqual(SpeedCurve.speed(cpuUsage: 1.0, invert: false, fpsLimit: .fps10), 5, accuracy: 0.0001)
        XCTAssertEqual(SpeedCurve.speed(cpuUsage: 0.1, invert: false, fpsLimit: .fps10), 1, accuracy: 0.0001)
    }

    func testFormatting() {
        XCTAssertEqual(MetricFormat.percent(0.075), " 7.5%")
        XCTAssertEqual(MetricFormat.bytes(6_400_000_000), "6.4 GB")
        XCTAssertEqual(MetricFormat.bytes(512), "512 B")
    }

    @MainActor
    func testSettingsMergeKeepsNewDefaults() throws {
        let stored = #"{"runnerID":"kodee","quota":{"bedrockEnabled":true}}"#.data(using: .utf8)
        let merged = SettingsStore.decodeMerged(data: stored, defaults: AppSettings())
        XCTAssertEqual(merged.runnerID, "kodee")
        XCTAssertTrue(merged.quota.bedrockEnabled)
        XCTAssertTrue(merged.quota.claudeEnabled, "merged quota: \(merged.quota)")
        XCTAssertEqual(merged.updateIntervalSeconds, 5)
    }
}
