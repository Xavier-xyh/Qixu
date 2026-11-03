import Foundation
import IOKit.ps
import Darwin

final class HardwareLeaseEngine {
    let backend: SMCControlBackend
    var storage = AdminStorage()
    var batteryPercent: () -> Int? = HardwareLeaseEngine.readBattery
    var shouldStop: () -> Bool = { false }
    var now: () -> TimeInterval = { Date().timeIntervalSince1970 }
    var wait: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    init(backend: SMCControlBackend) { self.backend = backend }
    private var file: URL { storage.root.appendingPathComponent("hardware-lease.json") }
    func recover(owner: UInt32) throws -> HardwareLeaseRecord? {
        try storage.prepare()
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var record = try storage.read(HardwareLeaseRecord.self, file: file)
        guard record.ownerUID == owner else { throw AdminError.invalid("未结束的硬件会话属于其他用户，请由该用户恢复。") }
        if record.phase == "restored" { return record }
        var failures: [String] = []
        for change in record.changes.reversed() {
            do {
                guard HardwareControlPolicy.writeKeys.contains(change.original.key) else { throw AdminError.invalid("恢复记录包含非控制键。") }
                let current = try backend.read(change.original.key)
                if HardwareControlPolicy.equivalent(current, change.original) { continue }
                guard HardwareControlPolicy.equivalent(current, change.intended) else { throw AdminError.invalid("该键已被其他控制器改变，不覆盖它。") }
                try backend.write(change.original)
                guard HardwareControlPolicy.equivalent(try backend.read(change.original.key), change.original) else { throw AdminError.failed("恢复读回不符。") }
            } catch { failures.append(change.original.key + ": " + error.localizedDescription) }
        }
        record.phase = failures.isEmpty ? "restored" : "needsReview"
        record.detail = failures.isEmpty ? "本会话改变的硬件键已恢复原值。" : failures.joined(separator: "\n")
        try storage.write(record, to: file)
        guard failures.isEmpty else { throw AdminError.failed("部分硬件状态未能恢复：\(record.detail)") }
        return record
    }
    func run(_ request: HardwareLeaseRequest, client: AdminProcessIdentity) async throws -> HardwareLeaseRecord {
        guard request.fanPercent != nil || request.chargeLimit != nil, (60...3600).contains(request.seconds),
              request.chargeLimit == nil || (50...95).contains(request.chargeLimit!) else { throw AdminError.invalid("硬件会话时长为 1–60 分钟，充电上限为 50–95%。") }
        try storage.prepare()
        if FileManager.default.fileExists(atPath: file.path) {
            let old = try storage.read(HardwareLeaseRecord.self, file: file)
            guard old.phase == "restored" else { throw AdminError.unavailable("先复核并恢复上次未结束的硬件会话，再开启新的会话。") }
        }
        let capabilities = try HardwareControlPolicy.probe(backend)
        guard client.isAlive, !shouldStop(), !stopRequested(request, client: client) else { throw AdminError.unavailable("会话已在写入前停止。") }
        if request.fanPercent != nil { guard !capabilities.fans.isEmpty, capabilities.fans.count == capabilities.reportedFanCount else { throw AdminError.unavailable("设备无风扇或部分风扇协议未知，未写入。") } }
        if request.fanPercent != nil, capabilities.fans.contains(where: { ![[UInt8(0)], [UInt8(3)]].contains($0.mode.bytes) }) { throw AdminError.unavailable("风扇已处于其他手动控制状态，请先由原控制器恢复自动模式。") }
        if request.chargeLimit != nil { guard !capabilities.chargingKeys.isEmpty, batteryPercent() != nil else { throw AdminError.unavailable("充电协议或电池百分比不可确认，未写入。") } }
        if request.chargeLimit != nil {
            for key in capabilities.chargingKeys { guard try backend.read(key).bytes.allSatisfy({ $0 == 0 }) else { throw AdminError.unavailable("充电已被其他控制器暂停，请先由原控制器恢复。") } }
        }
        var values: [SMCControlValue] = []
        if let percent = request.fanPercent {
            for fan in capabilities.fans {
                values.append(try HardwareControlPolicy.fanTarget(fan, percent: percent))
                var forced = fan.mode; forced.bytes = [1]; values.append(forced)
            }
        }
        for key in request.chargeLimit == nil ? [] : capabilities.chargingKeys { values.append(try backend.read(key)) }
        var record = try HardwareLeaseRecord(id: request.id, ownerUID: client.uid, date: Date(), phase: "prepared", detail: "已记录原始状态，尚未确认写入。", changes: values.map { HardwareKeyChange(original: try backend.read($0.key), intended: $0) })
        try storage.write(record, to: file) // Must precede the first hardware write.
        let deadline = now() + Double(request.seconds)
        let monotonicDeadline = ProcessInfo.processInfo.systemUptime + Double(request.seconds)
        var failure: Error?
        do {
            for value in values where value.key.hasPrefix("F") {
                guard client.isAlive, !shouldStop(), !stopRequested(request, client: client) else { throw AdminError.unavailable("已停止后续写入，恢复已完成步骤。") }
                try apply(value, record: &record)
            }
            var holding: Bool?
            while now() < deadline, ProcessInfo.processInfo.systemUptime < monotonicDeadline, client.isAlive, !shouldStop(), !stopRequested(request, client: client) {
                try Task.checkCancellation()
                if request.fanPercent != nil, ProcessInfo.processInfo.thermalState == .critical { throw AdminError.unavailable("系统进入严重热状态，结束手动风扇会话并恢复。") }
                if let limit = request.chargeLimit {
                    guard let percent = batteryPercent(), (0...100).contains(percent) else { throw AdminError.unavailable("电池读数不可用，结束充电控制并恢复。") }
                    let next = percent >= limit ? true : percent <= limit - 5 ? false : (holding ?? (percent >= limit))
                    if next != holding {
                        for key in capabilities.chargingKeys { try apply(HardwareControlPolicy.chargeValue(backend.read(key), hold: next), record: &record) }
                        holding = next
                    }
                }
                if record.phase != "active" {
                    record.phase = "active"; record.detail = "硬件会话生效中；到时、停止或客户端退出后恢复原值。"; try storage.write(record, to: file)
                }
                try await wait()
            }
        } catch { failure = error }
        // Cancellation cannot skip restoration; all restore calls are synchronous.
        let restored = try recover(owner: client.uid)!
        if let failure { throw AdminError.failed("会话因错误提前结束；\(restored.detail) \(failure.localizedDescription)") }
        return restored
    }
    private func apply(_ value: SMCControlValue, record: inout HardwareLeaseRecord) throws {
        guard let index = record.changes.firstIndex(where: { $0.original.key == value.key }) else { throw AdminError.invalid("不在会话快照中的硬件键。") }
        let current = try backend.read(value.key), change = record.changes[index]
        guard HardwareControlPolicy.equivalent(current, change.original) || HardwareControlPolicy.equivalent(current, change.intended) else { throw AdminError.invalid("检测到其他硬件控制器修改，停止本会话。") }
        record.changes[index].intended = value
        try storage.write(record, to: file)
        if !HardwareControlPolicy.equivalent(current, value) { try backend.write(value) }
        guard HardwareControlPolicy.equivalent(try backend.read(value.key), value) else { throw AdminError.failed("SMC 写入读回验证失败：\(value.key)") }
    }
    private func stopRequested(_ request: HardwareLeaseRequest, client: AdminProcessIdentity) -> Bool {
        var st = stat()
        return lstat(request.stopFile(uid: client.uid).path, &st) == 0 && st.st_uid == client.uid && st.st_mode & S_IFMT == S_IFREG && st.st_size == 0
    }
    private static func readBattery() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any] else { return nil }
        for source in sources {
            guard let p = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any], p[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = p[kIOPSCurrentCapacityKey] as? NSNumber, let maximum = p[kIOPSMaxCapacityKey] as? NSNumber, maximum.doubleValue > 0 else { continue }
            return Int((current.doubleValue / maximum.doubleValue * 100).rounded())
        }
        return nil
    }
}
