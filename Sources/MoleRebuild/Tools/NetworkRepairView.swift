import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MoleCore

@MainActor private final class NetworkRepairModel: ObservableObject {
    static let shared = NetworkRepairModel()
    @Published var local: NetworkLocalState?
    @Published var diagnosis: NetworkDiagnosis?
    @Published var selectedService: String?
    @Published var busy = false
    @Published var phase = "先读取本机配置，或按需进行联网检测。"
    @Published var error: String?
    @Published var operationOutput = ""
    @Published var repairReceipt: NetworkRepairReceipt?
    private var task: Task<Void, Never>?
    var service: NetworkServiceState? { local?.services.first { $0.id == selectedService } }
    var report: String { repairReceipt.map { $0.report + "\n\n当前检测\n" + (diagnosis?.report ?? local?.report ?? "") } ?? (diagnosis?.report ?? local?.report ?? "") }

    func run(_ title: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; phase = title; error = nil
        task = Task {
            defer { busy = false; task = nil }
            do { try await action(); try Task.checkCancellation() }
            catch is CancellationError { phase = "已停止等待。若已发送管理员操作，已完成的步骤不会撤销，请重新读取配置。" }
            catch { self.error = error.localizedDescription; phase = "操作未完成。" }
        }
    }
    func accept(_ state: NetworkLocalState) {
        local = state
        if !state.services.contains(where: { $0.id == selectedService && $0.canRefresh }) { selectedService = state.preferredTarget?.serviceID }
    }
    func read() {
        run("读取本机网络配置…") { [self] in
            let state = try await Task.detached { try NetworkConfiguration.read() }.value
            try Task.checkCancellation(); accept(state); diagnosis = nil
            phase = "本机配置已读取，尚未进行联网检测。"
        }
    }
    func diagnose() {
        run("检测本机、网关、域名解析与 HTTPS…") { [self] in
            let result = try await NetworkDiagnosticService().diagnose()
            try Task.checkCancellation(); accept(result.local); diagnosis = result
            phase = "检测结束于 \(result.local.date.formatted(date: .omitted, time: .shortened))。按下方分项结果复核。"
        }
    }
    func repair(dhcp target: NetworkRefreshTarget?) {
        let title = target == nil ? "刷新 DNS 缓存" : "重新协商 DHCP"
        run("\(title)…") { [self] in
            do {
                diagnosis = nil
                let result = try await NetworkRepairWorkflow().execute(target.map(NetworkRepairAction.dhcp) ?? .dns) { [self] text in
                    await MainActor.run { self.phase = text }
                }
                repairReceipt = result; operationOutput = result.operationDetail
                diagnosis = result.after; accept(result.after?.local ?? result.before.local)
                phase = result.summary
                await ActivityStore.shared.append(ActivityRecord(category: "网络修复", title: title,
                    detail: result.report, succeeded: true))
            } catch {
                diagnosis = nil
                await ActivityStore.shared.append(ActivityRecord(category: "网络修复", title: title, detail: error.localizedDescription, succeeded: false))
                throw error
            }
        }
    }
    func changeDNS(_ service: NetworkServiceState, input: String?) {
        let title = input == nil ? "恢复服务 DNS" : "修改服务 DNS"
        run(title + "…") { [self] in
            var request = try AdminRequest(operation: input == nil ? .restoreServiceDNS : .setServiceDNS, network: service.target)
            request.dnsInput = input
            let response = try await AdminClient().execute(request)
            guard response.succeeded else { throw ToolOperationError.invalid(response.detail) }
            diagnosis = nil
            repairReceipt = nil
            operationOutput = response.detail
            phase = response.detail
            await ActivityStore.shared.append(ActivityRecord(category: "网络修复", title: title, detail: response.detail))
            if let updated = try? await Task.detached(operation: { try NetworkConfiguration.read() }).value {
                accept(updated)
            }
        }
    }
    func cancel() { task?.cancel() }
    func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Qixu-网络诊断.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
    }
}

struct NetworkRepairView: View {
    @StateObject private var model = NetworkRepairModel.shared
    @State private var confirmation: RepairConfirmation?
    @State private var dnsServiceID: String?
    @State private var dnsInput = ""
    @State private var dnsConfirmation: DNSConfirmation?

    private struct DNSConfirmation: Identifiable {
        let id = UUID()
        let service: NetworkServiceState
        let input: String?
    }

    private var dnsService: NetworkServiceState? {
        model.local?.services.first { $0.id == dnsServiceID && $0.enabled && $0.physical }
    }

