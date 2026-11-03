import Foundation
import CoreFoundation

public enum DiskSMARTHealth: String, Codable, Sendable {
    case verified, failing, unsupported, unknown
    public var label: String {
        switch self { case .verified: return "SMART 已通过"; case .failing: return "SMART 报告故障"; case .unsupported: return "设备未提供 SMART 支持"; case .unknown: return "SMART 状态不可用或未识别" }
    }
}
public struct PhysicalDiskHealth: Identifiable, Codable, Sendable {
    public var id: String { device }
    public let device: String
    public var sampledAt = Date()
    public var model: String?
    public var connection: String?
    public var isInternal: Bool?
    public var isSolidState: Bool?
    public var capacityBytes: Int64?
    public var health: DiskSMARTHealth = .unknown
    public var reportedStatus: String?
    public var rawSMART: [String: String] = [:]
    public var issues: [String] = []
}
public struct DiskHealthReport: Codable, Sendable {
    public let date: Date
    public let disks: [PhysicalDiskHealth]
    public let issues: [String]
}
public struct DiskHealthService: Sendable {
    let command: @Sendable (ToolCommand) async throws -> ToolCommandResult
    public init() { command = { try await ToolCommandExecutor().run($0, timeout: 15, maximumOutputBytes: 1024 * 1024) } }
    init(command: @escaping @Sendable (ToolCommand) async throws -> ToolCommandResult) { self.command = command }
    public func inspect(progress: @escaping @Sendable (PhysicalDiskHealth) -> Void = { _ in }) async throws -> DiskHealthReport {
        try Task.checkCancellation()
        let list = try await command(ToolCommand("/usr/sbin/diskutil", ["list", "-plist", "physical"]))
        guard list.succeeded else { throw ToolOperationError.failed("无法读取物理磁盘清单：\(list.output.prefix(500))") }
        let ids = try Self.identifiers(Data(list.output.utf8))
        let started = ProcessInfo.processInfo.systemUptime
        var disks: [PhysicalDiskHealth] = [], issues: [String] = []
        for id in ids {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - started < 60 else { issues.append("磁盘信息读取达到时限，其余设备未读取。"); break }
            var disk: PhysicalDiskHealth
            do {
                let result = try await command(ToolCommand("/usr/sbin/diskutil", ["info", "-plist", id]))
                try Task.checkCancellation()
                guard result.succeeded else { throw ToolOperationError.failed("设备不可读取或已断开：\(result.output.prefix(300))") }
                disk = try Self.parse(Data(result.output.utf8), expectedDevice: id)
            } catch is CancellationError { throw CancellationError() }
            catch { disk = PhysicalDiskHealth(device: id); disk.issues = [error.localizedDescription] }
            disks.append(disk); progress(disk)
        }
        if ids.isEmpty { issues.append("系统未报告物理磁盘。") }
        return DiskHealthReport(date: Date(), disks: disks, issues: issues)
    }
    static func identifiers(_ data: Data) throws -> [String] {
        let plist = try dictionary(data)
        guard let ids = plist["WholeDisks"] as? [String], ids.count <= 64, Set(ids).count == ids.count, ids.allSatisfy(validIdentifier) else { throw invalid("物理磁盘标识清单无效或过大。") }
        return ids
    }
    static func parse(_ data: Data, expectedDevice: String) throws -> PhysicalDiskHealth {
        let info = try dictionary(data)
        guard validIdentifier(expectedDevice), info["DeviceIdentifier"] as? String == expectedDevice, boolean(info["WholeDisk"]) == true,
              info["ParentWholeDisk"] == nil || info["ParentWholeDisk"] as? String == expectedDevice,
              info["VirtualOrPhysical"] as? String != "Virtual" else { throw invalid("设备身份改变或不是整块物理磁盘。") }
        var disk = PhysicalDiskHealth(device: expectedDevice)
        disk.model = text(info["DeviceModel"]) ?? text(info["MediaName"])
        disk.connection = text(info["BusProtocol"])
        disk.isInternal = boolean(info["Internal"]); disk.isSolidState = boolean(info["SolidState"])
        if let value = integer(info["TotalSize"] ?? info["DiskSize"]), let bytes = Int64(value), bytes > 0 { disk.capacityBytes = bytes }
        disk.reportedStatus = text(info["SMARTStatus"])
        switch disk.reportedStatus?.lowercased() {
        case "verified": disk.health = .verified
        case "failing": disk.health = .failing
        case "not supported", "notsupported": disk.health = .unsupported
        default: disk.health = .unknown
        }
        if let raw = info["SMARTDeviceSpecificKeysMayVaryNotGuaranteed"] {
            if let fields = raw as? [String: Any], fields.count <= 128 {
                for (key, value) in fields {
                    guard !key.isEmpty, key.utf8.count <= 128, key.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }), let number = integer(value) else { disk.issues.append("部分驱动原始字段的类型不受支持，未显示。"); continue }
                    disk.rawSMART[key] = number
                }
                disk.issues = Array(Set(disk.issues)).sorted()
            } else { disk.issues.append("驱动原始 SMART 字段结构不可识别，未显示。") }
        }
        return disk
    }
    private static func validIdentifier(_ value: String) -> Bool {
        guard value.hasPrefix("disk") else { return false }
        let digits = value.dropFirst(4)
        return (1...9).contains(digits.utf8.count) && digits.utf8.allSatisfy { (48...57).contains($0) } && (digits == "0" || digits.first != "0")
    }
    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= 1024 * 1024, let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw invalid("磁盘属性列表无效或超过大小限制。") }; return value
    }
    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }; return value
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }; return number.boolValue
    }
    private static func integer(_ value: Any?) -> String? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), UInt64(number.stringValue) != nil else { return nil }; return number.stringValue
    }
    private static func invalid(_ message: String) -> ToolOperationError { .invalid(message) }
}
