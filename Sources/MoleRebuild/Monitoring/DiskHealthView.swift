import SwiftUI
import AppKit
import MoleCore

@MainActor private final class DiskHealthModel: ObservableObject {
    @Published var disks: [PhysicalDiskHealth] = []
    @Published var busy = false
    @Published var stopping = false
    @Published var phase = "按需读取内置及外接物理磁盘，不运行写入或自检命令。"
    @Published var report: DiskHealthReport?
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var generation = 0
    func read() {
        guard !busy else { return }
        generation += 1; let current = generation
        busy = true; stopping = false; disks = []; report = nil; error = nil; phase = "正在读取物理磁盘与 SMART…"
        task = Task {
            defer { generation += 1; busy = false; stopping = false; task = nil }
            do {
                let value = try await DiskHealthService().inspect { [weak self] disk in Task { @MainActor in
                    guard let self, self.generation == current, !self.stopping else { return }
                    if !self.disks.contains(where: { $0.id == disk.id }) { self.disks.append(disk) }
                } }
                try Task.checkCancellation()
                disks = value.disks; report = value; phase = "读取完成 · \(value.disks.count) 块物理磁盘。" + value.issues.joined(separator: " ")
            } catch is CancellationError { phase = "读取已停止，保留已显示的 \(disks.count) 项；这些不是完整报告。" }
            catch { self.error = error.localizedDescription; phase = "未完成读取；没有更改磁盘。" }
        }
    }
    func cancel() { guard busy else { return }; stopping = true; generation += 1; task?.cancel(); phase = "正在停止磁盘信息读取…" }
    func copyReport() {
        guard let report else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
            phase = "已复制报告 JSON。"
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor struct DiskHealthView: View {
    @StateObject private var model = DiskHealthModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("物理磁盘健康", systemImage: "internaldrive").font(.headline)
                Spacer()
                if model.busy { ProgressView().controlSize(.small); Button(model.stopping ? "正在停止…" : "停止") { model.cancel() }.disabled(model.stopping) }
                else { Button(model.disks.isEmpty ? "读取 SMART" : "刷新 SMART") { model.read() }; Button("复制报告 JSON") { model.copyReport() }.disabled(model.report == nil) }
            }
            ForEach(model.disks) { disk in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(disk.model ?? disk.device).fontWeight(.medium)
                        Text(disk.device).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(disk.health.label).foregroundStyle(disk.health == .failing ? Color.red : disk.health == .verified ? Color.green : Color.secondary)
                    }
                    HStack {
                        Text(disk.connection ?? "连接方式不可用")
                        Text(disk.isInternal.map { $0 ? "内置" : "外接" } ?? "位置未知")
                        Text(disk.isSolidState.map { $0 ? "固态" : "非固态" } ?? "介质类型未知")
                        Text(disk.capacityBytes.map { MonitorDisplay.bytes($0) } ?? "容量不可用")
                        Spacer(); Text(disk.sampledAt, style: .time)
                    }.font(.caption).foregroundStyle(.secondary)
                    if let raw = disk.reportedStatus { Text("系统原始状态：\(raw)").font(.caption).foregroundStyle(.secondary) }
                    if !disk.rawSMART.isEmpty {
                        DisclosureGroup("\(disk.rawSMART.count) 项驱动原始字段") {
                            Text("字段由驱动提供，单位与含义未作推断；不换算为寿命、温度或写入量。").font(.caption).foregroundStyle(.secondary)
                            ForEach(disk.rawSMART.keys.sorted(), id: \.self) { key in
                                HStack { Text(key); Spacer(); Text(disk.rawSMART[key] ?? "") }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                    ForEach(disk.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text(model.phase).font(.caption).foregroundStyle(.secondary)
            Text("SMART 为设备自检汇总状态，不代表寿命预测；USB 桥接器可能不提供该信息。").font(.caption2).foregroundStyle(.secondary)
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .onDisappear { model.cancel() }
    }
}
