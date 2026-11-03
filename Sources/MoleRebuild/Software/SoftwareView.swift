import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MoleCore

@MainActor
private final class SoftwareViewModel: ObservableObject {
    @Published var applications = [InstalledApplication]()
    @Published var search = ""
    @Published var order = "名称"
    @Published var selection: String?
    @Published var remnants = [SoftwareRemnant]()
    @Published var selectedRemnants = Set<String>()
    @Published var issues = [String]()
    @Published var didScanRemnants = false
    @Published var remnantIssues = [String]()
    @Published var isLoading = false
    @Published var isScanning = false
    @Published var isExecuting = false
    @Published var status = "读取应用列表后选择一项查看详情。"
    @Published var error: String?
    @Published var showReview = false
    @Published var showResults = false
    @Published var showHistory = false
    @Published var outcomes = [TrashOperationResult]()
    private var inventoryTask: Task<Void, Never>?
    private var remnantTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var inventoryGeneration = 0, remnantGeneration = 0
    private var icons = [String: NSImage]()
    var chosenApp: InstalledApplication? { applications.first { $0.id == selection } }
    var chosenRemnants: [SoftwareRemnant] { remnants.filter { selectedRemnants.contains($0.id) } }
    var filtered: [InstalledApplication] {
        let values = applications.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.bundleID.localizedCaseInsensitiveContains(search) || $0.url.path.localizedCaseInsensitiveContains(search) }
        if order == "占用空间" { return values.sorted { $0.size > $1.size } }
        if order == "最近修改" { return values.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) } }
        return values
    }
    func icon(_ app: InstalledApplication) -> NSImage { if let value = icons[app.id] { return value }; let value = NSWorkspace.shared.icon(forFile: app.url.path); icons[app.id] = value; return value }
    func reload() {
        guard !isExecuting else { return }
        inventoryTask?.cancel(); inventoryGeneration += 1; let current = inventoryGeneration
        isLoading = true; issues = []; status = "正在读取应用身份与大小…"
        inventoryTask = Task {
            do {
                let inventory = try await SoftwareService().inventory { [weak self] name in Task { @MainActor in guard let self, self.inventoryGeneration == current else { return }; self.status = "读取应用 · " + name } }
                guard !Task.isCancelled, inventoryGeneration == current else { return }
                applications = inventory.applications; issues = inventory.issues
                if !applications.contains(where: { $0.id == selection }) { selection = nil }
                status = "已读取 \(applications.count) 个应用；大小带 ≥ 表示尚未完成全部统计。"
            } catch is CancellationError { if inventoryGeneration == current { status = "读取已取消，保留此前列表。" } }
            catch { if inventoryGeneration == current { self.error = error.localizedDescription } }
            if inventoryGeneration == current { isLoading = false; inventoryTask = nil }
        }
    }
    func cancel() {
        if let operationTask { operationTask.cancel(); status = "正在停止后续操作，等待已完成项目返回结果…"; return }
        inventoryGeneration += 1; remnantGeneration += 1
        inventoryTask?.cancel(); remnantTask?.cancel(); inventoryTask = nil; remnantTask = nil
        isLoading = false; isScanning = false; status = "已取消，保留此前结果。"
    }
    func selectionChanged() { remnantGeneration += 1; remnantTask?.cancel(); remnantTask = nil; isScanning = false; remnants = []; selectedRemnants = []; remnantIssues = []; didScanRemnants = false }
    func scanRemnants() {
        guard let app = chosenApp else { return }
        remnantTask?.cancel(); remnantGeneration += 1; let current = remnantGeneration
        isScanning = true; status = "正在检查 \(app.name) 的关联数据…"
        let siblings = applications
        remnantTask = Task {
            do {
                let scan = try await SoftwareService().remnants(for: app, siblings: siblings) { [weak self] category in Task { @MainActor in guard let self, self.remnantGeneration == current else { return }; self.status = "关联数据 · " + category } }
                guard !Task.isCancelled, remnantGeneration == current, selection == app.id else { return }
                didScanRemnants = true
                remnants = scan.remnants; selectedRemnants = Set(scan.remnants.filter(\.isSelectedByDefault).map(\.id)); remnantIssues = scan.issues
                status = scan.issues.isEmpty ? "发现 \(remnants.count) 项关联数据。" : "扫描未完成，已发现 \(remnants.count) 项。请查看扫描说明。"
            } catch is CancellationError { if remnantGeneration == current { status = "关联扫描已取消。" } }
            catch { if remnantGeneration == current { self.error = error.localizedDescription } }
            if remnantGeneration == current { isScanning = false; remnantTask = nil }
        }
    }
    func uninstall() {
        guard !isExecuting, let app = chosenApp else { return }
        let selected = chosenRemnants
        showReview = false; isExecuting = true; status = "执行前复核并移入废纸篓…"
        operationTask = Task {
            let results = await SoftwareService().uninstall(app, selectedRemnants: selected)
            outcomes = results; isExecuting = false; operationTask = nil; showResults = true
            let moved = Set(results.filter { $0.trashURL != nil }.map { $0.url.path })
            applications.removeAll { moved.contains($0.id) }; remnants.removeAll { moved.contains($0.id) }
            selectedRemnants.subtract(moved)
            if moved.contains(app.id) { selection = nil }
            status = Task.isCancelled ? "已停止 · 已移动 \(moved.count) 项，未执行项目仍保留；详情见结果。" : "已处理 \(moved.count) 项；具体跳过或错误见处理结果。"
        }
    }
    func launch(_ app: InstalledApplication) { if !NSWorkspace.shared.open(app.url) { error = "无法打开 \(app.name)。" } }
    func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "应用清单.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = applications.map { ["name": $0.name, "bundleID": $0.bundleID, "version": $0.version, "build": $0.build, "teamID": $0.teamID ?? "", "path": $0.url.path, "bytes": $0.size, "sizeIncomplete": $0.isSizeIncomplete] as [String: Any] }
            try JSONSerialization.data(withJSONObject: ["date": Date().ISO8601Format(), "applications": values, "issues": issues], options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}

