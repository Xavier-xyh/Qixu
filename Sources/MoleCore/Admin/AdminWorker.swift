import Foundation
import Darwin

public enum AdminWorker {
    public static func execute(_ request: AdminRequest, shouldStop: @escaping () -> Bool = { false }) async -> AdminResponse {
        do {
            guard geteuid() == 0, request.version == 1, request.client.uid != 0, request.client.isAlive else { throw AdminError.invalid("必须由当前普通用户通过 macOS 管理员授权执行，且协议和进程身份有效。") }
            guard request.network == nil || [.refreshNetwork, .setServiceDNS, .restoreServiceDNS].contains(request.operation) else { throw AdminError.invalid("网络请求字段不适用于此操作。") }
            let storage = AdminStorage(); try storage.prepare()
            let lockURL = storage.root.appendingPathComponent([.hardwareLease, .recoverHardware].contains(request.operation) ? "hardware.lock" : "system.lock")
            let fd = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw AdminError.failed("无法建立管理员互斥锁。") }
            defer { Darwin.close(fd) }
            try storage.validate(lockURL)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw AdminError.unavailable("同类管理员操作仍在进行，请先停止或等待它完成。") }
            defer { flock(fd, LOCK_UN) }
            let uninstall = SystemUninstallEngine()
            switch request.operation {
            case .setServiceDNS, .restoreServiceDNS:
                guard let target = request.network, request.uninstall == nil, request.hardware == nil,
                      request.recordID == nil, request.reloadServices != true, !shouldStop(),
                      (request.operation == .setServiceDNS) == (request.dnsInput != nil) else {
                    throw AdminError.invalid("DNS 请求字段无效或操作已取消。")
                }
                return AdminResponse(succeeded: true, detail: try ServiceDNS.change(target: target, input: request.dnsInput, owner: request.client.uid))
            case .refreshNetwork:
                guard let target = request.network, request.uninstall == nil, request.hardware == nil,
                      request.recordID == nil, request.reloadServices != true, !shouldStop() else {
                    throw AdminError.invalid("网络重新协商请求字段无效或操作已取消。")
                }
                return AdminResponse(succeeded: true, detail: try NetworkConfiguration.refresh(target))
            case .inspectSystem:
                guard let application = request.uninstall?.application, request.hardware == nil, request.recordID == nil else { throw AdminError.invalid("管理员扫描请求字段无效。") }
                var response = AdminResponse(succeeded: true, detail: "已在管理员权限下补充只读扫描；请重新复核并选择系统项目。")
                response.plan = try await SystemUninstallPlanner().plan(application); return response
            case .hardwareCapabilities:
                var response = AdminResponse(succeeded: true, detail: "已在管理员权限下只读核对硬件协议，尚未写入硬件。")
                response.capabilities = try HardwareCapabilities.probe(); return response
            case .history:
                var response = AdminResponse(succeeded: true, detail: "已读取当前用户的管理员隔离记录。")
                response.records = try uninstall.records(owner: request.client.uid); return response
            case .quarantine:
                guard let plan = request.uninstall, request.hardware == nil, request.recordID == nil else { throw AdminError.invalid("卸载请求字段无效。") }
                let record = try await uninstall.quarantine(plan, owner: request.client.uid)
                var response = AdminResponse(succeeded: true, detail: "所选项目已隔离，可从管理员记录恢复。")
                response.records = [record]; return response
            case .restoreQuarantine:
                guard let id = request.recordID, request.hardware == nil, request.uninstall == nil else { throw AdminError.invalid("恢复请求字段无效。") }
                var record = try uninstall.restore(id: id, owner: request.client.uid)
                if record.phase == "restoreNeedsReview" {
                    var response = AdminResponse(succeeded: false, detail: "已恢复可处理的项目。请移开记录中标出的冲突，再继续恢复。")
                    response.records = [record]
                    return response
                }
                if request.reloadServices == true { record = try await uninstall.reloadServices(record) }
                var response = AdminResponse(succeeded: true, detail: request.reloadServices == true ? "文件已恢复，并核对了此前停止服务的重新加载结果。" : "文件已恢复；系统服务不会自动启动。")
                response.records = [record]; return response
            case .hardwareLease, .recoverHardware:
                let engine = try HardwareLeaseEngine(backend: LiveSMCControl()); engine.shouldStop = shouldStop
                var response = AdminResponse(succeeded: true, detail: "硬件会话已恢复原值。")
                if request.operation == .recoverHardware { response.hardware = try engine.recover(owner: request.client.uid) }
                else {
                    guard let hardware = request.hardware, request.uninstall == nil, request.recordID == nil else { throw AdminError.invalid("硬件会话请求字段无效。") }
                    response.hardware = try await engine.run(hardware, client: request.client)
                }
                return response
            }
        } catch { return AdminResponse(succeeded: false, detail: error.localizedDescription) }
    }
}
