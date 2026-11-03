import XCTest
@testable import MoleCore

final class DiskHealthTests: XCTestCase {
    private func plist(_ value: [String: Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) }
    private func info(_ fields: [String: Any] = [:]) throws -> Data {
        var base: [String: Any] = ["DeviceIdentifier": "disk0", "WholeDisk": true, "ParentWholeDisk": "disk0", "VirtualOrPhysical": "Unknown", "MediaName": "Fixture SSD", "BusProtocol": "USB", "Internal": false, "SolidState": true, "TotalSize": 512_000_000_000 as Int64]
        base.merge(fields) { _, new in new }; return try plist(base)
    }
    func testPhysicalIdentifiersRejectPartitionsDuplicatesAndArguments() throws {
        XCTAssertEqual(try DiskHealthService.identifiers(plist(["WholeDisks": ["disk0", "disk12"]])), ["disk0", "disk12"])
        for ids in [["disk0s1"], ["disk0", "disk0"], ["disk01"], ["/dev/disk0"], ["disk0;eraseDisk"], ["disk-1"], ["disk0\n"], ["disk0 disk1"]] {
            XCTAssertThrowsError(try DiskHealthService.identifiers(plist(["WholeDisks": ids])))
        }
        XCTAssertThrowsError(try DiskHealthService.identifiers(plist(["WholeDisks": Array(repeating: "disk0", count: 65)])))
    }
    func testVerifiedSMARTKeepsDeviceMetadataAndRawCountersWithoutConversion() throws {
        let bytes = try info(["SMARTStatus": "Verified", "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": ["TEMPERATURE": 300, "PERCENTAGE_USED": 0, "DATA_UNITS_WRITTEN_0": 1_000_000]])
        let disk = try DiskHealthService.parse(bytes, expectedDevice: "disk0")
        XCTAssertEqual(disk.health, .verified); XCTAssertEqual(disk.model, "Fixture SSD"); XCTAssertEqual(disk.connection, "USB")
        XCTAssertEqual(disk.isInternal, false); XCTAssertEqual(disk.isSolidState, true); XCTAssertEqual(disk.capacityBytes, 512_000_000_000)
        XCTAssertEqual(disk.rawSMART["TEMPERATURE"], "300"); XCTAssertEqual(disk.rawSMART["PERCENTAGE_USED"], "0")
        XCTAssertTrue(disk.issues.isEmpty)
    }
    func testFailingUnsupportedAndUnknownAreDistinct() throws {
        for (raw, expected): (String, DiskSMARTHealth) in [("Failing", .failing), ("Not Supported", .unsupported), ("NotSupported", .unsupported), ("Healthy-ish", .unknown), ("", .unknown)] {
            XCTAssertEqual(try DiskHealthService.parse(info(["SMARTStatus": raw]), expectedDevice: "disk0").health, expected)
        }
        let missing = try DiskHealthService.parse(info(), expectedDevice: "disk0")
        XCTAssertEqual(missing.health, .unknown); XCTAssertNil(missing.reportedStatus); XCTAssertTrue(missing.rawSMART.isEmpty)
    }
    func testInfoMustStillIdentifySameWholePhysicalDevice() throws {
        for fields: [String: Any] in [["DeviceIdentifier": "disk1"], ["ParentWholeDisk": "disk2"], ["WholeDisk": false], ["WholeDisk": 1], ["VirtualOrPhysical": "Virtual"]] {
            XCTAssertThrowsError(try DiskHealthService.parse(info(fields), expectedDevice: "disk0"))
        }
        XCTAssertThrowsError(try DiskHealthService.parse(info(), expectedDevice: "disk0s1"))
    }
    func testMalformedOrUnsupportedNumbersNeverBecomeZeroOrPercentages() throws {
        let disk = try DiskHealthService.parse(info(["TotalSize": true, "SolidState": "yes", "Internal": 1, "SMARTDeviceSpecificKeysMayVaryNotGuaranteed": ["OK_NUMBER": 12, "NEGATIVE": -1, "FRACTION": 0.5, "BOOL": true, "STRING": "100", "NESTED": ["x": 1], "bad\nkey": 1]]), expectedDevice: "disk0")
        XCTAssertNil(disk.capacityBytes); XCTAssertNil(disk.isInternal); XCTAssertNil(disk.isSolidState)
        XCTAssertEqual(disk.rawSMART, ["OK_NUMBER": "12"]); XCTAssertFalse(disk.issues.isEmpty)
        XCTAssertEqual(disk.health, .unknown)
    }
    func testPropertyListAndRawFieldBudgetsAreBounded() throws {
        XCTAssertThrowsError(try DiskHealthService.identifiers(Data("not a plist".utf8)))
        XCTAssertThrowsError(try DiskHealthService.identifiers(Data(repeating: 32, count: 1_048_577)))
        let fields = Dictionary(uniqueKeysWithValues: (0..<129).map { ("KEY_\($0)", $0) })
        let disk = try DiskHealthService.parse(info(["SMARTDeviceSpecificKeysMayVaryNotGuaranteed": fields]), expectedDevice: "disk0")
        XCTAssertTrue(disk.rawSMART.isEmpty); XCTAssertFalse(disk.issues.isEmpty)
    }
    func testServiceUsesOnlyListAndInfoAndPreservesDisconnectedDisk() async throws {
        let list = try plist(["WholeDisks": ["disk0", "disk1"]]), bytes = try info(["SMARTStatus": "Verified"])
        let service = DiskHealthService(command: { command in
            XCTAssertEqual(command.executable, "/usr/sbin/diskutil")
            if command.arguments == ["list", "-plist", "physical"] { return Self.result(command, data: list) }
            if command.arguments == ["info", "-plist", "disk0"] { return Self.result(command, data: bytes) }
            XCTAssertEqual(command.arguments, ["info", "-plist", "disk1"])
            return ToolCommandResult(command: command.display, exitCode: 1, output: "disconnected fixture", duration: 0)
        })
        let report = try await service.inspect()
        XCTAssertEqual(report.disks.count, 2); XCTAssertEqual(report.disks[0].health, .verified)
        XCTAssertEqual(report.disks[1].device, "disk1"); XCTAssertEqual(report.disks[1].health, .unknown); XCTAssertFalse(report.disks[1].issues.isEmpty)
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(DiskHealthReport.self, from: data).disks.count, 2)
    }
    func testCancellationPropagatesInsteadOfProducingHealthyOrCompleteResult() async throws {
        let list = try plist(["WholeDisks": ["disk0"]])
        let service = DiskHealthService(command: { command in
            if command.arguments.first == "list" { return Self.result(command, data: list) }
            throw CancellationError()
        })
        do { _ = try await service.inspect(); XCTFail("Cancellation must propagate") } catch is CancellationError { } catch { XCTFail("Unexpected \(error)") }
    }
    func testEmptyAndFailedEnumerationRemainExplicit() async throws {
        let empty = try plist(["WholeDisks": [String]()])
        let service = DiskHealthService(command: { Self.result($0, data: empty) })
        let report = try await service.inspect()
        XCTAssertTrue(report.disks.isEmpty); XCTAssertFalse(report.issues.isEmpty)
        let failed = DiskHealthService(command: { ToolCommandResult(command: $0.display, exitCode: 1, output: "unavailable fixture", duration: 0) })
        do { _ = try await failed.inspect(); XCTFail("Enumeration failure must not be success") } catch { }
    }
    private static func result(_ command: ToolCommand, data: Data) -> ToolCommandResult { ToolCommandResult(command: command.display, exitCode: 0, output: String(decoding: data, as: UTF8.self), duration: 0) }
}
