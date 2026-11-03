import SwiftUI
import Charts
import AppKit
import MoleCore

@MainActor
struct MonitorView: View {
    @StateObject private var model = MonitorModel.shared
    @State private var consumerID = "window-" + UUID().uuidString
    @State private var processSearch = ""
    @State private var processSort = ProcessSort.cpu
    @State private var selectedPID: Int32?
    @State private var showDiagnostics = false

    enum ProcessSort: String, CaseIterable { case cpu = "CPU", memory = "内存", name = "名称" }
    private var sample: MonitorSnapshot? { model.snapshot }
    private var processes: [MonitorProcess] {
        let list = (sample?.processes ?? []).filter {
            processSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(processSearch) || String($0.pid).contains(processSearch)
        }
        switch processSort {
        case .cpu: return list.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: return list.sorted { $0.residentBytes > $1.residentBytes }
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let sample {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 14)], spacing: 14) {
                        valueCard("CPU", symbol: "cpu", value: sample.cpu?.hasBaseline == true ? MonitorDisplay.percent(sample.cpu?.usage) : "建立基线", detail: "\(sample.cpu?.perCore.count ?? ProcessInfo.processInfo.processorCount) 个核心 · 全机平均", color: .cyan)
                        valueCard("内存", symbol: "memorychip", value: MonitorDisplay.percent(sample.memory?.usedPercent), detail: sample.memory.map { "\(MonitorDisplay.bytes($0.used)) / \(MonitorDisplay.bytes($0.total))" } ?? "暂不可用", color: .purple)
                        valueCard("下载", symbol: "arrow.down", value: MonitorDisplay.rate(sample.network.reduce(0) { $0 + $1.receivedPerSecond }), detail: "\(sample.network.count) 个活动接口合计", color: .teal)
                        valueCard("上传", symbol: "arrow.up", value: MonitorDisplay.rate(sample.network.reduce(0) { $0 + $1.sentPerSecond }), detail: "接口统计，可能包含虚拟网卡", color: .orange)
                    }
                    historySection
                    networkHistorySection
                    coreSection(sample)
                    HStack(alignment: .top, spacing: 16) {
                        systemSection(sample).frame(maxWidth: .infinity, alignment: .topLeading)
                        diskSection(sample).frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    DiskHealthView()
                    sensorSection(sample)
                    networkSection(sample)
                    processSection
                    if !sample.diagnostics.isEmpty {
                        DisclosureGroup(isExpanded: $showDiagnostics) {
                            ForEach(sample.diagnostics, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                        } label: { Label("\(sample.diagnostics.count) 项读取提示", systemImage: "info.circle").font(.callout) }
                        .padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                    }
                    Text("CPU 为各核心平均；进程 CPU 可超过 100%。网络统计包含虚拟接口，合计可能重复计算 VPN 流量。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("正在读取系统指标…").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 360)
                }
            }.padding(26)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { model.acquire(consumerID) }
        .onDisappear { model.release(consumerID) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("系统状态").font(.system(size: 30, weight: .bold, design: .rounded))
                HStack(spacing: 7) {
                    Circle().fill(model.isPaused ? .orange : .green).frame(width: 7, height: 7)
                    Text(model.isPaused ? "已暂停" : "实时采集")
                    if let date = sample?.date { Text("·"); Text(date, style: .time) }
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("采样间隔", selection: $model.interval) {
                Text("0.5 秒").tag(0.5); Text("1 秒").tag(1.0); Text("2 秒").tag(2.0); Text("5 秒").tag(5.0)
            }.frame(width: 120)
            Button { model.togglePause() } label: { Label(model.isPaused ? "继续" : "暂停", systemImage: model.isPaused ? "play.fill" : "pause.fill") }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.disabled(model.isPaused).help("立即采样")
        }
    }

    private func valueCard(_ title: String, symbol: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.callout.weight(.medium)).foregroundStyle(color)
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(color.opacity(0.12)))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("最近两分钟").font(.headline); Spacer()
                Label("CPU", systemImage: "circle.fill").foregroundStyle(.cyan)
                Label("内存", systemImage: "circle.fill").foregroundStyle(.purple)
                if sample?.gpuPercent != nil { Label("GPU", systemImage: "circle.fill").foregroundStyle(.green) }
            }.font(.caption)
            Chart {
                ForEach(model.history) { point in
                    if let value = point.cpu {
                        LineMark(x: .value("时间", point.date), y: .value("百分比", value), series: .value("指标", "CPU"))
                            .foregroundStyle(.cyan).interpolationMethod(.monotone)
                    }
                    if let value = point.memory {
                        LineMark(x: .value("时间", point.date), y: .value("百分比", value), series: .value("指标", "内存"))
                            .foregroundStyle(.purple).interpolationMethod(.monotone)
                    }
                    if let value = point.gpu {
                        LineMark(x: .value("时间", point.date), y: .value("百分比", value), series: .value("指标", "GPU"))
                            .foregroundStyle(.green).interpolationMethod(.monotone)
                    }
                }
            }.chartYScale(domain: 0...100).chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }.frame(height: 165)
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private var networkHistorySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("网络速率变化").font(.headline); Spacer()
                Label("下载", systemImage: "circle.fill").foregroundStyle(.teal)
                Label("上传", systemImage: "circle.fill").foregroundStyle(.orange)
            }.font(.caption)
            Chart {
                ForEach(model.history) { point in
                    LineMark(x: .value("时间", point.date), y: .value("字节每秒", point.received), series: .value("方向", "下载"))
                        .foregroundStyle(.teal).interpolationMethod(.monotone)
                    LineMark(x: .value("时间", point.date), y: .value("字节每秒", point.sent), series: .value("方向", "上传"))
                        .foregroundStyle(.orange).interpolationMethod(.monotone)
                }
            }.chartYScale(domain: 0...max(1, (model.history.map { max($0.received, $0.sent) }.max() ?? 1) * 1.1))
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel { if let rate = value.as(Double.self) { Text(MonitorDisplay.rate(rate)) } }
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }.frame(height: 120)
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private func coreSection(_ sample: MonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("核心负载").font(.headline); Spacer()
                if let loads = sample.cpu?.loads, loads.count == 3 {
                    Text(String(format: "平均负载  %.2f / %.2f / %.2f", loads[0], loads[1], loads[2])).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let groups = sample.cpu?.coreGroups, !groups.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        Text("\(group.displayName) · \(group.logicalCount) 个逻辑核心").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("分组由系统提供；逐核编号暂未映射到分组。").font(.caption2).foregroundStyle(.secondary)
            } else { Text("系统未提供核心类型分组。").font(.caption).foregroundStyle(.secondary) }
            if let cpu = sample.cpu, cpu.hasBaseline {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 95), spacing: 12)], spacing: 12) {
                    ForEach(Array(cpu.perCore.enumerated()), id: \.offset) { index, value in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text("核心 \(index + 1)"); Spacer(); Text(String(format: "%.0f%%", value)).monospacedDigit() }.font(.caption2).foregroundStyle(.secondary)
                            ProgressView(value: value, total: 100).tint(value > 80 ? .orange : .cyan)
                        }
                    }
                }
            } else { Text("第二次采样后显示各核心差分负载。").font(.callout).foregroundStyle(.secondary) }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private func systemSection(_ sample: MonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("硬件与内存").font(.headline)
            infoRow("机型", sample.hardwareModel)
            infoRow("开机时长", MonitorDisplay.uptime(sample.uptime))
            infoRow("系统热状态", MonitorDisplay.thermal(sample.thermalState))
            infoRow("GPU 使用率", sample.gpuPercent.map { MonitorDisplay.percent($0) } ?? "此设备未提供")
            if let memory = sample.memory {
                Divider()
                infoRow("系统内存压力", MonitorDisplay.pressure(memory.pressureLevel))
                infoRow("Wired + 压缩占比", MonitorDisplay.percent(memory.pressurePercent))
                infoRow("交换空间", memory.swapUsed.flatMap { used in memory.swapTotal.map { "\(MonitorDisplay.bytes(used)) / \(MonitorDisplay.bytes($0))" } } ?? "不可用")
            }
            if let battery = sample.battery {
                Divider()
                infoRow("电池电量", MonitorDisplay.percent(battery.chargePercent))
                infoRow("电池健康", MonitorDisplay.percent(battery.healthPercent))
                infoRow("电池温度", battery.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "电源接口未提供")
                infoRow("循环次数", battery.cycles.map(String.init) ?? "不可用")
                infoRow("电源", battery.isCharging ? "正在充电" : (battery.isExternalConnected ? "外接电源" : "电池供电"))
            }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private func sensorSection(_ sample: MonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("温度与风扇", systemImage: "thermometer.medium").font(.headline)
            if let sensors = sample.sensors {
                if let lowest = sensors.temperatures.map(\.celsius).min(), let highest = sensors.temperatures.map(\.celsius).max() {
                    infoRow("已读温度范围", String(format: "%.1f – %.1f °C", lowest, highest))
                    DisclosureGroup("\(sensors.temperatures.count) 个温度传感器") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155))], spacing: 10) {
                            ForEach(sensors.temperatures) { temperature in
                                HStack {
                                    Text(temperature.key).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(String(format: "%.1f °C", temperature.celsius)).monospacedDigit()
                                }.font(.caption).padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                            }
                        }.padding(.top, 10)
                        Text("传感器标识来自硬件；位置会随芯片变化，不等同于上方逐核编号。").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.callout)
                } else { infoRow("温度", "此设备未返回受支持的读数") }
                ForEach(sensors.fans) { fan in
                    infoRow("风扇 \(fan.index + 1)", String(format: "%.0f RPM", fan.revolutionsPerMinute))
                }
                if sensors.reportedFanCount == 0 { infoRow("风扇", "设备报告无风扇") }
                else if sensors.fans.isEmpty { infoRow("风扇", "转速不可用") }
                if let diagnostic = sensors.diagnostic { Text(diagnostic).font(.caption).foregroundStyle(.secondary) }
            } else { Text("正在读取传感器…").font(.callout).foregroundStyle(.secondary) }
            Text("传感器每 5 秒更新；此处只读取当前状态。").font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private func diskSection(_ sample: MonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("磁盘与读写").font(.headline)
            infoRow("总读取速率", sample.diskIO.map { $0.hasBaseline ? MonitorDisplay.rate($0.readPerSecond) : "建立基线" } ?? "驱动未提供")
            infoRow("总写入速率", sample.diskIO.map { $0.hasBaseline ? MonitorDisplay.rate($0.writePerSecond) : "建立基线" } ?? "驱动未提供")
            Divider()
            if sample.volumes.isEmpty { Text("没有可读取的挂载卷").foregroundStyle(.secondary) }
            ForEach(sample.volumes) { volume in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive"); Text(volume.name).lineLimit(1); Spacer(); Text(String(format: "%.0f%%", volume.usedPercent)).font(.caption).foregroundStyle(.secondary) }
                    ProgressView(value: min(100, max(0, volume.usedPercent)), total: 100).tint(volume.usedPercent > 90 ? .orange : .blue)
                    Text("可用 \(MonitorDisplay.bytes(volume.available)) / \(MonitorDisplay.bytes(volume.total))").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private func networkSection(_ sample: MonitorSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("网络接口").font(.headline)
            if sample.network.isEmpty { Text("当前没有活动接口，或接口统计不可读取。").foregroundStyle(.secondary).font(.callout) }
            ForEach(sample.network) { network in
                HStack(spacing: 18) {
                    Image(systemName: network.name.hasPrefix("utun") ? "network.badge.shield.half.filled" : "network").foregroundStyle(.teal).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) { Text(network.name).font(.callout.weight(.medium)); Text(network.ipv4 ?? "无 IPv4 地址").font(.caption).foregroundStyle(.secondary) }.frame(width: 160, alignment: .leading)
                    Spacer()
                    Label(MonitorDisplay.rate(network.receivedPerSecond), systemImage: "arrow.down").foregroundStyle(.teal).frame(width: 150, alignment: .trailing)
                    Label(MonitorDisplay.rate(network.sentPerSecond), systemImage: "arrow.up").foregroundStyle(.orange).frame(width: 150, alignment: .trailing)
                }.font(.callout.monospacedDigit())
            }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("进程").font(.headline)
                Text("\(sample?.processes.count ?? 0)").foregroundStyle(.secondary).font(.caption)
                Spacer()
                TextField("名称或 PID", text: $processSearch).textFieldStyle(.roundedBorder).frame(width: 180)
                Picker("排序", selection: $processSort) { ForEach(ProcessSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 115)
            }
            Table(processes, selection: $selectedPID) {
                TableColumn("进程") { process in
                    HStack(spacing: 8) {
                        Image(systemName: "app.dashed").foregroundStyle(.secondary)
                        Text(process.name).lineLimit(1).help(process.path ?? process.name)
                    }.contextMenu {
                        if let path = process.path {
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            Button("复制可执行路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
                        }
                        Button("复制 PID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(String(process.pid), forType: .string) }
                    }
                }.width(min: 150, ideal: 300)
                TableColumn("PID") { Text(String($0.pid)).foregroundStyle(.secondary).monospacedDigit() }.width(65)
                TableColumn("CPU") { Text(String(format: "%.1f%%", $0.cpuPercent)).monospacedDigit() }.width(80)
                TableColumn("内存") { Text(MonitorDisplay.bytes($0.residentBytes)).monospacedDigit() }.width(100)
                TableColumn("线程") { Text(String($0.threadCount)).monospacedDigit().foregroundStyle(.secondary) }.width(55)
            }.frame(height: 300)
            Text("只显示系统允许读取的进程；CPU 在两次进程采样之间计算，约每两秒更新。右键可定位程序。").font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label).foregroundStyle(.secondary); Spacer(minLength: 16); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.caption)
    }
}
