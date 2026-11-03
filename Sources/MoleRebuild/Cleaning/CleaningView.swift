import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MoleCore

@MainActor
private final class CleaningViewModel: ObservableObject {
    @Published var items = [CleaningCandidate]()
    @Published var selected = Set<String>()
    @Published var focused = Set<String>()
    @Published var enabledCategories = Set(CleaningCategory.allCases)
    @Published var search = ""
    @Published var category = "全部分类"
    @Published var isBusy = false
    @Published var status = "选择分类后开始扫描。"
    @Published var issues = [String]()
    @Published var results = [TrashOperationResult]()
    @Published var error: String?
    @Published var showReview = false
    @Published var showResults = false
    @Published var showHistory = false
    private var scanTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var generation = 0
    var filtered: [CleaningCandidate] { items.filter { (category == "全部分类" || $0.category.rawValue == category) && (search.isEmpty || $0.url.path.localizedCaseInsensitiveContains(search)) } }
    var chosen: [CleaningCandidate] { items.filter { selected.contains($0.id) && $0.availability == .immediate && $0.safety != .blocked } }
    var chosenBytes: Int64 { chosen.reduce(0) { total, item in let result = total.addingReportingOverflow(item.size); return result.overflow ? Int64.max : result.partialValue } }
    var selectedDetail: CleaningCandidate? { items.first { focused.contains($0.id) } }
    func scan() {
        guard operationTask == nil else { return }
        scanTask?.cancel(); generation += 1; let current = generation
        isBusy = true; issues = []; error = nil; status = "正在准备扫描…"
        let categories = enabledCategories
        let exclusions = (UserDefaults.standard.stringArray(forKey: "cleaningExcludedPaths") ?? []).map { URL(fileURLWithPath: $0) }
        scanTask = Task {
            do {
                let scan = try await CleaningScanner().scan(categories: categories, excludedPaths: exclusions) { [weak self] text in
                    Task { @MainActor in guard let self, self.generation == current else { return }; self.status = text }
                }
                guard !Task.isCancelled, generation == current else { return }
                items = scan.items; selected = Set(scan.items.filter(\.isSelectedByDefault).map(\.id)); focused = []
                issues = scan.issues; status = "扫描完成 · \(items.count) 项 · \(scan.date.formatted(date: .omitted, time: .shortened))"
            } catch is CancellationError { if generation == current { status = "扫描已取消，保留此前结果。" } }
            catch { if generation == current { self.error = error.localizedDescription } }
            if generation == current { isBusy = false; scanTask = nil }
        }
    }
    func cancel() {
        if let operationTask {
            operationTask.cancel()
            status = "正在停止后续操作，等待已完成项目返回结果…"
            return
        }
        generation += 1; scanTask?.cancel(); scanTask = nil; isBusy = false; status = "扫描已取消，保留此前结果。"
    }
    func recommended() { selected = Set(items.filter(\.isSelectedByDefault).map(\.id)) }
    func exclude(_ item: CleaningCandidate) {
        var values = UserDefaults.standard.stringArray(forKey: "cleaningExcludedPaths") ?? []
        if !values.contains(item.url.path) { values.append(item.url.path); UserDefaults.standard.set(values, forKey: "cleaningExcludedPaths") }
        selected.remove(item.id); items.removeAll { $0.id == item.id }; status = "已加入排除名单：\(item.url.lastPathComponent)"
    }
    func execute() {
        guard operationTask == nil, !isBusy else { return }
        let requests = chosen.map(\.request)
        showReview = false; isBusy = true; generation += 1
        status = "正在复核并移入废纸篓…"
        operationTask = Task {
            let outcomes = await TrashService.shared.moveToTrash(requests)
            // Cancellation stops future requests; completed moves must still reach the UI.
            results = outcomes
            let moved = Set(outcomes.filter { $0.trashURL != nil }.map { $0.url.path })
            items.removeAll { moved.contains($0.id) }; selected.subtract(moved)
            focused.subtract(moved)
            let stopped = Task.isCancelled
            isBusy = false; operationTask = nil
            status = stopped ? "已停止 · 已移动 \(moved.count) 项，未执行项目仍保留；详情见结果。" : "已处理 \(moved.count) 项；\(outcomes.filter { !$0.succeeded }.count) 项需要查看结果。"
            showResults = true
        }
    }
    func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "清理扫描.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = items.map { ["path": $0.url.path, "category": $0.category.rawValue, "bytes": $0.size, "incomplete": $0.isSizeIncomplete, "safety": $0.safety.rawValue, "availability": $0.availability.rawValue, "reason": $0.reason] as [String: Any] }
            try JSONSerialization.data(withJSONObject: ["date": Date().ISO8601Format(), "items": values, "issues": issues], options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }
}

