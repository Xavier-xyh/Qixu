import SwiftUI
import AppKit
import MoleCore

@MainActor
private final class UnmatchedRemnantsModel: ObservableObject {
    @Published var items = [UnmatchedRemnant]()
    @Published var selected = Set<String>()
    @Published var search = ""
    @Published var issues = [String]()
    @Published var isScanning = false
    @Published var isExecuting = false
    @Published var hasScanned = false
    @Published var status = "点击扫描后读取应用身份与明确的用户数据目录。"
    @Published var showReview = false
    @Published var showResults = false
    @Published var outcomes = [TrashOperationResult]()
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var generation = 0
    var visible: [UnmatchedRemnant] { items.filter { search.isEmpty || $0.url.path.localizedCaseInsensitiveContains(search) || $0.identifier.localizedCaseInsensitiveContains(search) } }
    var chosen: [UnmatchedRemnant] { items.filter { selected.contains($0.id) } }
    @Published private(set) var applicationPaths = UserDefaults.standard.stringArray(
        forKey: UnmatchedRemnantService.additionalApplicationPathsKey
    ) ?? []

    func addApplicationFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择存放应用的文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        updateApplicationPaths(Array(Set(applicationPaths + paths)).sorted())
    }

    func removeApplicationFolder(_ path: String) {
        updateApplicationPaths(applicationPaths.filter { $0 != path })
    }

    private func updateApplicationPaths(_ paths: [String]) {
        guard paths != applicationPaths else { return }
        applicationPaths = paths
        UserDefaults.standard.set(paths, forKey: UnmatchedRemnantService.additionalApplicationPathsKey)
        items = []
        selected = []
        issues = []
        hasScanned = false
        status = "应用目录已更新，请重新扫描。"
    }
    func scan() {
        task?.cancel(); generation += 1; let current = generation
        isScanning = true; issues = []; selected = []; status = "正在核对应用身份…"
        let exclusions = (UserDefaults.standard.stringArray(forKey: "cleaningExcludedPaths") ?? []).map { URL(fileURLWithPath: $0) }
        task = Task {
            do {
                let result = try await UnmatchedRemnantService().scan(excludedPaths: exclusions) { [weak self] value in Task { @MainActor in guard let self, self.generation == current else { return }; self.status = "扫描 · " + value } }
                guard !Task.isCancelled, generation == current else { return }
                items = result.items; issues = result.issues; hasScanned = true
                status = issues.isEmpty ? "发现 \(items.count) 项未匹配数据，均需人工复核。" : "扫描未完整完成，请查看扫描说明。"
            } catch is CancellationError { if generation == current { status = "扫描已取消。" } }
            catch { if generation == current { self.error = error.localizedDescription } }
            if generation == current { isScanning = false; task = nil }
        }
    }
    func cancel() {
        if isExecuting { task?.cancel(); status = "正在停止后续操作，等待已完成项目返回结果…"; return }
        generation += 1; task?.cancel(); task = nil; isScanning = false; status = "扫描已取消，保留已有结果。"
    }
    func move() {
        let targets = chosen
        guard !targets.isEmpty else { return }
        showReview = false; isExecuting = true; status = "重新核对应用清单、运行状态与文件身份…"
        task = Task {
            outcomes = await UnmatchedRemnantService().moveReviewedToTrash(targets)
            let moved = Set(outcomes.filter { $0.trashURL != nil }.map { $0.url.path })
            items.removeAll { moved.contains($0.id) }; selected.subtract(moved)
            isExecuting = false; showResults = true; task = nil
            status = Task.isCancelled ? "已停止 · 已移动 \(moved.count) 项，未执行项目仍保留；详情见结果。" : "已移入废纸篓 \(moved.count) 项，详情见处理结果。"
        }
    }
}

