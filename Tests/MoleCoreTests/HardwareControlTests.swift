import XCTest
import Darwin
@testable import MoleCore

final class HardwareControlTests: XCTestCase {
    func testNoFanAndUnknownChargeTypesRemainUnavailable() throws {
        let backend = MockSMC(); backend.values["FNum"] = value("FNum", "ui8 ", [0])
        backend.values["CHTE"] = value("CHTE", "hex_", [0, 0, 0, 0])
        let cap = try HardwareControlPolicy.probe(backend)
        XCTAssertEqual(cap.reportedFanCount, 0); XCTAssertTrue(cap.fans.isEmpty); XCTAssertTrue(cap.chargingKeys.isEmpty); XCTAssertEqual(backend.writes, 0)
    }
    func testFanTargetIsClampedToHardwareMinimumAndEncodesKnownTypes() throws {
        let backend = MockSMC.fan()
        let fan = try XCTUnwrap(HardwareControlPolicy.probe(backend).fans.first)
        let minimum = try HardwareControlPolicy.fanTarget(fan, percent: 30)
        XCTAssertEqual(HardwareControlPolicy.rpm(minimum), 2500)
        XCTAssertEqual(HardwareControlPolicy.rpm(try HardwareControlPolicy.fanTarget(fan, percent: 100)), 6000)
        XCTAssertThrowsError(try HardwareControlPolicy.fanTarget(fan, percent: -1))
        XCTAssertThrowsError(try HardwareControlPolicy.fanTarget(fan, percent: 101))
        XCTAssertEqual(backend.writes, 0)
    }
    func testChargingLeasePersistsBeforeWriteAndRestoresOnTimeout() async throws {
        let f = try Fixture(); defer { f.remove() }
        let backend = MockSMC.charging(), engine = f.engine(backend)
        var clock = 0.0; engine.now = { clock }; engine.wait = { clock += 61 }
        backend.beforeWrite = { _ in
            let record = try engine.storage.read(HardwareLeaseRecord.self, file: engine.storage.root.appendingPathComponent("hardware-lease.json"))
            XCTAssertFalse(record.changes.isEmpty)
        }
        let result = try await engine.run(HardwareLeaseRequest(chargeLimit: 80, seconds: 60), client: AdminProcessIdentity.capture(getpid()))
        XCTAssertEqual(result.phase, "restored")
        XCTAssertEqual(backend.values["CHTE"]?.bytes, [0, 0, 0, 0]); XCTAssertEqual(backend.writes, 2)
    }
    func testChargingHysteresisDoesNotToggleWithinBand() async throws {
        let f = try Fixture(); defer { f.remove() }
        let backend = MockSMC.charging(), engine = f.engine(backend)
        var clock = 0.0, index = 0
        let battery = [85, 79, 77, 75]
        engine.now = { clock }; engine.batteryPercent = { battery[min(index, battery.count - 1)] }
        engine.wait = { index += 1; clock += 16 }
        _ = try await engine.run(HardwareLeaseRequest(chargeLimit: 80, seconds: 60), client: AdminProcessIdentity.capture(getpid()))
        XCTAssertEqual(backend.writes, 2) // hold once, allow once; restore is already equal.
    }
    func testFailureDuringFanModeWriteRestoresEarlierTarget() async throws {
        let f = try Fixture(); defer { f.remove() }
        let backend = MockSMC.fan(), engine = f.engine(backend), original = backend.values
        backend.failKey = "F0Md"
        do { _ = try await engine.run(HardwareLeaseRequest(fanPercent: 60, seconds: 60), client: AdminProcessIdentity.capture(getpid())); XCTFail("Expected write failure") } catch { }
        XCTAssertEqual(backend.values, original)
        XCTAssertEqual(try engine.storage.read(HardwareLeaseRecord.self, file: engine.storage.root.appendingPathComponent("hardware-lease.json")).phase, "restored")
    }
    func testCancellationAfterWriteCannotSkipRestoration() async throws {
        let f = try Fixture(); defer { f.remove() }
        let backend = MockSMC.charging(), engine = f.engine(backend)
        engine.wait = { throw CancellationError() }
        do { _ = try await engine.run(HardwareLeaseRequest(chargeLimit: 80, seconds: 60), client: AdminProcessIdentity.capture(getpid())); XCTFail("Expected stopped lease") } catch { }
        XCTAssertEqual(backend.values["CHTE"]?.bytes, [0, 0, 0, 0])
    }
    func testOtherControllerChangesAreNotOverwrittenAndNewLeaseIsBlocked() async throws {
        let f = try Fixture(); defer { f.remove() }
        let backend = MockSMC.charging(), engine = f.engine(backend)
        engine.wait = { backend.values["CHTE"] = self.value("CHTE", "ui32", [8, 0, 0, 0]); throw CancellationError() }
        do { _ = try await engine.run(HardwareLeaseRequest(chargeLimit: 80, seconds: 60), client: AdminProcessIdentity.capture(getpid())); XCTFail("Expected unresolved recovery") } catch { }
        XCTAssertEqual(backend.values["CHTE"]?.bytes, [8, 0, 0, 0])
        XCTAssertEqual(try engine.storage.read(HardwareLeaseRecord.self, file: engine.storage.root.appendingPathComponent("hardware-lease.json")).phase, "needsReview")
        do { _ = try await engine.run(HardwareLeaseRequest(chargeLimit: 80, seconds: 60), client: AdminProcessIdentity.capture(getpid())); XCTFail("Expected blocked new lease") } catch { }
    }
    func testInvalidLeaseAndUntrustedJournalPerformNoHardwareWrites() async throws {
        let f = try Fixture(); defer { f.remove() }
        let backend = MockSMC.charging(), engine = f.engine(backend)
        do { _ = try await engine.run(HardwareLeaseRequest(chargeLimit: 100, seconds: 1), client: AdminProcessIdentity.capture(getpid())); XCTFail("Expected invalid request") } catch { }
        try FileManager.default.createDirectory(at: engine.storage.root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: engine.storage.root.path)
        do { _ = try await engine.run(HardwareLeaseRequest(chargeLimit: 80, seconds: 60), client: AdminProcessIdentity.capture(getpid())); XCTFail("Expected journal failure") } catch { }
        XCTAssertEqual(backend.writes, 0)
    }
    private func value(_ key: String, _ type: String, _ bytes: [UInt8]) -> SMCControlValue { SMCControlValue(key: key, type: type, bytes: bytes) }
    private final class MockSMC: SMCControlBackend {
        var values: [String: SMCControlValue] = [:], writes = 0
        var failKey: String?
        var beforeWrite: ((SMCControlValue) throws -> Void)?
        func read(_ key: String) throws -> SMCControlValue { guard let value = values[key] else { throw AdminError.unavailable("unsupported fixture key") }; return value }
        func write(_ value: SMCControlValue) throws { try beforeWrite?(value); if value.key == failKey { throw AdminError.failed("injected failure") }; writes += 1; values[value.key] = value }
        static func charging() -> MockSMC { let b = MockSMC(); b.values["CHTE"] = SMCControlValue(key: "CHTE", type: "ui32", bytes: [0, 0, 0, 0]); return b }
        static func fan() -> MockSMC {
            let b = MockSMC()
            b.values["FNum"] = SMCControlValue(key: "FNum", type: "ui8 ", bytes: [1])
            b.values["F0Md"] = SMCControlValue(key: "F0Md", type: "ui8 ", bytes: [0])
            for (key, rpm) in [("F0Mn", 2500), ("F0Mx", 6000), ("F0Tg", 2500)] {
                let encoded = UInt16(rpm * 4); b.values[key] = SMCControlValue(key: key, type: "fpe2", bytes: [UInt8(encoded >> 8), UInt8(encoded & 255)])
            }
            return b
        }
    }
    private struct Fixture {
        let root: URL
        init() throws { root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".HardwareFixture-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        func engine(_ backend: SMCControlBackend) -> HardwareLeaseEngine { let e = HardwareLeaseEngine(backend: backend); e.storage = AdminStorage(root: root.appendingPathComponent("journal"), requiredOwner: getuid()); e.batteryPercent = { 85 }; return e }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
