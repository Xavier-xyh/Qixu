import SwiftUI
import AppKit

@MainActor
struct MonitorMenuLabel: View {
    @StateObject private var model = MonitorModel.shared
    @State private var consumerID = "label-" + UUID().uuidString
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            if let cpu = model.snapshot?.cpu, cpu.hasBaseline { Text(String(format: "%.0f%%", cpu.usage)).monospacedDigit() }
        }.task { model.acquire(consumerID) }.onDisappear { model.release(consumerID) }
    }
}

@MainActor
struct MonitorMenuContent: View {
    @StateObject private var model = MonitorModel.shared
    @State private var consumerID = "menu-" + UUID().uuidString
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Qixu · 系统状态", systemImage: "waveform.path.ecg").font(.headline)
                Spacer()
                Circle().fill(model.isPaused ? .orange : .green).frame(width: 7, height: 7)
            }
            if let sample = model.snapshot {
                menuRow("CPU", MonitorDisplay.percent(sample.cpu?.hasBaseline == true ? sample.cpu?.usage : nil), color: .cyan)
                menuRow("内存", MonitorDisplay.percent(sample.memory?.usedPercent), color: .purple)
                menuRow("下载", MonitorDisplay.rate(sample.network.reduce(0) { $0 + $1.receivedPerSecond }), color: .teal)
                menuRow("上传", MonitorDisplay.rate(sample.network.reduce(0) { $0 + $1.sentPerSecond }), color: .orange)
                if let battery = sample.battery { menuRow("电池", MonitorDisplay.percent(battery.chargePercent), color: .green) }
                Divider()
                Text("热状态 \(MonitorDisplay.thermal(sample.thermalState))  ·  已运行 \(MonitorDisplay.uptime(sample.uptime))").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(sample.processes.prefix(3))) { process in
                    HStack { Text(process.name).lineLimit(1); Spacer(); Text(String(format: "%.1f%%", process.cpuPercent)).monospacedDigit() }.font(.caption)
                }
            } else { ProgressView("读取指标…").padding(.vertical, 12) }
            Divider()
            HStack {
                Button(model.isPaused ? "继续采样" : "暂停采样") { model.togglePause() }
                Spacer()
                Button("显示主窗口") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                }
            }.font(.caption)
        }.padding(18).frame(width: 310)
            .task { model.acquire(consumerID) }.onDisappear { model.release(consumerID) }
    }
    private func menuRow(_ name: String, _ value: String, color: Color) -> some View {
        HStack { Text(name).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(color) }.font(.callout)
    }
}
