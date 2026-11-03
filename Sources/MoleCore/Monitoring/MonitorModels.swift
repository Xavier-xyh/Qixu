import Foundation

public struct MonitorCPU: Sendable {
    public var usage: Double
    public var perCore: [Double]
    public var loads: [Double]
    public var hasBaseline: Bool
    /// Groups reported by sysctl; these do not identify Mach per-core array indices.
    public var coreGroups: [MonitorCPUGroup] = []
    public init(usage: Double = 0, perCore: [Double] = [], loads: [Double] = [], hasBaseline: Bool = false) {
        self.usage = usage; self.perCore = perCore; self.loads = loads; self.hasBaseline = hasBaseline
    }
}

public struct MonitorCPUGroup: Identifiable, Sendable {
    public let level: Int
    public let name: String
    public let logicalCount: Int
    public let physicalCount: Int?
    public var id: Int { level }
    public var displayName: String {
        switch name.lowercased() {
        case "performance": return "性能核心（P）"
        case "efficiency": return "能效核心（E）"
        case "super": return "Super 核心"
        default: return name.isEmpty ? "性能分组 \(level)" : name
        }
    }
}

public struct MonitorMemory: Sendable {
    public let used: UInt64
    public let total: UInt64
    public let pressurePercent: Double
    public let pressureLevel: Int
    public let swapUsed: UInt64?
    public let swapTotal: UInt64?
    public var usedPercent: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 }
}

public struct MonitorNetwork: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let receivedPerSecond: Double
    public let sentPerSecond: Double
    public let receivedTotal: UInt64
    public let sentTotal: UInt64
    public let ipv4: String?
}

public struct MonitorVolume: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let total: Int64
    public let available: Int64
    public let isInternal: Bool
    public var used: Int64 { max(0, total - available) }
    public var usedPercent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
}

public struct MonitorDiskIO: Sendable {
    public let readPerSecond: Double
    public let writePerSecond: Double
    public let hasBaseline: Bool
}

public struct MonitorProcess: Identifiable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let path: String?
    public let cpuPercent: Double
    public let residentBytes: UInt64
    public let threadCount: Int
}

public struct MonitorBattery: Sendable {
    public let chargePercent: Double?
    public let healthPercent: Double?
    public let cycles: Int?
    public let isCharging: Bool
    public let isExternalConnected: Bool
    public let temperatureCelsius: Double?
}

public struct MonitorTemperature: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let celsius: Double
}

public struct MonitorFan: Identifiable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let revolutionsPerMinute: Double
}

public struct MonitorSensors: Sendable {
    public let temperatures: [MonitorTemperature]
    public let fans: [MonitorFan]
    /// nil means unavailable; zero means the device explicitly reported no fans.
    public let reportedFanCount: Int?
    public let diagnostic: String?
}

public struct MonitorSnapshot: Sendable {
    public let date: Date
    public let cpu: MonitorCPU?
    public let memory: MonitorMemory?
    public let network: [MonitorNetwork]
    public let diskIO: MonitorDiskIO?
    public let volumes: [MonitorVolume]
    public let processes: [MonitorProcess]
    public let battery: MonitorBattery?
    public let gpuPercent: Double?
    public let sensors: MonitorSensors?
    public let thermalState: Int
    public let uptime: TimeInterval
    public let hardwareModel: String
    public let osVersion: String
    public let diagnostics: [String]
}

/// Pure calculations independently reconstructed from the retained behavior.
public enum MonitorMath {
    public static func cpuUsage(previous: [UInt32]?, current: [UInt32]) -> MonitorCPU {
        guard let previous, previous.count == current.count, !current.isEmpty, current.count.isMultiple(of: 4) else {
            return MonitorCPU()
        }
        var values: [Double] = []
        for offset in stride(from: 0, to: current.count, by: 4) {
            // A decreased tick counter means a new/reset baseline, rather than a negative load.
            guard (0..<4).allSatisfy({ current[offset + $0] >= previous[offset + $0] }) else {
                values.append(0); continue
            }
            let d = (0..<4).map { Double(current[offset + $0] - previous[offset + $0]) }
            let total = d.reduce(0, +)
            values.append(total > 0 ? (d[0] + d[1] + d[3]) / total * 100 : 0)
        }
        return MonitorCPU(usage: values.reduce(0, +) / Double(values.count), perCore: values, hasBaseline: true)
    }

    public static func rate(previous: UInt64?, current: UInt64, elapsed: TimeInterval) -> Double {
        guard let previous, current >= previous, elapsed.isFinite, elapsed > 0 else { return 0 }
        return Double(current - previous) / elapsed
    }

    public static func memoryUsed(active: UInt64, wired: UInt64, compressed: UInt64, pageSize: UInt64, total: UInt64) -> UInt64 {
        let (sum1, overflow1) = active.addingReportingOverflow(wired)
        let (sum2, overflow2) = sum1.addingReportingOverflow(compressed)
        let (bytes, overflow3) = sum2.multipliedReportingOverflow(by: pageSize)
        return overflow1 || overflow2 || overflow3 ? total : min(bytes, total)
    }
}
