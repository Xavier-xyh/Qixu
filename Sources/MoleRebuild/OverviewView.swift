import SwiftUI
import MoleCore

struct RebuildOverviewView: View {
    @ObservedObject var router: RebuildRouter
    @ObservedObject private var monitor = MonitorModel.shared
    @State private var records: [ActivityRecord] = []
    @State private var consumer = "overview-" + UUID().uuidString

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MAC WORKSPACE").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(Color.teal)
                    Text("系统总览").font(.largeTitle.bold())
                    Text(Host.current().localizedName ?? "Mac").foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    metric("CPU 使用率", monitor.snapshot?.cpu?.hasBaseline == true ? MonitorDisplay.percent(monitor.snapshot?.cpu?.usage) : "采样中", icon: "cpu")
                    Divider()
                    metric("内存使用", MonitorDisplay.percent(monitor.snapshot?.memory?.usedPercent), icon: "memorychip")
                    Divider()
                    metric("磁盘可用", monitor.snapshot?.volumes.first(where: { $0.path == "/" }).map { MonitorDisplay.bytes($0.available) } ?? "—", icon: "internaldrive")
                    Divider()
                    metric("运行时长", monitor.snapshot.map { MonitorDisplay.uptime($0.uptime) } ?? "—", icon: "clock")
                }
                .frame(height: 96)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))

                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("快捷入口").font(.title2.bold())
                        destination(.cleaning, detail: "扫描缓存与日志")
                        destination(.software, detail: "管理已安装应用及更新")
                        destination(.disk, detail: "查看目录大小与空间图")
                        destination(.monitor, detail: "查看实时性能和进程")
                        destination(.tools, detail: "检查网络、启动项和系统维护")
                    }.frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("最近操作").font(.title2.bold())
                            Spacer()
                            Button("查看全部") { router.selection = .activity }.buttonStyle(.link)
                        }
                        if records.isEmpty {
                            Text("扫描和维护记录会显示在这里。").foregroundStyle(.secondary)
                        }
                        ForEach(records.prefix(5)) { record in
                            HStack(spacing: 10) {
                                Image(systemName: record.succeeded ? "checkmark.circle" : "exclamationmark.circle")
                                    .foregroundStyle(record.succeeded ? Color.teal : Color.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.title).font(.callout.weight(.medium)).lineLimit(1).help(record.title)
                                    Text(record.category).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(record.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }.padding(12)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }.frame(minWidth: 300, idealWidth: 360, maxWidth: 420, alignment: .leading)
                }
            }.frame(maxWidth: 1240).padding(30).frame(maxWidth: .infinity)
        }
        .task { monitor.acquire(consumer); records = await ActivityStore.shared.records() }
        .onDisappear { monitor.release(consumer) }
    }

    private func metric(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
        }.padding(.horizontal, 18).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func destination(_ section: RebuildSection, detail: String) -> some View {
        Button { router.selection = section } label: {
            HStack(spacing: 12) {
                Image(systemName: section.icon).foregroundStyle(Color.teal).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.rawValue).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
