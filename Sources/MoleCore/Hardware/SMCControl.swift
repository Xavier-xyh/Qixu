import Foundation
import IOKit
import Darwin

struct SMCControlValue: Codable, Equatable, Sendable {
    let key: String
    let type: String
    var bytes: [UInt8]
}
protocol SMCControlBackend: AnyObject {
    func read(_ key: String) throws -> SMCControlValue
    func write(_ value: SMCControlValue) throws
}
/// Fixed wire layout; only the control engine's narrow key list can be written.
final class LiveSMCControl: SMCControlBackend {
    private var connection: io_connect_t = 0
    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw AdminError.unavailable("此设备没有 AppleSMC 服务。") }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { throw AdminError.unavailable("此设备无法访问 AppleSMC。") }
    }
    deinit { IOServiceClose(connection) }
    func read(_ key: String) throws -> SMCControlValue {
        let info = try call(key: key, operation: 9)
        let length = Int(Self.word(info, 28)), typeCode = Self.word(info, 32)
        guard (1...32).contains(length), let type = String(bytes: [UInt8((typeCode >> 24) & 255), UInt8((typeCode >> 16) & 255), UInt8((typeCode >> 8) & 255), UInt8(typeCode & 255)], encoding: .ascii) else { throw AdminError.invalid("SMC 类型无效。") }
        let data = try call(key: key, operation: 5, bytes: [UInt8](repeating: 0, count: length))
        return SMCControlValue(key: key, type: type, bytes: Array(data[48..<(48 + length)]))
    }
    func write(_ value: SMCControlValue) throws {
        guard geteuid() == 0, HardwareControlPolicy.writeKeys.contains(value.key) else { throw AdminError.invalid("SMC 写入必须经过独立管理员组件且限于固定控制键。") }
        let current = try read(value.key)
        guard current.type == value.type, current.bytes.count == value.bytes.count else { throw AdminError.invalid("SMC 键类型在执行前已改变。") }
        _ = try call(key: value.key, operation: 6, bytes: value.bytes)
    }
    private func call(key: String, operation: UInt8, bytes: [UInt8] = []) throws -> [UInt8] {
        guard key.utf8.count == 4, key.utf8.allSatisfy({ (32...126).contains($0) }), bytes.count <= 32 else { throw AdminError.invalid("SMC 请求格式无效。") }
        var input = [UInt8](repeating: 0, count: 80), output = input, length = 80
        Self.put(key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }, into: &input, at: 0)
        Self.put(UInt32(bytes.count), into: &input, at: 28); input[42] = operation
        for index in bytes.indices { input[48 + index] = bytes[index] }
        let result = input.withUnsafeBytes { source in output.withUnsafeMutableBytes { destination in IOConnectCallStructMethod(connection, 2, source.baseAddress, 80, destination.baseAddress, &length) } }
        guard result == KERN_SUCCESS, length == 80, output[40] == 0 else { throw AdminError.unavailable("SMC 不接受 \(key) 的\(operation == 6 ? "写入" : "读取")（\(result)）。") }
        return output
    }
    private static func word(_ bytes: [UInt8], _ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << ($1 * 8) } }
    private static func put(_ value: UInt32, into bytes: inout [UInt8], at: Int) { for i in 0..<4 { bytes[at + i] = UInt8((value >> (i * 8)) & 255) } }
}

