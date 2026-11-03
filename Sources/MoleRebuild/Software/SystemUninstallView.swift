import SwiftUI
import AppKit
import MoleCore

@MainActor private final class SystemUninstallModel: ObservableObject {
    @Published var plan: SystemUninstallPlan?
    @Published var selected: Set<String> = []
    @Published var records: [SystemUninstallRecord] = []
    @Published var busy = false
    @Published var phase = "先扫描并复核；扫描不会修改系统。"
    @Published var error: String?
    @Published var vendorCandidates: [URL]?
    func inspectVendor(_ app: InstalledApplication, reveal: URL? = nil) {
        guard !busy else { return }
        busy = true
        error = nil
        phase = "正在核对应用包内的厂商卸载器…"
        Task {
            defer { busy = false }
            let candidates = await Task.detached(priority: .userInitiated) {
                VendorUninstaller.candidates(for: app)
            }.value
            vendorCandidates = candidates
            phase = candidates.isEmpty ? "未找到可验证的内置卸载器。" : "已核对内置卸载器的开发者签名。"
            if let reveal {
                guard candidates.contains(reveal) else {
                    error = "此卸载器已不可用或签名已变化。"
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([reveal])
            }
        }
    }
    func inspectAdministrator(_ app: InstalledApplication) {
        guard !busy else { return }
        plan = SystemUninstallPlan(application: SystemApplicationIdentity(app), items: [])
        run(.inspectSystem)
    }
    func scan(_ app: InstalledApplication) {
        guard !busy else { return }; busy = true; error = nil
        Task {
            defer { busy = false }
            do { let plan = try await SystemUninstallPlanner().plan(app); self.plan = plan; selected = [app.id]; phase = "仅默认选择应用本体。系统数据需逐项手动复核。" }
            catch { self.error = error.localizedDescription }
        }
    }
    func run(_ operation: AdminOperation, id: UUID? = nil, reload: Bool = false) {
        guard !busy else { return }
        var selection = plan
        if operation == .quarantine {
            guard selection != nil else { return }; selection!.items.removeAll { !selected.contains($0.id) }
            let labels = Set(selection!.items.compactMap(\.serviceLabel))
            guard selection!.items.compactMap(\.requiredServiceLabel).allSatisfy(labels.contains) else { error = "选择系统组件时，必须同时选择其对应的系统服务。"; return }
        }
        busy = true; error = nil; phase = "等待管理员授权并核对执行条件…"
        Task {
            defer { busy = false }
            do {
                let response = try await AdminClient().execute(AdminRequest(operation: operation, uninstall: [.quarantine, .inspectSystem].contains(operation) ? selection : nil, recordID: id, reloadServices: reload))
                if let plan = response.plan { self.plan = plan; selected = [plan.application.url.path] }
                if operation == .history {
                    if response.succeeded { records = response.records }
                } else if !response.records.isEmpty {
                    let updatedIDs = Set(response.records.map(\.id))
                    records = (records.filter { !updatedIDs.contains($0.id) } + response.records)
                        .sorted { $0.date > $1.date }
                }
                phase = response.detail
                if !response.succeeded { error = response.detail }
                if operation == .quarantine, response.succeeded { plan = nil; selected = []; vendorCandidates = nil }
                await ActivityStore.shared.append(ActivityRecord(category: "系统级卸载", title: operation == .history ? "读取管理员隔离记录" : operation == .inspectSystem ? "管理员只读补充扫描" : operation == .quarantine ? "系统隔离操作" : "恢复系统隔离项目", detail: response.detail, succeeded: response.succeeded))
            } catch { self.error = error.localizedDescription; phase = "操作结果需核对。请读取管理员记录；已完成的移动不会被取消或隐藏。" }
        }
    }
}
struct SystemUninstallView: View {
    let application: InstalledApplication?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SystemUninstallModel()
    @State private var confirmation = false
    @State private var restoreID: UUID?
    private func recordSummary(_ record: SystemUninstallRecord) -> String {
        let restored = record.items.filter(\.restored).count
        let isolated = record.items.filter { $0.moved && !$0.restored }.count
        let stopped = record.items.filter(\.serviceStopped).count
        let conflicts = record.items.filter(\.hasDestinationConflict).count
        return "已恢复 \(restored) / \(record.items.count) · 仍隔离 \(isolated) · 服务已停止 \(stopped) · 路径冲突 \(conflicts)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("系统级卸载与恢复").font(.title.bold()); Spacer(); if model.busy { ProgressView().controlSize(.small) }; Button("关闭") { dismiss() }.disabled(model.busy) }
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
            Text("将明确选中的应用和系统关联项移到受保护的管理员隔离目录，可从本页恢复。系统服务会先停止；恢复文件不会自动启动服务。").foregroundStyle(.secondary)
            HStack {
                if let app = application {
                    Button("扫描 \(app.name)") { model.scan(app) }.disabled(model.busy || app.isProtected)
                    Button("授权补充扫描") { model.inspectAdministrator(app) }.disabled(model.busy || app.isProtected)
                }
                Spacer(); Button("授权读取隔离记录") { model.run(.history) }.disabled(model.busy)
            }
            if let app = application, !app.isProtected {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("厂商卸载器", systemImage: "shippingbox").font(.headline)
                        Spacer()
                        Button("查找内置卸载器") { model.inspectVendor(app) }.disabled(model.busy)
                    }
                    Text("驱动和系统扩展优先使用厂商卸载流程。厂商卸载器移除的内容不在 Qixu 的隔离记录中。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let candidates = model.vendorCandidates {
                        if candidates.isEmpty {
                            Text("应用包内未找到可验证的卸载器。请查看厂商支持文档或原始安装镜像。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(candidates, id: \.self) { url in
                            HStack {
                                Text(url.lastPathComponent).help(url.path)
                                Spacer()
                                Button("在 Finder 中显示") { model.inspectVendor(app, reveal: url) }.disabled(model.busy)
                            }
                        }
                    }
                }
            }
            if let plan = model.plan {
                List {
                    ForEach(plan.items) { item in
                        HStack(alignment: .top) {
                            Toggle("选择", isOn: Binding(get: { model.selected.contains(item.id) }, set: { if $0 { model.selected.insert(item.id) } else { model.selected.remove(item.id) } })).labelsHidden().disabled(model.busy || item.url == plan.application.url)
                            VStack(alignment: .leading, spacing: 4) { Text(item.url.lastPathComponent).fontWeight(.medium); Text(item.url.path).font(.caption).textSelection(.enabled); Text(item.evidence).font(.caption).foregroundStyle(.secondary); if let label = item.serviceLabel { Text("将停止\(item.url.deletingLastPathComponent().path == "/Library/LaunchAgents" ? "当前用户登录服务" : "系统服务")：\(label)").font(.caption).foregroundStyle(.orange) } }
                        }
                    }
                }.frame(height: 220)
                if !plan.receipts.isEmpty { DisclosureGroup("安装收据（只读，不删除）") { Text(plan.receipts.joined(separator: "\n")).font(.caption).textSelection(.enabled) } }
                Text(plan.issues.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("复核隔离 \(model.selected.count) 项…") { confirmation = true }.buttonStyle(.borderedProminent).disabled(model.busy || model.selected.isEmpty) }
            }
            if !model.records.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.records) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(record.application.url.lastPathComponent).font(.headline); Spacer(); Button("复核恢复…") { restoreID = record.id }.disabled(model.busy || (record.phase == "restored" && !record.items.contains(where: { $0.serviceWasLoaded && $0.serviceStopped }))) }
                            Text(recordSummary(record))
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(record.items.enumerated()), id: \.offset) { _, entry in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.restored ? "文件已恢复" : entry.moved ? "文件已隔离" : "待处理").font(.caption.bold())
                                        if entry.hasDestinationConflict {
                                            Label("原位置有冲突", systemImage: "exclamationmark.triangle")
                                                .font(.caption).foregroundStyle(.orange)
                                        }
                                        if entry.serviceStopped { Text("服务已停止").font(.caption).foregroundStyle(.orange) }
                                        Text("\(entry.item.url.path)\n\(entry.detail)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                    Spacer()
                                    if !entry.restored {
                                        Button(entry.hasDestinationConflict ? "在 Finder 中定位冲突" : "查看原位置") {
                                            let url = entry.item.url
                                            if entry.hasDestinationConflict, (try? FileIdentity.capture(url)) != nil {
                                                NSWorkspace.shared.activateFileViewerSelecting([url])
                                            } else {
                                                NSWorkspace.shared.open(url.deletingLastPathComponent())
                                            }
                                        }.disabled(model.busy)
                                    }
                                }
                            }
                            Text("阶段记录不代替现场身份检查；恢复不会覆盖原位置内容。").font(.caption2).foregroundStyle(.secondary)
                            Divider()
                        }.padding(.vertical, 8)
                    }
                }
            }
            if model.plan == nil && model.records.isEmpty { ContentUnavailableView("先选择应用扫描，或读取隔离记录", systemImage: "lock.shield").frame(maxWidth: .infinity, minHeight: 180) }
              }.frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.error { ScrollView { Text(error).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 70) }
            Text(model.phase).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(model.phase)
        }.padding(24).frame(minWidth: 800, idealWidth: 900, minHeight: 560, idealHeight: 660).interactiveDismissDisabled(model.busy)
            .confirmationDialog("将所选项目移到管理员隔离目录？", isPresented: $confirmation, titleVisibility: .visible) { Button("授权并隔离") { model.run(.quarantine) }; Button("取消", role: .cancel) { } } message: { Text("请先退出应用。系统将请求管理员授权；未知归属、身份变化或停止服务失败会阻止后续步骤。") }
            .confirmationDialog("恢复此记录中的文件？", isPresented: Binding(get: { restoreID != nil }, set: { if !$0 { restoreID = nil } }), titleVisibility: .visible) {
                Button("仅授权恢复文件") { let id = restoreID; restoreID = nil; model.run(.restoreQuarantine, id: id) }
                Button("恢复文件并重新加载此前停止的服务") { let id = restoreID; restoreID = nil; model.run(.restoreQuarantine, id: id, reload: true) }
                Button("取消", role: .cancel) { restoreID = nil }
            } message: { Text("逐项重新核对身份和目的地，不覆盖现有内容。重新加载服务会启动原后台程序，仅在明确选择该项时执行。") }
    }
}
