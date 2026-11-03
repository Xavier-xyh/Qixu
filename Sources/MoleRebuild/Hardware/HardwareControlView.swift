import SwiftUI
import MoleCore

@MainActor private final class HardwareControlModel: ObservableObject {
    static let shared = HardwareControlModel()
    @Published var capability: HardwareCapabilities?
    @Published var busy = false
    @Published var phase = "先读取本机能力；此步骤不会写入硬件。"
    @Published var error: String?
    @Published var fan = false
    @Published var charging = false
    @Published var fanPercent = 60.0
    @Published var chargeLimit = 80
    @Published var minutes = 30
    private var lease: HardwareLeaseRequest?
    func probe() {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { capability = try await Task.detached { try HardwareCapabilities.probe() }.value; phase = "能力读取完成；尚未执行硬件控制。" }
            catch { self.error = error.localizedDescription }
        }
    }
    func probeAdministrator() {
        guard !busy else { return }; busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let response = try await AdminClient().execute(AdminRequest(operation: .hardwareCapabilities))
                capability = response.capabilities; phase = response.detail
                if !response.succeeded { error = response.detail }
            } catch { self.error = error.localizedDescription }
        }
    }
    func start() {
        guard !busy, fan || charging else { return }
        let request = HardwareLeaseRequest(fanPercent: fan ? Int(fanPercent) : nil, chargeLimit: charging ? chargeLimit : nil, seconds: minutes * 60)
        lease = request; busy = true; error = nil; phase = "会话请求进行中；授权后按所选时限运行，结束时核对恢复结果。"
        Task {
            defer { busy = false; lease = nil }
            do {
                let response = try await AdminClient().execute(AdminRequest(operation: .hardwareLease, hardware: request), timeout: Double(request.seconds + 600))
                phase = response.detail
                if !response.succeeded { error = response.detail }
                await ActivityStore.shared.append(ActivityRecord(category: "硬件控制", title: "硬件会话结束", detail: response.detail, succeeded: response.succeeded))
            } catch { self.error = error.localizedDescription; phase = "无法确认恢复结果，请使用“恢复未结束会话”复核。" }
        }
    }
    func stop() {
        guard let lease else { return }
        do { try lease.requestStop(); phase = "已请求停止，等待管理员组件核对并恢复原值…" }
        catch { self.error = error.localizedDescription }
    }
    func recover() {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let response = try await AdminClient().execute(AdminRequest(operation: .recoverHardware))
                phase = response.hardware?.detail ?? response.detail
                if !response.succeeded { error = response.detail }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct HardwareControlView: View {
    @StateObject private var model = HardwareControlModel.shared
    @State private var confirm = false
    @State private var confirmRecovery = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("风扇与充电").font(.title2.bold()); Spacer(); Button("读取本机能力") { model.probe() }.disabled(model.busy); Button("授权复核能力") { model.probeAdministrator() }.disabled(model.busy) }
                Text("控制仅在有时限的会话中生效。到时、停止或退出应用后，管理员组件会核对并恢复会话前状态。请先退出其他风扇或充电控制工具。").foregroundStyle(.secondary)
                if let capability = model.capability {
                    GroupBox("风扇") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(capability.reportedFanCount == 0 ? "本机未配置风扇，风扇控制不可用。" : "检测到 \(capability.reportedFanCount.map(String.init) ?? "未知") 个风扇，\(capability.fans.count) 个具备可识别控制接口。")
                            Toggle("手动目标转速", isOn: $model.fan).disabled(capability.fans.isEmpty || model.busy)
                            if model.fan { HStack { Slider(value: $model.fanPercent, in: 30...100, step: 5); Text("\(Int(model.fanPercent))%").monospacedDigit().frame(width: 50) }.disabled(model.busy) }
                            ForEach(capability.fans) { fan in Text("风扇 \(fan.index)：\(Int(fan.minimumRPM))–\(Int(fan.maximumRPM)) RPM").font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox("充电养护") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("限制充电上限", isOn: $model.charging).disabled(capability.chargingKeys.isEmpty || model.busy)
                            if capability.chargingKeys.isEmpty { Text("没有识别到支持的充电控制协议。需要权限才能读取的设备也可能在这里显示不可用。").font(.caption).foregroundStyle(.secondary) }
                            if model.charging { Stepper("上限 \(model.chargeLimit)%（低于 \(model.chargeLimit - 5)% 后重新允许充电）", value: $model.chargeLimit, in: 50...95).disabled(model.busy) }
                            Text("仅暂停或允许充电，不主动放电；macOS 的优化充电仍可能影响最终电量。").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    if !capability.issues.isEmpty { Text(capability.issues.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    Picker("会话时长", selection: $model.minutes) { ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) 分钟").tag($0) } }.frame(width: 220).disabled(model.busy)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small); Button("停止并恢复") { model.stop() } }
                    else { Button("复核并开始…") { confirm = true }.buttonStyle(.borderedProminent).disabled(!model.fan && !model.charging) }
                }
                Divider()
                HStack { Text("若组件被强制终止、断电或上次恢复失败，请核对未结束会话。恢复会请求管理员授权；已被其他控制器改变的值不会直接覆盖。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("恢复未结束会话…") { confirmRecovery = true }.disabled(model.busy) }
                if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                Text(model.phase).font(.callout).textSelection(.enabled)
            }.padding(8)
        }
        .confirmationDialog("开启 \(model.minutes) 分钟的硬件控制会话？", isPresented: $confirm, titleVisibility: .visible) {
            Button("授权并开始") { model.start() }; Button("取消", role: .cancel) { }
        } message: { Text("\(model.fan ? "风扇目标：\(Int(model.fanPercent))%。" : "")\(model.charging ? "充电上限：\(model.chargeLimit)%。" : "") 执行前保存原值，结束时核对恢复。系统将请求管理员授权。") }
        .confirmationDialog("复核并恢复上次硬件会话？", isPresented: $confirmRecovery, titleVisibility: .visible) { Button("授权并恢复") { model.recover() }; Button("取消", role: .cancel) { } }
    }
}
