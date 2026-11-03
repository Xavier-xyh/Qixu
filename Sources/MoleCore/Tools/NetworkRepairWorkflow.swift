import Foundation

public enum NetworkRepairAction: Sendable {
    case dns
    case dhcp(NetworkRefreshTarget)
    public var title: String {
        switch self { case .dns: return "刷新 DNS 缓存"; case .dhcp: return "重新协商 DHCP" }
    }
}

public struct NetworkRepairReceipt: Sendable {
    public let title: String
    public let before: NetworkDiagnosis
    public let operationDetail: String
    public let after: NetworkDiagnosis?
    public let verificationIssue: String?
    public var connectivityVerified: Bool {
        guard let after else { return false }
        return ["local", "dns", "https"].allSatisfy { id in after.checks.contains { $0.id == id && $0.state == .passed } }
    }
    public var summary: String {
        if connectivityVerified {
            let alreadyPassed = ["local", "dns", "https"].allSatisfy { id in before.checks.contains { $0.id == id && $0.state == .passed } }
            return alreadyPassed ? "操作已执行；地址、DNS 和 HTTPS 在修复前后均通过，不能据此证明原先存在故障。" : "操作已执行；地址、DNS 和 HTTPS 复测通过。"
        }
        return "操作已执行，网络恢复尚未确认。" + (verificationIssue.map { "复测未完成：" + $0 } ?? "请查看复测中的异常项目。")
    }
    public var report: String {
        "\(title)\n\(summary)\n\n修复前\n\(before.report)\n\n执行结果\n\(operationDetail)\n\n修复后\n\(after?.report ?? verificationIssue ?? "未完成复测")"
    }
}

/// Operation completion and connectivity verification are separate outcomes.
/// A failed/cancelled post-check must never relabel an already executed action
/// as not having happened, or cause the privileged action to be run a second time.
public struct NetworkRepairWorkflow: Sendable {
    var diagnose: @Sendable () async throws -> NetworkDiagnosis
    var perform: @Sendable (NetworkRepairAction) async throws -> String
    var settle: @Sendable () async throws -> Void
    public init() {
        diagnose = { try await NetworkDiagnosticService().diagnose() }
        settle = { try await Task.sleep(for: .seconds(2)) }
        perform = { action in
            switch action {
            case .dns:
                return try await MaintenanceService().execute(.dns).map { "$ \($0.command)\n\($0.output)\n退出码 \($0.exitCode)" }.joined(separator: "\n")
            case .dhcp(let target):
                let response = try await AdminClient().execute(AdminRequest(operation: .refreshNetwork, network: target), timeout: 120)
                guard response.succeeded else { throw ToolOperationError.failed(response.detail) }
                return response.detail
            }
        }
    }
    public func execute(_ action: NetworkRepairAction, progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> NetworkRepairReceipt {
        await progress("修复前检测…")
        let before = try await diagnose()
        try Task.checkCancellation()
        if case .dhcp(let target) = action {
            guard before.local.services.contains(where: { $0.target == target && $0.canRefresh }) else {
                throw ToolOperationError.invalid("目标网络服务已改变，请重新读取后复核 DHCP 操作。")
            }
        }
        await progress("\(action.title)：等待授权与执行…")
        let detail = try await perform(action)
        await progress("操作已执行，等待网络稳定并自动复测…")
        do {
            try await settle()
            try Task.checkCancellation()
            let after = try await diagnose()
            return NetworkRepairReceipt(title: action.title, before: before, operationDetail: detail, after: after, verificationIssue: nil)
        } catch {
            return NetworkRepairReceipt(title: action.title, before: before, operationDetail: detail, after: nil,
                verificationIssue: error is CancellationError ? "用户停止等待；已完成操作保留。" : error.localizedDescription)
        }
    }
}