struct CleaningView: View {
    @StateObject private var model = CleaningViewModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("清理空间").font(.largeTitle.bold())
                    Text("按分类发现缓存和日志，复核后移入废纸篓。").foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.showHistory = true } label: { Label("恢复记录", systemImage: "clock.arrow.circlepath") }
                if model.isBusy { Button("取消", role: .cancel) { model.cancel() } }
                else { Button { model.scan() } label: { Label(model.items.isEmpty ? "开始扫描" : "重新扫描", systemImage: "magnifyingglass") }.buttonStyle(.borderedProminent).disabled(model.enabledCategories.isEmpty) }
            }
            HStack(spacing: 14) {
                summary("发现项目", value: "\(model.items.count)", icon: "square.stack.3d.up")
                summary("已选择", value: "\(model.chosen.count)", icon: "checkmark.circle")
                summary("选择大小", value: cleanBytes(model.chosenBytes), icon: "externaldrive")
                Spacer()
            }.padding(16).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
            HStack {
                Menu { ForEach(CleaningCategory.allCases) { category in Toggle(category.rawValue, isOn: Binding(get: { model.enabledCategories.contains(category) }, set: { value in if value { model.enabledCategories.insert(category) } else { model.enabledCategories.remove(category) } })) } } label: { Label("扫描分类", systemImage: "line.3.horizontal.decrease.circle") }.disabled(model.isBusy)
                Picker("显示", selection: $model.category) { Text("全部分类").tag("全部分类"); ForEach(CleaningCategory.allCases) { Text($0.rawValue).tag($0.rawValue) } }.labelsHidden().frame(width: 160)
                TextField("搜索名称或路径", text: $model.search).textFieldStyle(.roundedBorder)
                Button("恢复推荐") { model.recommended() }.disabled(model.isBusy || model.items.isEmpty)
                Button("取消选择") { model.selected = [] }.disabled(model.isBusy || model.selected.isEmpty)
                Button { model.export() } label: { Image(systemName: "square.and.arrow.up") }.help("导出扫描报告").disabled(model.items.isEmpty)
            }
            if model.items.isEmpty {
                ContentUnavailableView { Label(model.isBusy ? "正在扫描" : "检查可释放空间", systemImage: model.isBusy ? "magnifyingglass" : "sparkles") } description: { Text(model.isBusy ? model.status : "扫描不会修改文件。选中项目后，可以查看具体路径、大小和处理原因。") }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.filtered, selection: $model.focused) {
                    TableColumn("选择") { item in Toggle("选择", isOn: Binding(get: { model.selected.contains(item.id) }, set: { selected in if selected { model.selected.insert(item.id) } else { model.selected.remove(item.id) } })).labelsHidden().disabled(model.isBusy || item.availability != .immediate || item.safety == .blocked) }.width(42)
                    TableColumn("项目") { item in
                        VStack(alignment: .leading, spacing: 3) { Text(item.url.lastPathComponent).fontWeight(.medium); Text(item.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            .help(item.url.path).contextMenu {
                                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                Button("加入排除名单") { model.exclude(item) }.disabled(model.isBusy)
                            }
                    }.width(min: 210, ideal: 340)
                    TableColumn("分类") { item in Label(item.category.rawValue, systemImage: item.category.symbol).font(.caption) }.width(110)
                    TableColumn("大小") { item in Text((item.isSizeIncomplete ? "≥ " : "") + cleanBytes(item.size)).monospacedDigit() }.width(105)
                    TableColumn("建议") { item in Text(item.safety.rawValue).foregroundStyle(item.safety == .autoClean ? Color.green : Color.orange) }.width(70)
                    TableColumn("状态") { item in Text(item.availability.rawValue).foregroundStyle(item.availability == .immediate ? Color.secondary : Color.orange) }.width(80)
                }.frame(minHeight: 210)
                if let item = model.selectedDetail {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) { Text(item.reason); Text(item.url.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled); if let date = item.modifiedAt { Text("修改于 \(date.formatted())").font(.caption).foregroundStyle(.secondary) } }
                        Spacer()
                    }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            if !model.issues.isEmpty { DisclosureGroup("\(model.issues.count) 条扫描说明 / 无法访问的路径") { ScrollView { Text(model.issues.joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100) }.foregroundStyle(.secondary) }
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button { model.showReview = true } label: { Label("复核 \(model.chosen.count) 项", systemImage: "trash") }.buttonStyle(.borderedProminent).disabled(model.chosen.isEmpty || model.isBusy)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .sheet(isPresented: $model.showReview) { review }
            .sheet(isPresented: $model.showResults) { CleaningResultsView(results: model.results) }
            .sheet(isPresented: $model.showHistory) { TrashHistoryView() }
            .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private func summary(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) { Image(systemName: icon).font(.title2).foregroundStyle(.tint); VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.bold()).monospacedDigit() } }.frame(minWidth: 145, alignment: .leading)
    }
    private var review: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("复核清理项目").font(.title2.bold())
            Text("\(model.chosen.count) 项，所选文件合计 \(cleanBytes(model.chosenBytes))。移入废纸篓后仍占用磁盘空间。").foregroundStyle(.secondary)
            Text("可推荐 \(model.chosen.filter { $0.safety == .autoClean }.count) 项 · 需人工复核 \(model.chosen.filter { $0.safety == .reviewOnly }.count) 项").font(.callout)
            List(model.chosen) { item in HStack { VStack(alignment: .leading, spacing: 3) { Text(item.url.lastPathComponent); Text(item.url.path).font(.caption).foregroundStyle(.secondary); if item.safety == .reviewOnly { Text(item.reason).font(.caption).foregroundStyle(.orange) } }; Spacer(); Text(cleanBytes(item.size)).monospacedDigit() } }.frame(minHeight: 220)
            Text("执行前会重新检查路径、文件身份和应用占用；无法处理的项目会保留并列出原因。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("返回", role: .cancel) { model.showReview = false }; Spacer(); Button("移入废纸篓", role: .destructive) { model.execute() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 660, height: 480)
    }
}

