import GoRunnerCore
import XCTest
@testable import SystemMetrics

final class SystemMonitorLiveTests: XCTestCase {
    func testSampleNowIsSaneAndFast() throws {
        let begin = Date()
        let monitor = SystemMonitor()
        let snapshot = monitor.sampleNow()
        let elapsed = Date().timeIntervalSince(begin)

        XCTAssertLessThan(elapsed, 1.5)
        XCTAssertTrue((0...1).contains(snapshot.cpu.usage))
        let memory = try XCTUnwrap(snapshot.memory)
        XCTAssertGreaterThan(memory.physicalBytes, 0)
        XCTAssertTrue((0...1).contains(memory.usage))
        let storage = try XCTUnwrap(snapshot.storage)
        XCTAssertGreaterThan(storage.totalBytes, 0)
        XCTAssertNotNil(snapshot.battery)
        XCTAssertNotNil(snapshot.network)

        // A second sample 1 s later has real CPU and network deltas (what --smoke-test does).
        Thread.sleep(forTimeInterval: 1)
        let second = monitor.sampleNow()
        print(Self.describe(second, firstSampleSeconds: elapsed))
    }

    func testDisabledMetricsAreNil() {
        let monitor = SystemMonitor()
        monitor.update(options: MetricsOptions(interval: 5, memory: false, storage: false, battery: false, network: false))
        let snapshot = monitor.sampleNow()
        XCTAssertNil(snapshot.memory)
        XCTAssertNil(snapshot.storage)
        XCTAssertNil(snapshot.battery)
        XCTAssertNil(snapshot.network)
    }

    func testStartDeliversRepeatedUpdatesOnMain() {
        let monitor = SystemMonitor()
        let expectation = expectation(description: "two updates")
        var count = 0
        var offMain = false
        monitor.start(options: MetricsOptions(interval: 1)) { _ in
            if !Thread.isMainThread { offMain = true }
            count += 1
            if count == 2 { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 3)
        monitor.stop()
        XCTAssertFalse(offMain)

        // No more callbacks after stop; start works again.
        let stoppedCount = count
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.3))
        XCTAssertEqual(count, stoppedCount)

        let again = self.expectation(description: "restart")
        monitor.start(options: MetricsOptions(interval: 1, network: false)) { snapshot in
            XCTAssertNil(snapshot.network)
            again.fulfill()
        }
        wait(for: [again], timeout: 2)
        monitor.stop()
    }

    private static func describe(_ s: SystemSnapshot, firstSampleSeconds: Double) -> String {
        func gb(_ bytes: Double) -> String { String(format: "%.2f GB", bytes / 1_000_000_000) }
        var lines = ["=== GoRunner live snapshot (first sampleNow took \(String(format: "%.3f", firstSampleSeconds)) s)"]
        lines.append(String(format: "cpu: usage %.3f system %.3f user %.3f idle %.3f",
                            s.cpu.usage, s.cpu.system, s.cpu.user, s.cpu.idle))
        if let m = s.memory {
            lines.append(String(format: "memory: usage %.3f pressure %.3f app %@ wired %@ compressed %@ physical %@",
                                m.usage, m.pressure, gb(m.appBytes), gb(m.wiredBytes), gb(m.compressedBytes), gb(m.physicalBytes)))
        }
        if let st = s.storage {
            lines.append("storage: total \(gb(st.totalBytes)) available \(gb(st.availableBytes)) usage \(String(format: "%.3f", st.usage))")
        }
        if let b = s.battery {
            lines.append("battery: \(b)")
        }
        if let n = s.network {
            lines.append("network: \(n)")
        }
        return lines.joined(separator: "\n")
    }
}
