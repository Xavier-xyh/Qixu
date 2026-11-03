import XCTest
@testable import MoleCore

final class MonitoringTests: XCTestCase {
    func testCPUUsesPerCoreAverageRatherThanSum() {
        let old: [UInt32] = [10, 10, 80, 0, 10, 10, 80, 0]
        let new: [UInt32] = [30, 40, 130, 0, 20, 20, 160, 0]
        let cpu = MonitorMath.cpuUsage(previous: old, current: new)
        XCTAssertTrue(cpu.hasBaseline)
        XCTAssertEqual(cpu.perCore, [50, 20])
        XCTAssertEqual(cpu.usage, 35, accuracy: 0.001)
    }
    func testCPUInitialAndCoreCountChangeRequireNewBaseline() {
        XCTAssertFalse(MonitorMath.cpuUsage(previous: nil, current: [1, 1, 1, 1]).hasBaseline)
        XCTAssertFalse(MonitorMath.cpuUsage(previous: [1, 1, 1, 1], current: [UInt32](repeating: 2, count: 8)).hasBaseline)
    }
    func testCounterResetAndInvalidTimeNeverCreateNegativeOrInfiniteRates() {
        XCTAssertEqual(MonitorMath.rate(previous: 200, current: 100, elapsed: 1), 0)
        XCTAssertEqual(MonitorMath.rate(previous: nil, current: 100, elapsed: 1), 0)
        XCTAssertEqual(MonitorMath.rate(previous: 0, current: 100, elapsed: 0), 0)
        XCTAssertEqual(MonitorMath.rate(previous: 0, current: 100, elapsed: .nan), 0)
        XCTAssertEqual(MonitorMath.rate(previous: 100, current: 1100, elapsed: 2), 500)
    }
    func testMemoryIncludesActiveWiredAndCompressedAndClampsToPhysicalTotal() {
        XCTAssertEqual(MonitorMath.memoryUsed(active: 10, wired: 5, compressed: 2, pageSize: 4096, total: 1_000_000), 17 * 4096)
        XCTAssertEqual(MonitorMath.memoryUsed(active: 100, wired: 100, compressed: 100, pageSize: 4096, total: 128), 128)
        XCTAssertEqual(MonitorMath.memoryUsed(active: .max, wired: 1, compressed: 1, pageSize: 4096, total: 1024), 1024)
    }

    func testCPUTickWrapDiscardsOnlyAffectedCoreInterval() {
        let old: [UInt32] = [.max, 10, 20, 0, 0, 0, 0, 0]
        let new: [UInt32] = [2, 11, 21, 0, 10, 10, 80, 0]
        let value = MonitorMath.cpuUsage(previous: old, current: new)
        XCTAssertEqual(value.perCore, [0, 20])
        XCTAssertEqual(value.usage, 10)
    }

    func testCoreGroupClassificationUsesNameRatherThanLevelOrder() {
        XCTAssertEqual(MonitorCPUGroup(level: 1, name: "Performance", logicalCount: 8, physicalCount: 8).displayName, "性能核心（P）")
        XCTAssertEqual(MonitorCPUGroup(level: 0, name: "Efficiency", logicalCount: 4, physicalCount: 4).displayName, "能效核心（E）")
        XCTAssertEqual(MonitorCPUGroup(level: 0, name: "Super", logicalCount: 6, physicalCount: nil).displayName, "Super 核心")
        XCTAssertEqual(MonitorCPUGroup(level: 2, name: "Future", logicalCount: 2, physicalCount: nil).displayName, "Future")
    }