    private var dnsControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("按网络服务设置 DNS").font(.headline)
            Picker("网络服务", selection: $dnsServiceID) {
                Text("选择网络服务").tag(nil as String?)
                ForEach(model.local?.services.filter { $0.enabled && $0.physical } ?? []) { service in
                    Text("\(service.name)（\(service.target.interfaceName)）").tag(Optional(service.id))
                }
            }.frame(maxWidth: 410)
            if let service = dnsService {
                Text("手动 DNS：" + (service.configuredDNS?.joined(separator: ", ") ?? "未设置"))
                    .font(.caption).foregroundStyle(.secondary)
                TextField("输入 DNS 地址，以空格或逗号分隔", text: $dnsInput)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("复核并设置…") {
                        dnsConfirmation = DNSConfirmation(service: service, input: dnsInput)
                    }.disabled((try? ServiceDNS.addresses(dnsInput)) == nil)
                    Button("恢复原 DNS…") {
                        dnsConfirmation = DNSConfirmation(service: service, input: nil)
                    }
                }
            } else {
                Text("先读取本机配置，再选择 Wi-Fi 或以太网服务。").font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(model.busy)
    }
    private struct RepairConfirmation: Identifiable {
        let id = UUID()
        let service: NetworkServiceState?
        var title: String { service == nil ? "刷新 DNS 缓存？" : "重新协商 DHCP？" }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("网络诊断与修复", systemImage: "network").font(.title2.bold())
                        Text("分步检查地址、网关、DNS 与 HTTPS，再选择对应的修复操作。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small); Button("停止等待") { model.cancel() } }
                    else {
                        Button("读取本机配置") { model.read() }
                        Button("检测网络", systemImage: "stethoscope") { model.diagnose() }.buttonStyle(.borderedProminent)
                    }
                }
                Text("联网检测会查询 www.apple.com 并请求 Apple HTTPS 检测地址；网关检测发送两次 ICMP。不会自动修改配置。").font(.caption).foregroundStyle(.secondary)
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
                if let local = model.local {
                    GroupBox("当前网络") {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                            info("主接口", local.primaryInterfaces.joined(separator: ", "))
                            info("本机地址", local.addresses.joined(separator: ", "))
                            info("默认网关", local.gateways.joined(separator: ", "))
                            info("DNS 服务器", local.dnsServers.joined(separator: ", "))
                            info("系统代理", local.proxyKinds.isEmpty ? "未启用全局代理" : local.proxyKinds.joined(separator: ", "))
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        Text("显示全局及主服务配置；VPN 分域 DNS、应用专用代理和虚拟网卡可能另有规则。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                if let receipt = model.repairReceipt {
                    GroupBox("最近一次修复验证") {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(receipt.summary, systemImage: receipt.connectivityVerified ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(receipt.connectivityVerified ? Color.green : Color.orange)
                            Text("\(receipt.title) · \(receipt.before.local.date.formatted(date: .omitted, time: .shortened)) → \(receipt.after?.local.date.formatted(date: .omitted, time: .shortened) ?? "复测未完成")").font(.caption).foregroundStyle(.secondary)
                            ForEach(receipt.before.checks) { before in
                                HStack {
                                    Text(before.title); Spacer()
                                    Text("\(status(before.state)) → \(receipt.after?.checks.first(where: { $0.id == before.id }).map { status($0.state) } ?? "未完成")").foregroundStyle(.secondary)
                                }.font(.callout)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                if let diagnosis = model.diagnosis {
                    Label(nextStep(diagnosis), systemImage: "arrow.turn.down.right")
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(diagnosis.checks) { check in
                            VStack(alignment: .leading, spacing: 9) {
                                Label(check.title, systemImage: symbol(check.state)).font(.headline).foregroundStyle(color(check.state))
                                Text(check.detail).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                GroupBox("按症状修复") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("域名解析异常").font(.headline)
                                Text("清空本机 DNS 缓存并通知系统解析服务重新加载。需要管理员授权。").font(.callout).foregroundStyle(.secondary)
                            }; Spacer()
                            Button("刷新 DNS 缓存…") { confirmation = RepairConfirmation(service: nil) }.disabled(model.busy || !MaintenanceAction.dns.isAvailable)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 9) {
                            Text("未获得有效地址 / DHCP 超时").font(.headline)
                            Text("通知已启用的 Wi-Fi 或以太网 DHCP 客户端立即重试。可能短暂影响连接；保留静态地址、DNS 和代理设置。系统接受请求不代表已经续租成功。").font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Picker("网络服务", selection: $model.selectedService) {
                                    Text("选择 DHCP 网络服务").tag(nil as String?)
                                    ForEach(model.local?.services.filter(\.canRefresh) ?? []) { service in
                                        Text("\(service.name)（\(service.target.interfaceName)）").tag(Optional(service.id))
                                    }
                                }.frame(maxWidth: 410).disabled(model.busy)
                                Spacer()
                                Button("重新协商 DHCP…") { if let service = model.service, service.canRefresh { confirmation = RepairConfirmation(service: service) } }
                                    .disabled(model.busy || model.service?.canRefresh != true)
                            }
                            if model.local == nil { Text("先读取本机配置，确定网卡和获取地址方式。").font(.caption).foregroundStyle(.secondary) }
                            else if model.local?.services.contains(where: \.canRefresh) != true { Text("未发现可重新协商的 DHCP 服务；静态 IP、停用网卡及 VPN 不在操作范围。").font(.caption).foregroundStyle(.secondary) }
                        }
                        Divider()
                        dnsControls
                        Divider()
                        Text("代理 / VPN / Wi-Fi 登录异常：在系统网络设置中核对对应项目。公共网络可能需要先完成网页认证。").font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("打开网络设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!) }
                            Button("无线诊断") { openWirelessDiagnostics() }
                            Spacer()
                            Button("导出诊断报告…") { model.export() }.disabled(model.local == nil || model.busy)
                        }
                        Text("报告包含本机 IP、网关和 DNS 地址，分享前请检查内容。").font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                if !model.operationOutput.isEmpty {
                    DisclosureGroup("修复输出") { Text(model.operationOutput).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                Text(model.phase).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .topLeading).padding(.trailing, 8).padding(.bottom, 12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $dnsConfirmation) { item in
            VStack(alignment: .leading, spacing: 16) {
                Text(item.input == nil ? "恢复原 DNS" : "设置 DNS").font(.title2.bold())
                Text("\(item.service.name)（\(item.service.target.interfaceName)）")
                Text(item.input ?? "恢复此服务由 Qixu 备份的 DNS 地址设置。")
                    .textSelection(.enabled)
                Text("系统将请求管理员授权。DNS 变更可能影响域名解析。").foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("取消") { dnsConfirmation = nil }.keyboardShortcut(.cancelAction)
                    Button("授权并执行") {
                        dnsConfirmation = nil
                        model.changeDNS(item.service, input: item.input)
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 540)
        }
        .sheet(item: $confirmation) { item in
            VStack(alignment: .leading, spacing: 18) {
                Label(item.title, systemImage: "network").font(.title2.bold())
                if let service = item.service {
                    Text("目标：\(service.name)（\(service.target.interfaceName)）。只通知当前 DHCP 客户端立即重试配置，可能短暂影响连接。执行前会重新核对网络位置、网卡与 DHCP 模式；不会将静态地址转换为自动获取。")
                } else { Text("清空名称缓存并通知 mDNSResponder 重新加载。之后的域名请求会重新解析；不会更改 DNS 服务器。") }
                Label("系统将请求管理员授权", systemImage: "lock.shield").foregroundStyle(.orange)
                HStack { Spacer(); Button("取消") { confirmation = nil }.keyboardShortcut(.cancelAction); Button("授权并执行") { confirmation = nil; model.repair(dhcp: item.service?.target) }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 580)
        }
    }
    private func info(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).foregroundStyle(.secondary); Text(value.isEmpty ? "未读到" : value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.font(.callout)
    }
    private func nextStep(_ diagnosis: NetworkDiagnosis) -> String {
        func state(_ id: String) -> NetworkCheck.State? {
            diagnosis.checks.first { $0.id == id }?.state
        }
        if state("local") == .warning {
            return "先确认 Wi-Fi 或网线已连接。若该服务使用 DHCP，可尝试重新协商。"
        }
        if state("dns") == .failed || state("dns") == .warning {
            return state("gateway") == .passed
                ? "网关有响应，但域名解析未通过。先刷新 DNS 缓存，再检查当前服务的 DNS 和 VPN 设置。"
                : "域名解析未通过。先确认网络连接与网关，再检查 DNS 设置。"
        }
        if state("https") == .failed || state("https") == .warning {
            return "域名解析与网页访问是不同步骤。请检查代理、VPN 或需要登录的公共网络。"
        }
        if state("gateway") == .warning {
            return "网关未回应探测，部分网络会限制这种探测。若网页能打开，可保持当前设置。"
        }
        return "当前检测未发现需要修复的项目。"
    }

    private func symbol(_ state: NetworkCheck.State) -> String {
        switch state { case .passed: return "checkmark.circle.fill"; case .warning: return "exclamationmark.triangle.fill"; case .failed: return "xmark.circle.fill"; case .skipped: return "minus.circle" }
    }
    private func status(_ state: NetworkCheck.State) -> String {
        switch state { case .passed: return "通过"; case .warning: return "需复核"; case .failed: return "失败"; case .skipped: return "未检测" }
    }
    private func color(_ state: NetworkCheck.State) -> Color {
        switch state { case .passed: return .green; case .warning: return .orange; case .failed: return .red; case .skipped: return .secondary }
    }
    private func openWirelessDiagnostics() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Wireless Diagnostics.app")
        guard FileManager.default.fileExists(atPath: url.path) else { model.error = "此系统未提供无线诊断；请在 Wi-Fi 菜单中检查诊断选项。"; return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error { Task { @MainActor in model.error = error.localizedDescription } }
        }
    }
}
