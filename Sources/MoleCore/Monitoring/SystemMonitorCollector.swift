import Foundation
import Darwin
import IOKit
import IOKit.ps

public actor SystemMonitorCollector {
    private var previousCPU: [UInt32]?
    private var previousNetwork: [String: (UInt64, UInt64)] = [:]
    private var previousNetworkDate: Date?
    private var previousDisk: (UInt64, UInt64)?
    private var previousDiskDate: Date?
    private var previousProcesses: [Int32: (UInt64, UInt64)] = [:]
    private var previousProcessDate: Date?
    private var cachedProcesses: [MonitorProcess] = []
    private var cachedVolumes: [MonitorVolume] = []
    private var volumeDate: Date?
    private var cachedBattery: MonitorBattery?
    private var batteryDate: Date?
    private var cachedGPU: Double?
    private var hardware: String?
    private var coreGroups: [MonitorCPUGroup]?
    private var cachedSensors: MonitorSensors?
    private var sensorDate: Date?

    public init() {}

    public func collect(includeProcesses: Bool = true) -> MonitorSnapshot {
        let now = Date()
        var issues: [String] = []
        let cpu = readCPU(issues: &issues)
        let memory = readMemory(issues: &issues)
        let network = readNetwork(now: now, issues: &issues)
        let io = readDiskIO(now: now, issues: &issues)
        if volumeDate == nil || now.timeIntervalSince(volumeDate!) >= 30 {
            cachedVolumes = readVolumes(issues: &issues); volumeDate = now
        }
        if batteryDate == nil || now.timeIntervalSince(batteryDate!) >= 10 {
            cachedBattery = readBattery(); cachedGPU = readGPU(); batteryDate = now
        }
        if sensorDate == nil || now.timeIntervalSince(sensorDate!) >= 5 {
            cachedSensors = ReadOnlySMCSensors.collect(); sensorDate = now
        }
        if includeProcesses && (previousProcessDate == nil || now.timeIntervalSince(previousProcessDate!) >= 1.8) {
            cachedProcesses = readProcesses(now: now)
        }
        if hardware == nil { hardware = sysctlString("hw.model") ?? "Mac" }
        return MonitorSnapshot(date: now, cpu: cpu, memory: memory, network: network, diskIO: io,
                               volumes: cachedVolumes, processes: includeProcesses ? cachedProcesses : [],
                               battery: cachedBattery, gpuPercent: cachedGPU, sensors: cachedSensors,
                               thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                               uptime: ProcessInfo.processInfo.systemUptime, hardwareModel: hardware ?? "Mac",
                               osVersion: ProcessInfo.processInfo.operatingSystemVersionString, diagnostics: issues)
    }

    private func readCPU(issues: inout [String]) -> MonitorCPU? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var length: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &length)
        guard result == KERN_SUCCESS, let info else { issues.append("无法读取 CPU tick（\(result)）"); return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(length) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let ticks = (0..<Int(length)).map { UInt32(bitPattern: info[$0]) }
        var value = MonitorMath.cpuUsage(previous: previousCPU, current: ticks)
        if coreGroups == nil { coreGroups = readCoreGroups() }
        value.coreGroups = coreGroups ?? []
        previousCPU = ticks
        var loads = [Double](repeating: 0, count: 3)
        let loadCount = getloadavg(&loads, 3)
        value.loads = loadCount == 3 ? loads : []
        return value
    }

    private func readCoreGroups() -> [MonitorCPUGroup] {
        guard let count = sysctlInt32("hw.nperflevels"), (1...32).contains(count) else { return [] }
        return (0..<count).compactMap { level in
            let prefix = "hw.perflevel\(level)"
            guard let logical = sysctlInt32(prefix + ".logicalcpu"), logical > 0 else { return nil }
            let physical = sysctlInt32(prefix + ".physicalcpu").flatMap { $0 > 0 ? Int($0) : nil }
            // Never infer core kinds from a level's numeric position or map group counts to Mach indices.
            return MonitorCPUGroup(level: Int(level), name: sysctlString(prefix + ".name") ?? "",
                                   logicalCount: Int(logical), physicalCount: physical)
        }
    }

    private func readMemory(issues: inout [String]) -> MonitorMemory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { issues.append("无法读取内存统计（\(result)）"); return nil }
        let rawPage = sysconf(_SC_PAGESIZE)
        guard rawPage > 0 else { issues.append("无法读取系统页大小"); return nil }
        let page = UInt64(rawPage)
        let total = ProcessInfo.processInfo.physicalMemory
        let used = MonitorMath.memoryUsed(active: UInt64(stats.active_count), wired: UInt64(stats.wire_count), compressed: UInt64(stats.compressor_page_count), pageSize: page, total: total)
        let pressure = total > 0 ? min(100, Double(UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * Double(page) / Double(total) * 100) : 0
        var level: Int32 = 1; var levelSize = MemoryLayout.size(ofValue: level)
        let pressureResult = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
        var swap = xsw_usage(); var swapSize = MemoryLayout.size(ofValue: swap)
        let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        if pressureResult != 0 { issues.append("系统内存压力等级暂不可用") }
        if swapResult != 0 { issues.append("交换空间统计暂不可用") }
        return MonitorMemory(used: used, total: total, pressurePercent: pressure,
                             pressureLevel: pressureResult == 0 ? Int(level) : -1,
                             swapUsed: swapResult == 0 ? swap.xsu_used : nil,
                             swapTotal: swapResult == 0 ? swap.xsu_total : nil)
    }

    private func readNetwork(now: Date, issues: inout [String]) -> [MonitorNetwork] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { issues.append("无法枚举网络接口"); return [] }
        defer { freeifaddrs(first) }
        var counters: [String: (UInt64, UInt64)] = [:]
        var addresses: [String: String] = [:]
        var item = first
        while let current = item {
            defer { item = current.pointee.ifa_next }
            let interface = current.pointee
            guard let address = interface.ifa_addr, let namePointer = interface.ifa_name else { continue }
            let name = String(cString: namePointer)
            guard interface.ifa_flags & UInt32(IFF_UP) != 0, interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            if address.pointee.sa_family == UInt8(AF_LINK), let data = interface.ifa_data {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                counters[name] = (UInt64(stats.ifi_ibytes), UInt64(stats.ifi_obytes))
            } else if address.pointee.sa_family == UInt8(AF_INET) {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses[name] = String(cString: buffer)
                }
            }
        }
        let elapsed = previousNetworkDate.map { now.timeIntervalSince($0) } ?? 0
        let result = counters.map { name, value in
            MonitorNetwork(name: name,
                           receivedPerSecond: MonitorMath.rate(previous: previousNetwork[name]?.0, current: value.0, elapsed: elapsed),
                           sentPerSecond: MonitorMath.rate(previous: previousNetwork[name]?.1, current: value.1, elapsed: elapsed),
                           receivedTotal: value.0, sentTotal: value.1, ipv4: addresses[name])
        }.sorted { ($0.receivedPerSecond + $0.sentPerSecond) > ($1.receivedPerSecond + $1.sentPerSecond) }
        previousNetwork = counters; previousNetworkDate = now
        return result
    }

    private func readDiskIO(now: Date, issues: inout [String]) -> MonitorDiskIO? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            issues.append("磁盘驱动 I/O 统计暂不可用"); return nil
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0; var written: UInt64 = 0; var found = false
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let properties = registryProperties(service), let statistics = properties["Statistics"] as? [String: Any] else { continue }
            if let bytes = statistics["Bytes (Read)"] as? NSNumber { read = read &+ bytes.uint64Value; found = true }
            if let bytes = statistics["Bytes (Write)"] as? NSNumber { written = written &+ bytes.uint64Value; found = true }
        }
        guard found else { return nil }
        let elapsed = previousDiskDate.map { now.timeIntervalSince($0) } ?? 0
        let result = MonitorDiskIO(readPerSecond: MonitorMath.rate(previous: previousDisk?.0, current: read, elapsed: elapsed),
                                   writePerSecond: MonitorMath.rate(previous: previousDisk?.1, current: written, elapsed: elapsed),
                                   hasBaseline: previousDisk != nil && elapsed > 0)
        previousDisk = (read, written); previousDiskDate = now
        return result
    }

    private func readVolumes(issues: inout [String]) -> [MonitorVolume] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsInternalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) else {
            issues.append("无法读取挂载卷"); return []
        }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity, total > 0 else { return nil }
            return MonitorVolume(path: url.path, name: values.volumeName ?? url.lastPathComponent,
                                 total: Int64(total), available: Int64(available), isInternal: values.volumeIsInternal ?? false)
        }.sorted { $0.path == "/" ? true : ($1.path == "/" ? false : $0.name.localizedStandardCompare($1.name) == .orderedAscending) }
    }

    private func readProcesses(now: Date) -> [MonitorProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard actual > 0 else { return [] }
        let elapsed = previousProcessDate.map { now.timeIntervalSince($0) } ?? 0
        var samples: [Int32: (UInt64, UInt64)] = [:]
        var output: [MonitorProcess] = []
        for pid in pids.prefix(Int(actual)) where pid > 0 {
            var info = proc_taskinfo()
            let length = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, length) == length else { continue }
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let hasPath = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0
            let path = hasPath ? String(cString: pathBuffer) : nil
            var nameBuffer = [CChar](repeating: 0, count: 1024)
            let hasName = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count)) > 0
            let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? (hasName ? String(cString: nameBuffer) : "PID \(pid)")
            let total = info.pti_total_user &+ info.pti_total_system
            var identity = proc_bsdinfo()
            let identityLength = Int32(MemoryLayout<proc_bsdinfo>.size)
            let hasIdentity = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &identity, identityLength) == identityLength
            let start = hasIdentity ? identity.pbi_start_tvsec &* 1_000_000 &+ identity.pbi_start_tvusec : 0
            let old = previousProcesses[pid]
            let previousTotal = hasIdentity && old?.1 == start ? old?.0 : nil
            let cpu = MonitorMath.rate(previous: previousTotal, current: total, elapsed: elapsed) / 1_000_000_000 * 100
            samples[pid] = (total, start)
            output.append(MonitorProcess(pid: pid, name: name, path: path, cpuPercent: cpu,
                                         residentBytes: info.pti_resident_size, threadCount: Int(info.pti_threadnum)))
        }
        previousProcesses = samples; previousProcessDate = now
        return output.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private func readBattery() -> MonitorBattery? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let p = registryProperties(service) else { return nil }
        func n(_ key: String) -> Double? { (p[key] as? NSNumber)?.doubleValue }
        let rawCurrent = n("AppleRawCurrentCapacity"), rawMax = n("AppleRawMaxCapacity")
        let useRaw = rawCurrent != nil && rawMax != nil
        let current = useRaw ? rawCurrent : n("CurrentCapacity"), maximum = useRaw ? rawMax : n("MaxCapacity")
        let charge = current.flatMap { c in maximum.flatMap { $0 > 0 ? min(100, max(0, c / $0 * 100)) : nil } }
        let health = (n("NominalChargeCapacity") ?? rawMax).flatMap { m in n("DesignCapacity").flatMap { $0 > 0 ? min(100, max(0, m / $0 * 100)) : nil } }
        return MonitorBattery(chargePercent: charge, healthPercent: health, cycles: (p["CycleCount"] as? NSNumber)?.intValue,
                              isCharging: (p["IsCharging"] as? NSNumber)?.boolValue ?? false,
                              isExternalConnected: (p["ExternalConnected"] as? NSNumber)?.boolValue ?? false,
                              temperatureCelsius: readPublicBatteryTemperature())
    }

    private func readPublicBatteryTemperature() -> Double? {
        // IOPSKeys.h explicitly defines this description key in degrees C. The same-named
        // private AppleSmartBattery registry property has no SDK unit guarantee and is not used.
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let number = description[kIOPSTemperatureKey] as? NSNumber else { continue }
            let value = number.doubleValue
            if value.isFinite, (-40...100).contains(value) { return value }
        }
        return nil
    }

    private func readGPU() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var values: [Double] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let p = registryProperties(service), let stats = p["PerformanceStatistics"] as? [String: Any] else { continue }
            for key in ["Device Utilization %", "GPU Activity(%)"] {
                if let n = stats[key] as? NSNumber, n.doubleValue.isFinite, (0...100).contains(n.doubleValue) { values.append(n.doubleValue); break }
            }
        }
        return values.max()
    }

    private func registryProperties(_ service: io_registry_entry_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    private func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    private func sysctlInt32(_ key: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else { return nil }
        return value
    }
}