public struct HardwareFanCapability: Identifiable, Codable, Sendable {
    public let index: Int
    public let minimumRPM: Double
    public let maximumRPM: Double
    public var id: Int { index }
    let mode: SMCControlValue
    let target: SMCControlValue
}
public struct HardwareCapabilities: Codable, Sendable {
    public let reportedFanCount: Int?
    public let fans: [HardwareFanCapability]
    public let chargingKeys: [String]
    public let issues: [String]
    public static func probe() throws -> HardwareCapabilities { try HardwareControlPolicy.probe(LiveSMCControl()) }
}
public struct HardwareLeaseRequest: Codable, Sendable {
    public let id: UUID
    public let fanPercent: Int?
    public let chargeLimit: Int?
    public let seconds: Int
    public init(fanPercent: Int? = nil, chargeLimit: Int? = nil, seconds: Int = 1800) {
        id = UUID(); self.fanPercent = fanPercent; self.chargeLimit = chargeLimit; self.seconds = seconds
    }
    public func stopFile(uid: UInt32) -> URL { URL(fileURLWithPath: "/private/tmp/MoleRebuild-stop-\(uid)-\(id.uuidString)") }
    public func requestStop() throws {
        let file = stopFile(uid: getuid())
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd >= 0 { Darwin.close(fd); return }
        var st = stat()
        guard lstat(file.path, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG, st.st_size == 0 else { throw AdminError.invalid("无法创建硬件会话停止信号。") }
    }
}
struct HardwareKeyChange: Codable, Sendable {
    let original: SMCControlValue
    var intended: SMCControlValue
}
public struct HardwareLeaseRecord: Codable, Sendable {
    public let id: UUID
    public let ownerUID: UInt32
    public let date: Date
    public var phase: String
    public var detail: String
    var changes: [HardwareKeyChange]
}

enum HardwareControlPolicy {
    static let writeKeys: Set<String> = Set((0..<10).flatMap { ["F\($0)Md", "F\($0)md", "F\($0)Tg"] } + ["CHTE", "CH0B", "CH0C"])
    static func probe(_ backend: SMCControlBackend) throws -> HardwareCapabilities {
        var fans: [HardwareFanCapability] = [], issues: [String] = []
        let rawCount = try? backend.read("FNum")
        let count = rawCount.flatMap { $0.type == "ui8 " && $0.bytes.count == 1 && $0.bytes[0] <= 10 ? Int($0.bytes[0]) : nil }
        if let count {
            for index in 0..<count {
                let mode = (try? backend.read("F\(index)md")) ?? (try? backend.read("F\(index)Md"))
                let minimum = ((try? backend.read("F\(index)mn")) ?? (try? backend.read("F\(index)Mn"))).flatMap(rpm)
                let maximum = ((try? backend.read("F\(index)mx")) ?? (try? backend.read("F\(index)Mx"))).flatMap(rpm)
                guard let mode, mode.type == "ui8 ", mode.bytes.count == 1, [0, 1, 3].contains(mode.bytes[0]),
                      let minimum, let maximum, minimum > 0, maximum > minimum,
                      let target = try? backend.read("F\(index)Tg"), rpm(target) != nil,
                      target.type != "fpe2" || maximum <= 16383 else { issues.append("风扇 \(index)：控制类型或上下限不明确，禁用写入。"); continue }
                fans.append(HardwareFanCapability(index: index, minimumRPM: minimum, maximumRPM: maximum, mode: mode, target: target))
            }
        } else { issues.append("无法确认风扇数量，禁用风扇控制。") }
        var keys: [String] = []
        #if arch(arm64)
        if let modern = try? backend.read("CHTE"), modern.type == "ui32", modern.bytes == [0, 0, 0, 0] || modern.bytes == [1, 0, 0, 0] { keys = ["CHTE"] }
        else if let b = try? backend.read("CH0B"), let c = try? backend.read("CH0C"),
                [b, c].allSatisfy({ $0.type == "ui8 " && $0.bytes.count == 1 && [0, 2].contains($0.bytes[0]) }) { keys = ["CH0B", "CH0C"] }
        #endif
        if keys.isEmpty { issues.append("没有识别到支持的充电控制协议，禁用充电写入。") }
        return HardwareCapabilities(reportedFanCount: count, fans: fans, chargingKeys: keys, issues: issues)
    }
    static func rpm(_ value: SMCControlValue) -> Double? { MonitorSensorDecoding.fanRPM(type: value.type, bytes: value.bytes) }
    static func fanTarget(_ fan: HardwareFanCapability, percent: Int) throws -> SMCControlValue {
        guard (30...100).contains(percent) else { throw AdminError.invalid("风扇百分比必须为 30–100，且不得低于硬件下限。") }
        let target = min(fan.maximumRPM, max(fan.minimumRPM, floor(fan.maximumRPM * Double(percent) / 100)))
        var result = fan.target
        if result.type == "flt " { let bits = Float(target).bitPattern; result.bytes = (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) } }
        else if result.type == "fpe2", target <= 16383 { let bits = UInt16(target * 4); result.bytes = [UInt8(bits >> 8), UInt8(bits & 255)] }
        else { throw AdminError.invalid("不支持的风扇目标编码。") }
        return result
    }
    static func chargeValue(_ current: SMCControlValue, hold: Bool) throws -> SMCControlValue {
        var result = current
        if current.key == "CHTE", current.type == "ui32", current.bytes.count == 4 { result.bytes = [hold ? 1 : 0, 0, 0, 0] }
        else if ["CH0B", "CH0C"].contains(current.key), current.type == "ui8 ", current.bytes.count == 1 { result.bytes = [hold ? 2 : 0] }
        else { throw AdminError.invalid("未知充电控制类型，拒绝写入。") }
        return result
    }
    static func equivalent(_ a: SMCControlValue, _ b: SMCControlValue) -> Bool {
        guard a.key == b.key, a.type == b.type, a.bytes.count == b.bytes.count else { return false }
        if a.key.hasSuffix("Tg"), let x = rpm(a), let y = rpm(b) { return abs(x - y) <= 1 }
        return a.bytes == b.bytes
    }
}
