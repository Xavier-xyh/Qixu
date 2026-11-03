import Foundation
import IOKit

/// A bounded read-only AppleSMC client. It sends only key metadata (9) and read bytes (5).
/// The wire format is private; unsupported drivers, keys and types remain unavailable.
enum ReadOnlySMCSensors {
    // These keys are present in retained Mole strings and documented as temperature sensors
    // in upstream sensor implementations. Physical placement varies by chip, so UI uses keys.
    private static let temperatureKeys = [
        "TC0P", "TC0D", "TC0E", "TC0F", "TG0P",
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X", "Tp0b", "Tp0f", "Tp0j",
        "Tp0V", "Tp0Y", "Tp0e", "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0a", "Tp0d", "Tp0g", "Tp0m", "Tp0p", "Tp0u", "Tp0y"
    ]

    static func collect() -> MonitorSensors {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return unavailable("此设备未提供 AppleSMC 传感器服务") }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let status = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard status == KERN_SUCCESS else { return unavailable("传感器服务不可读取（\(status)）") }
        defer { IOServiceClose(connection) }
        let reader = Reader(connection: connection)
        let temperatures = temperatureKeys.compactMap { key -> MonitorTemperature? in
            guard let raw = reader.read(key), !raw.bytes.allSatisfy({ $0 == 0 }),
                  let value = MonitorSensorDecoding.temperature(type: raw.type, bytes: raw.bytes) else { return nil }
            return MonitorTemperature(key: key, celsius: value)
        }
        let count = reader.read("FNum").flatMap { raw -> Int? in
            guard raw.type == "ui8 ", raw.bytes.count == 1, let value = raw.bytes.first,
                  value <= 16 else { return nil }
            return Int(value)
        }
        let fans = (0..<(count ?? 0)).compactMap { index -> MonitorFan? in
            let key = "F" + String(index, radix: 16, uppercase: true) + "Ac"
            guard let raw = reader.read(key), let value = MonitorSensorDecoding.fanRPM(type: raw.type, bytes: raw.bytes) else { return nil }
            return MonitorFan(index: index, revolutionsPerMinute: value)
        }
        let diagnostic: String?
        if temperatures.isEmpty && count == nil { diagnostic = "此设备未返回可验证的温度或风扇读数" }
        else if let count, fans.count < count { diagnostic = "部分风扇转速不可读取" }
        else { diagnostic = nil }
        return MonitorSensors(temperatures: temperatures, fans: fans, reportedFanCount: count, diagnostic: diagnostic)
    }

    private static func unavailable(_ message: String) -> MonitorSensors {
        MonitorSensors(temperatures: [], fans: [], reportedFanCount: nil, diagnostic: message)
    }

    private struct Reader {
        let connection: io_connect_t
        private enum ReadOperation: UInt8 { case bytes = 5, metadata = 9 }
        func read(_ key: String) -> (type: String, bytes: [UInt8])? {
            let characters = Array(key.utf8)
            guard characters.count == 4, characters.allSatisfy({ (32...126).contains($0) }) else { return nil }
            let code = characters.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard let info = call(key: code, operation: .metadata),
                  let length = Self.uint32(info, at: 28), (1...32).contains(length),
                  let typeCode = Self.uint32(info, at: 32),
                  let data = call(key: code, operation: .bytes, size: length) else { return nil }
            let typeBytes = [UInt8((typeCode >> 24) & 255), UInt8((typeCode >> 16) & 255), UInt8((typeCode >> 8) & 255), UInt8(typeCode & 255)]
            guard let type = String(bytes: typeBytes, encoding: .ascii) else { return nil }
            return (type, Array(data[48..<(48 + Int(length))]))
        }

        private func call(key: UInt32, operation: ReadOperation, size: UInt32 = 0) -> [UInt8]? {
            // Fixed 80-byte C wire layout avoids Swift nested-struct padding differences.
            var input = [UInt8](repeating: 0, count: 80)
            Self.put(key, into: &input, at: 0)
            Self.put(size, into: &input, at: 28)
            input[42] = operation.rawValue
            var output = [UInt8](repeating: 0, count: 80)
            var returnedSize = 80
            let result = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    IOConnectCallStructMethod(connection, 2, source.baseAddress, 80, destination.baseAddress, &returnedSize)
                }
            }
            guard result == KERN_SUCCESS, returnedSize == 80, output[40] == 0 else { return nil }
            return output
        }

        private static func put(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
            for i in 0..<4 { bytes[offset + i] = UInt8((value >> (i * 8)) & 255) }
        }
        private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
            guard offset >= 0, bytes.count >= offset + 4 else { return nil }
            return (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[offset + $1]) << ($1 * 8)) }
        }
    }
}

/// Decode only sensor-specific types with known units and reject malformed values.
enum MonitorSensorDecoding {
    static func temperature(type: String, bytes: [UInt8]) -> Double? {
        let value: Double?
        switch type {
        case "sp78" where bytes.count == 2:
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "flt " where bytes.count == 4:
            value = floatingPoint(bytes)
        default: value = nil
        }
        guard let value, value.isFinite, (-40...150).contains(value) else { return nil }
        return value
    }

    static func fanRPM(type: String, bytes: [UInt8]) -> Double? {
        let value: Double?
        switch type {
        case "fpe2" where bytes.count == 2:
            value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "flt " where bytes.count == 4:
            value = floatingPoint(bytes)
        default: value = nil
        }
        guard let value, value.isFinite, (0...30_000).contains(value) else { return nil }
        return value
    }

    private static func floatingPoint(_ bytes: [UInt8]) -> Double {
        let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[$1]) << ($1 * 8) }
        return Double(Float(bitPattern: bits))
    }
}