struct UnmatchedRemnantsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = UnmatchedRemnantsModel()
    @State private var showHistory = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("未匹配数据").font(.title.bold()); Text("未匹配，需复核").font(.subheadline).foregroundStyle(.orange) }
                Spacer()
                Menu("应用目录（\(model.applicationPaths.count)）") {
                    Button("添加目录…") { model.addApplicationFolder() }
                    if !model.applicationPaths.isEmpty { Divider() }
                    ForEach(model.applicationPaths, id: \.self) { path in
                        Button("从核对范围移除 \(path)") { model.removeApplicationFolder(path) }
                    }
                }.disabled(model.isScanning || model.isExecuting)
                Button("恢复记录") { showHistory = true }
                if model.isExecuting { Button("停止后续操作", role: .cancel) { model.cancel() } }
                else if model.isScanning { Button("取消扫描", role: .cancel) { model.cancel() } }
                else { Button(model.hasScanned ? "重新扫描" : "扫描") { model.scan() }.buttonStyle(.borderedProminent).disabled(model.isExecuting) }
                Button("完成") { dismiss() }.disabled(model.isExecuting)
            }
            Text("仅检查用户缓存、偏好与日志中结构明确的应用标识符名称。未匹配当前应用清单不能证明文件已无用途：便携应用、其他磁盘和已退出的后台程序仍可能使用它们。请逐项在 Finder 中确认；共享容器和应用支持数据不在此扫描范围。").font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("搜索标识符或路径", text: $model.search).textFieldStyle(.roundedBorder)
                Text("已选 \(model.chosen.count) 项").font(.caption).foregroundStyle(.secondary)
                Button("清空选择") { model.selected = [] }.disabled(model.selected.isEmpty || model.isExecuting)
            }
            if model.items.isEmpty {
                ContentUnavailableView(model.isScanning ? "正在核对" : model.hasScanned ? (model.issues.isEmpty ? "没有待复核项目" : "扫描未完整完成") : "按需扫描用户数据", systemImage: "questionmark.folder", description: Text(model.isScanning || !model.issues.isEmpty ? model.status : "所有处理均需再次确认。")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.visible) {
                    TableColumn("选择") { item in Toggle("选择 \(item.identifier)", isOn: Binding(get: { model.selected.contains(item.id) }, set: { value in if value { model.selected.insert(item.id) } else { model.selected.remove(item.id) } })).labelsHidden().disabled(model.isExecuting || model.isScanning) }.width(42)
                    TableColumn("项目 / 路径") { item in VStack(alignment: .leading, spacing: 4) { Text(item.identifier).fontWeight(.medium); Text(item.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2) }.padding(.vertical, 4).contextMenu { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } } }.width(min: 300, ideal: 430)
                    TableColumn("类型") { item in Text(item.kind).font(.caption) }.width(70)
                    TableColumn("大小") { item in Text((item.isSizeIncomplete ? "≥ " : "") + ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption).monospacedDigit() }.width(100)
                    TableColumn("判断") { _ in Text("未匹配，需复核").font(.caption).foregroundStyle(.orange) }.width(125)
                }.frame(minHeight: 260)
            }
            if !model.issues.isEmpty { DisclosureGroup("扫描说明（\(model.issues.count)）") { ScrollView { Text(model.issues.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100) } }
            HStack { if model.isScanning || model.isExecuting { ProgressView().controlSize(.small) }; Text(model.status).font(.caption).foregroundStyle(.secondary); Spacer(); Button("复核所选项目") { model.showReview = true }.disabled(model.selected.isEmpty || model.isScanning || model.isExecuting) }
        }.padding(24).frame(width: 920, height: 640)
            .sheet(isPresented: $model.showReview) { review }
            .sheet(isPresented: $model.showResults) { CleaningResultsView(results: model.outcomes) }
            .sheet(isPresented: $showHistory) { TrashHistoryView() }
            .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.error ?? "") }
            .onDisappear { if !model.isExecuting { model.cancel() } }
    }
    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("移入废纸篓前复核").font(.title2.bold())
            Text("以下 \(model.chosen.count) 项只是未匹配当前已安装应用，仍可能包含有效设置或日志。确认已逐项检查后再处理。").foregroundStyle(.secondary)
            List(model.chosen) { item in VStack(alignment: .leading, spacing: 5) { HStack { Text(item.identifier).fontWeight(.medium); Spacer(); Text("需复核").foregroundStyle(.orange) }; Text(item.url.path).font(.caption).textSelection(.enabled) } }
            Text("执行前重新读取应用身份及运行状态，并检查排除路径和文件身份。匹配到应用、文件已变化或无法完整核对时会跳过。仅移入废纸篓，恢复不会覆盖原位置项目。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("返回", role: .cancel) { model.showReview = false }; Spacer(); Button("确认移入废纸篓", role: .destructive) { model.move() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 680, height: 500)
    }
}