    func testSensorDecodingRequiresKnownTypeExactSizeAndValidUnits() {
        XCTAssertEqual(MonitorSensorDecoding.temperature(type: "sp78", bytes: [0x2a, 0x80]), 42.5)
        XCTAssertEqual(MonitorSensorDecoding.temperature(type: "sp78", bytes: [0xff, 0x80]), -0.5)
        XCTAssertEqual(MonitorSensorDecoding.temperature(type: "flt ", bytes: [0, 0, 0x28, 0x42]), 42)
        XCTAssertEqual(MonitorSensorDecoding.fanRPM(type: "fpe2", bytes: [0x1f, 0x40]), 2000)
        XCTAssertEqual(MonitorSensorDecoding.fanRPM(type: "flt ", bytes: [0, 0, 0, 0]), 0)
        XCTAssertNil(MonitorSensorDecoding.temperature(type: "unknown", bytes: [42, 0]))
        XCTAssertNil(MonitorSensorDecoding.temperature(type: "sp78", bytes: [42]))
        XCTAssertNil(MonitorSensorDecoding.temperature(type: "flt ", bytes: [0, 0, 0x80, 0x7f]))
        XCTAssertNil(MonitorSensorDecoding.fanRPM(type: "sp78", bytes: [42, 0]))
        XCTAssertNil(MonitorSensorDecoding.fanRPM(type: "flt ", bytes: [0, 0, 0x80, 0xbf]))
    }

    /// Actual system API reads only. Values vary by machine and activity, so no load,
    /// memory capacity, interface name, sensor presence, or hardware count is assumed.
    func testReadOnlyCollectorTwoSamplesHaveValidRanges() async throws {
        let collector = SystemMonitorCollector()
        let first = await collector.collect(includeProcesses: false)
        try await Task.sleep(nanoseconds: 150_000_000)
        let second = await collector.collect(includeProcesses: false)
        XCTAssertGreaterThanOrEqual(second.date, first.date)
        XCTAssertTrue(first.processes.isEmpty)
        XCTAssertTrue(second.processes.isEmpty)
        if let cpu = first.cpu { XCTAssertFalse(cpu.hasBaseline) }
        if first.cpu != nil, let cpu = second.cpu { XCTAssertTrue(cpu.hasBaseline) }
        for sample in [first, second] {
            if let cpu = sample.cpu {
                XCTAssertTrue(cpu.usage.isFinite)
                XCTAssertTrue((0...100).contains(cpu.usage))
                for usage in cpu.perCore {
                    XCTAssertTrue(usage.isFinite)
                    XCTAssertTrue((0...100).contains(usage))
                }
                XCTAssertEqual(Set(cpu.coreGroups.map(\.level)).count, cpu.coreGroups.count)
                for group in cpu.coreGroups {
                    XCTAssertGreaterThan(group.logicalCount, 0)
                    if let count = group.physicalCount { XCTAssertGreaterThan(count, 0) }
                }
            }
            if let memory = sample.memory {
                XCTAssertLessThanOrEqual(memory.used, memory.total)
                XCTAssertTrue(memory.pressurePercent.isFinite)
                XCTAssertTrue((0...100).contains(memory.pressurePercent))
                XCTAssertTrue(memory.usedPercent.isFinite)
                XCTAssertTrue((0...100).contains(memory.usedPercent))
                if let used = memory.swapUsed, let total = memory.swapTotal { XCTAssertLessThanOrEqual(used, total) }
            }
            XCTAssertEqual(Set(sample.network.map(\.name)).count, sample.network.count)
            for interface in sample.network {
                XCTAssertFalse(interface.name.isEmpty)
                XCTAssertTrue(interface.receivedPerSecond.isFinite)
                XCTAssertTrue(interface.sentPerSecond.isFinite)
                XCTAssertGreaterThanOrEqual(interface.receivedPerSecond, 0)
                XCTAssertGreaterThanOrEqual(interface.sentPerSecond, 0)
            }
            if let batteryTemperature = sample.battery?.temperatureCelsius {
                XCTAssertTrue(batteryTemperature.isFinite)
                XCTAssertTrue((-40...100).contains(batteryTemperature))
            }
            for temperature in sample.sensors?.temperatures ?? [] {
                XCTAssertTrue(temperature.celsius.isFinite)
                XCTAssertTrue((-40...150).contains(temperature.celsius))
            }
            for fan in sample.sensors?.fans ?? [] {
                XCTAssertTrue(fan.revolutionsPerMinute.isFinite)
                XCTAssertTrue((0...30_000).contains(fan.revolutionsPerMinute))
            }
        }
    }
}