struct CleaningResultsView: View {
    @Environment(\.dismiss) private var dismiss
    let results: [TrashOperationResult]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("处理结果").font(.title2.bold())
            Text("成功 \(results.filter(\.succeeded).count) 项，未处理 \(results.filter { !$0.succeeded }.count) 项。").foregroundStyle(.secondary)
            List(results) { result in HStack(alignment: .top) { Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(result.succeeded ? Color.green : Color.orange); VStack(alignment: .leading, spacing: 3) { Text(result.url.lastPathComponent); Text(result.url.path).font(.caption).foregroundStyle(.secondary); if let error = result.error { Text(error).font(.caption).foregroundStyle(.orange) }; if let trash = result.trashURL { Button("在废纸篓中显示") { NSWorkspace.shared.activateFileViewerSelecting([trash]) }.font(.caption) } } } }.frame(minHeight: 220)
            HStack { Spacer(); Button("完成") { dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 660, height: 460)
    }
}

struct TrashHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries = [TrashJournalEntry]()
    @State private var working: UUID?
    @State private var error: String?
    @State private var pending: TrashJournalEntry?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("废纸篓恢复记录").font(.title2.bold()); Spacer(); Button("刷新") { Task { await reload() } } }
            Text("只恢复由本应用记录的项目；原位置已有同名内容时不会覆盖。手动清空废纸篓后无法恢复。").font(.callout).foregroundStyle(.secondary)
            if entries.isEmpty { ContentUnavailableView("暂无操作记录", systemImage: "clock.arrow.circlepath", description: Text("本应用移入废纸篓的项目会记录在这里。")).frame(maxHeight: .infinity) }
            else {
                List(entries) { entry in
                    HStack(spacing: 12) { Image(systemName: entry.restoredAt == nil ? "trash" : "arrow.uturn.backward.circle.fill").foregroundStyle(entry.restoredAt == nil ? Color.secondary : Color.green); VStack(alignment: .leading, spacing: 4) { Text(entry.originalURL.lastPathComponent).fontWeight(.medium); Text(entry.originalURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled); Text(entry.date.formatted()).font(.caption2).foregroundStyle(.tertiary) }; Spacer(); if entry.restoredAt != nil { Text("已恢复").font(.caption).foregroundStyle(.green) } else if working == entry.id { ProgressView().controlSize(.small) } else { Button("恢复") { pending = entry }.disabled(working != nil) } }
                }
            }
            HStack { Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(minWidth: 680, minHeight: 460)
            .task { await reload() }
            .confirmationDialog("恢复到原位置？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                Button("恢复项目") { guard let entry = pending else { return }; pending = nil; working = entry.id; Task { do { try await TrashService.shared.restore(entry) } catch { self.error = error.localizedDescription }; await reload(); working = nil } }
                Button("取消", role: .cancel) { pending = nil }
            } message: { Text(pending?.originalURL.path ?? "") }
            .alert("无法恢复", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
    private func reload() async { entries = await TrashService.shared.history() }
}

private func cleanBytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