struct SoftwareView: View {
    @State private var showSystem = false
    @StateObject private var model = SoftwareViewModel()
    @State private var showUnmatched = false
    @State private var showUpdates = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) { Text("软件管理").font(.largeTitle.bold()); Text("查看应用身份与空间，按证据复核关联数据。").foregroundStyle(.secondary) }
                Spacer()
                Button("系统级卸载") { showSystem = true }.disabled(model.isExecuting)
                Button { showUpdates = true } label: { Label("应用更新", systemImage: "arrow.down.app") }.disabled(model.isExecuting)
                Button { showUnmatched = true } label: { Label("未匹配数据", systemImage: "questionmark.folder") }.disabled(model.isExecuting)
                Button { model.showHistory = true } label: { Label("恢复记录", systemImage: "clock.arrow.circlepath") }
                if model.isLoading || model.isScanning || model.isExecuting { Button(model.isExecuting ? "停止后续操作" : "取消", role: .cancel) { model.cancel() } }
                else { Button { model.reload() } label: { Label(model.applications.isEmpty ? "读取应用" : "刷新列表", systemImage: "arrow.clockwise") }.buttonStyle(.borderedProminent).disabled(model.isExecuting) }
            }
            HStack {
                TextField("搜索应用、Bundle ID 或路径", text: $model.search).textFieldStyle(.roundedBorder)
                Picker("排序", selection: $model.order) { Text("名称").tag("名称"); Text("占用空间").tag("占用空间"); Text("最近修改").tag("最近修改") }.frame(width: 175)
                Text("\(model.filtered.count) 个应用").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Button { model.export() } label: { Image(systemName: "square.and.arrow.up") }.help("导出应用清单").disabled(model.applications.isEmpty)
            }
            if model.applications.isEmpty {
                ContentUnavailableView { Label(model.isLoading ? "正在读取应用" : "管理已安装应用", systemImage: "square.stack.3d.up") } description: { Text(model.isLoading ? model.status : "读取应用、个人应用及系统应用目录。此步骤只读取身份和大小，系统应用只能浏览。") }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { bounds in
                    HSplitView {
                    Table(model.filtered, selection: $model.selection) {
                        TableColumn("应用") { app in HStack(spacing: 10) { Image(nsImage: model.icon(app)).resizable().scaledToFit().frame(width: 32, height: 32); VStack(alignment: .leading, spacing: 3) { Text(app.name).fontWeight(.medium); Text(app.bundleID.isEmpty ? app.url.path : app.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }.padding(.vertical, 3).help(app.url.path) }.width(min: 180, ideal: 280)
                        TableColumn("版本") { app in Text(app.version).font(.caption) }.width(70)
                        TableColumn("大小") { app in Text((app.isSizeIncomplete ? "≥ " : "") + softwareBytes(app.size)).monospacedDigit().font(.caption) }.width(95)
                        TableColumn("状态") { app in Text(app.isProtected ? "受保护" : app.isRunning ? "运行中" : "").font(.caption).foregroundStyle(app.isProtected ? Color.secondary : Color.orange) }.width(65)
                    }.frame(minWidth: 400, maxWidth: .infinity).frame(height: bounds.size.height).disabled(model.isExecuting)
                    // Keep the same split-pane host across empty/selected states.
                    // Both native table and detail receive the actual available height.
                    Group {
                        if let app = model.chosenApp { detail(app) }
                        else { ContentUnavailableView("选择一个应用", systemImage: "cursorarrow.click", description: Text("查看版本、签名 Team ID 和关联数据。")) }
                    }.frame(minWidth: 300, idealWidth: 375, maxWidth: 470).frame(height: bounds.size.height, alignment: .top)
                    }.frame(width: bounds.size.width, height: bounds.size.height, alignment: .topLeading)
                }.frame(minHeight: 330, maxHeight: .infinity)
            }
            if !model.issues.isEmpty { DisclosureGroup("\(model.issues.count) 条无法读取的项目") { ScrollView { Text(model.issues.joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90) }.foregroundStyle(.secondary) }
            HStack { if model.isLoading || model.isScanning || model.isExecuting { ProgressView().controlSize(.small) }; Text(model.status).font(.caption).foregroundStyle(.secondary); Spacer() }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: model.selection) { _, _ in model.selectionChanged() }
            .sheet(isPresented: $model.showReview) { if let app = model.chosenApp { review(app) } }
            .sheet(isPresented: $model.showResults) { CleaningResultsView(results: model.outcomes) }
            .sheet(isPresented: $model.showHistory) { TrashHistoryView() }
            .sheet(isPresented: $showUnmatched) { UnmatchedRemnantsView() }
            .sheet(isPresented: $showUpdates) { ApplicationUpdatesView() }
            .sheet(isPresented: $showSystem) { SystemUninstallView(application: model.chosenApp) }
            .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private func detail(_ app: InstalledApplication) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) { Image(nsImage: model.icon(app)).resizable().scaledToFit().frame(width: 56, height: 56); VStack(alignment: .leading, spacing: 5) { Text(app.name).font(.title2.bold()); Text("\(app.version) (\(app.build))").foregroundStyle(.secondary) } }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow { Text("标识符").foregroundStyle(.secondary); Text(app.bundleID.isEmpty ? "未提供" : app.bundleID).textSelection(.enabled) }
                    GridRow { Text("Team ID").foregroundStyle(.secondary); Text(app.teamID ?? "不可用 / 未签名").textSelection(.enabled) }
                    GridRow { Text("大小").foregroundStyle(.secondary); Text((app.isSizeIncomplete ? "至少 " : "") + softwareBytes(app.size)) }
                }.font(.caption)
                Text(app.url.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack { Button("打开应用") { model.launch(app) }; Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }; Spacer() }
                Divider()
                HStack { Text("关联数据").font(.headline); Spacer(); Button(model.didScanRemnants ? "重新扫描" : "扫描") { model.scanRemnants() }.disabled(model.isScanning || model.isLoading || model.isExecuting) }
                Text("精确身份匹配可默认选择；应用支持数据与共享容器保留为需复核。").font(.caption).foregroundStyle(.secondary)
                if model.isScanning { HStack { ProgressView().controlSize(.small); Text("正在检查用户 Library…").font(.caption) } }
                if model.remnants.isEmpty && !model.isScanning { Text(model.didScanRemnants ? (model.remnantIssues.isEmpty ? "已检查的位置未发现关联数据。" : "已检查的位置未发现关联数据，部分位置未能完成检查。") : "扫描后显示有证据关联的项目，也可仅卸载应用本体。").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8) }
                ForEach(model.remnants) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("选择", isOn: Binding(get: { model.selectedRemnants.contains(item.id) }, set: { selected in if selected { model.selectedRemnants.insert(item.id) } else { model.selectedRemnants.remove(item.id) } })).labelsHidden().disabled(model.isExecuting)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(2)
                            HStack { Text(item.kind); Text(item.confidence.rawValue).foregroundStyle(item.confidence == .strong ? Color.green : Color.orange); Spacer(); Text((item.isSizeIncomplete ? "≥ " : "") + softwareBytes(item.size)).monospacedDigit() }.font(.caption2)
                            Text(item.evidence).font(.caption2).foregroundStyle(.secondary)
                            Text(item.url.path).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled)
                        }
                    }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8)).contextMenu { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }
                }
                if !model.remnantIssues.isEmpty { DisclosureGroup("扫描说明（\(model.remnantIssues.count)）") { Text(model.remnantIssues.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } }
                Divider()
                if app.isProtected { Label("系统应用或本应用受保护", systemImage: "lock.shield").foregroundStyle(.secondary).font(.caption) }
                else if app.isRunning { Label("请退出应用并刷新列表后卸载", systemImage: "app.badge").foregroundStyle(.orange).font(.caption) }
                Button { model.showReview = true } label: { Label("复核卸载", systemImage: "trash") }.buttonStyle(.borderedProminent).disabled(app.isProtected || app.isRunning || model.isScanning || model.isLoading || model.isExecuting)
            }.padding(16)
        }
    }
    private func review(_ app: InstalledApplication) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("卸载 \(app.name)？").font(.title2.bold())
            Text("应用本体和以下 \(model.chosenRemnants.count) 项数据将移入废纸篓。未选中的关联数据会保留。").foregroundStyle(.secondary)
            List {
                Section("应用") { VStack(alignment: .leading, spacing: 4) { Label(app.name, systemImage: "app").fontWeight(.medium); Text(app.url.path).font(.caption).foregroundStyle(.secondary) } }
                Section("已选关联数据") { ForEach(model.chosenRemnants) { item in VStack(alignment: .leading, spacing: 4) { HStack { Text(item.url.lastPathComponent); Spacer(); Text(softwareBytes(item.size)).monospacedDigit() }; Text(item.url.path).font(.caption).foregroundStyle(.secondary); Text(item.evidence).font(.caption).foregroundStyle(item.confidence == .strong ? Color.secondary : Color.orange) } } }
            }
            Text("执行时再次核对运行状态、路径和文件身份。应用本体处理失败时，不会继续移除关联数据。恢复记录中可尝试还原未被清空的项目。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("返回", role: .cancel) { model.showReview = false }; Spacer(); Button("移入废纸篓", role: .destructive) { model.uninstall() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 660, height: 500)
    }
}

private func softwareBytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
