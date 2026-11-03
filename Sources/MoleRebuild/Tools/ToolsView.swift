import SwiftUI
import AppKit
import MoleCore

private enum ToolsSection: String, CaseIterable, Identifiable {
    case maintenance = "维护", network = "网络修复", startup = "启动项", updates = "更新", hardware = "风扇与充电"
    var id: String { rawValue }
}

private struct ToolConfirmation: Identifiable {
    enum Operation {
        case maintenance(MaintenanceAction)
        case startup(StartupOperation, StartupItem)
        case updates([BrewUpdate])
    }
    let id = UUID()
    let title: String
    let detail: String
    let commands: [String]
    let requiresAdministrator: Bool
    let operation: Operation
}

@MainActor
private final class ToolsViewModel: ObservableObject {
    static let shared = ToolsViewModel()
    @Published var busy = false
    @Published var phase = ""
    @Published var output = ""
    @Published var error: String?
    @Published var pending: ToolConfirmation?
    @Published var startupItems: [StartupItem] = []
    @Published var startupIssues: [String] = []
    @Published var startupSearch = ""
    @Published var userOnly = true
    @Published var selectedStartupID: String?
    @Published var updates: [BrewUpdate] = []
    @Published var selectedUpdates: Set<String> = []
    @Published var updatesCheckedAt: Date?
    @Published var lastCheckRefreshedMetadata = false
    @Published var awake = false
    @Published var awakeUntil: Date?
    @Published var awakeMinutes = 60
    @Published var keepDisplayAwake = false
    private var operation: Task<Void, Never>?
    private let startups = StartupManager()
    let brew = BrewUpdateService()

    var displayedStartups: [StartupItem] {
        startupItems.filter { item in
            (!userOnly || item.canManage) && (startupSearch.isEmpty || item.label.localizedCaseInsensitiveContains(startupSearch) || item.program.localizedCaseInsensitiveContains(startupSearch))
        }
    }
    var selectedStartup: StartupItem? { startupItems.first { $0.id == selectedStartupID } }
    var selectedPackages: [BrewUpdate] { updates.filter { selectedUpdates.contains($0.id) && !$0.pinned } }

    private func perform(_ title: String, category: String, record: Bool = true, action: @escaping @MainActor () async throws -> String) {
        guard !busy else { return }
        busy = true; error = nil; phase = title; output = "\(title)…\n"
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await action()
                try Task.checkCancellation()
                output = text.isEmpty ? "操作已完成。" : text
                if record { await ActivityStore.shared.append(ActivityRecord(category: category, title: title, detail: String(output.suffix(16_000)))) }
            } catch is CancellationError {
                output += "\n已请求终止并停止等待。已经完成的步骤不会撤销；Homebrew 或管理员子任务可能继续运行。"
                if record { await ActivityStore.shared.append(ActivityRecord(category: category, title: title, detail: "用户请求停止", succeeded: false)) }
            } catch {
                self.error = error.localizedDescription; output += "\n\(error.localizedDescription)"
                if record { await ActivityStore.shared.append(ActivityRecord(category: category, title: title, detail: String(error.localizedDescription.suffix(16_000)), succeeded: false)) }
            }
            busy = false; phase = ""; operation = nil
        }
    }
    func cancel() { operation?.cancel() }
    func prepare(_ action: MaintenanceAction) {
        pending = ToolConfirmation(title: action.title, detail: action.detail, commands: action.commands.map(\.display), requiresAdministrator: action.requiresAdministrator, operation: .maintenance(action))
    }
    func refreshStartups() {
        perform("读取启动项", category: "启动项", record: false) { [self] in
            let scan = try await startups.scan(); startupItems = scan.items; startupIssues = scan.issues
            return "读取 \(scan.items.count) 个启动项。\n" + scan.issues.joined(separator: "\n")
        }
    }
    func inspectStartup() {
        guard let item = selectedStartup else { return }
        perform("检查 \(item.label)", category: "启动项", record: false) { [self] in
            let (state, text) = try await startups.runtime(for: item)
            if let index = startupItems.firstIndex(where: { $0.id == item.id }) { startupItems[index].runtime = state }
            return text
        }
    }
    func prepareStartup(_ action: StartupOperation) {
        guard let item = selectedStartup, item.canManage, !busy else { return }
        Task {
            do {
                let commands = try await startups.commands(for: action, item: item)
                pending = ToolConfirmation(title: "\(action.rawValue)：\(item.label)",
                    detail: action == .disable ? "将停用此用户启动服务，并卸载当前已加载的实例。关联应用的后台功能可能暂停；可以之后重新允许和加载。" : "仅修改当前用户 launchd 域。允许下次启动不会立即运行服务，立即加载也不会改变原 plist 的配置。",
                    commands: commands.map(\.display), requiresAdministrator: false, operation: .startup(action, item))
            } catch { self.error = error.localizedDescription }
        }
    }
    func checkUpdates(refreshMetadata: Bool = true) {
        perform(refreshMetadata ? "联网刷新 Homebrew 并检查" : "检查 Homebrew 本地元数据", category: "更新", record: false) { [self] in
            updates = try await brew.check(refreshMetadata: refreshMetadata); selectedUpdates = Set(updates.filter { !$0.pinned }.map(\.id)); updatesCheckedAt = Date(); lastCheckRefreshedMetadata = refreshMetadata
            return updates.isEmpty ? (refreshMetadata ? "配方元数据已刷新，未报告可更新项目。" : "当前本地元数据未报告可更新项目；没有联网刷新配方库。") : "发现 \(updates.count) 个可更新项目。升级前请复核选择。"
        }
    }
    func prepareUpdates() {
        let packages = selectedPackages
        guard !packages.isEmpty else { return }
        do {
            pending = ToolConfirmation(title: "升级 \(packages.count) 个 Homebrew 项目", detail: "Homebrew 会下载并安装选中的版本，可能重新启动或替换应用。请先保存工作并退出相关应用；中止不会回滚已经升级的项目。" + (lastCheckRefreshedMetadata ? "本轮检查已刷新配方库。" : "本轮仅检查了本地配方元数据。"),
                commands: try packages.map { try brew.upgradeCommand(for: $0).display }, requiresAdministrator: false, operation: .updates(packages))
        } catch { self.error = error.localizedDescription }
    }
    func confirm() {
        guard let pending else { return }; self.pending = nil
        switch pending.operation {
        case .maintenance(let action):
            perform(action.title, category: "维护") {
                let results = try await MaintenanceService().execute(action)
                return results.map { "$ \($0.command)\n\($0.output)\n退出码 \($0.exitCode) · \(String(format: "%.1f", $0.duration)) 秒" }.joined(separator: "\n\n")
            }
        case .startup(let action, let item):
            perform(pending.title, category: "启动项") { [self] in
                let results = try await startups.execute(action, item: item)
                var text = results.isEmpty ? "此服务已处于目标状态。" : results.map { "$ \($0.command)\n\($0.output)\n退出码 \($0.exitCode)" }.joined(separator: "\n\n")
                do { let scan = try await startups.scan(); startupItems = scan.items; startupIssues = scan.issues }
                catch { text += "\n操作已执行，但列表刷新失败：\(error.localizedDescription)" }
                return text
            }
        case .updates(let packages):
            perform(pending.title, category: "更新") { [self] in
                var log = ""
                for (index, package) in packages.enumerated() {
                    try Task.checkCancellation(); phase = "升级 \(package.name)（\(index + 1)/\(packages.count)）"
                    let result = try await brew.upgrade(package)
                    log += "$ \(result.command)\n\(result.output)\n\n"
                    output = log
                    updates.removeAll { $0.id == package.id }; selectedUpdates.remove(package.id)
                }
                return log
            }
        }
    }
    func refreshAwake() async {
        let state = await KeepAwakeService.shared.state(); awake = state.active; awakeUntil = state.until
    }
    func toggleAwake() {
        Task {
            do {
                if awake {
                    await KeepAwakeService.shared.stop()
                    await ActivityStore.shared.append(ActivityRecord(category: "维护", title: "停止防睡眠"))
                } else {
                    try await KeepAwakeService.shared.start(seconds: awakeMinutes == 0 ? nil : awakeMinutes * 60, keepDisplayAwake: keepDisplayAwake)
                    await ActivityStore.shared.append(ActivityRecord(category: "维护", title: "开启防睡眠", detail: awakeMinutes == 0 ? "直到停止或退出应用" : "\(awakeMinutes) 分钟"))
                }
                await refreshAwake()
            } catch { self.error = error.localizedDescription }
        }
    }
    func open(_ url: String) {
        guard let value = URL(string: url), NSWorkspace.shared.open(value) else { error = "无法打开系统面板。"; return }
    }
}

struct ToolsView: View {
    @StateObject private var model = ToolsViewModel.shared
    @State private var section: ToolsSection = .maintenance
    @State private var showsOutput = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("维护与管理").font(.largeTitle.bold())
                    Text("按需执行维护，检查后台服务与软件更新。").foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small); Text(model.phase).font(.caption); Button("停止", role: .cancel) { model.cancel() } }
            }
            Picker("功能", selection: $section) { ForEach(ToolsSection.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if let error = model.error {
                HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange); Text(error).font(.callout).textSelection(.enabled); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                    .padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            // Give every tab a concrete viewport, including its initial empty state.
            // An unconstrained conditional Group lets AppKit-backed content report
            // its fitting height and centers short tabs in the remaining space.
            GeometryReader { bounds in
                Group {
                    switch section {
                    case .maintenance: maintenance
                    case .network: NetworkRepairView()
                    case .startup: startups
                    case .updates: updates
                    case .hardware: HardwareControlView()
                    }
                }.frame(width: bounds.size.width, height: bounds.size.height, alignment: .topLeading)
            }
            if !model.output.isEmpty && section != .network && section != .hardware {
                DisclosureGroup("执行输出", isExpanded: $showsOutput) {
                    ScrollView { Text(model.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10) }
                        .frame(height: 145).background(.background, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $model.pending) { confirmation in
            VStack(alignment: .leading, spacing: 18) {
                Label(confirmation.title, systemImage: "checklist").font(.title2.bold())
                Text(confirmation.detail).fixedSize(horizontal: false, vertical: true)
                if confirmation.requiresAdministrator { Label("系统将请求管理员授权", systemImage: "lock.shield").foregroundStyle(.orange) }
                DisclosureGroup("查看操作详情") {
                    ScrollView { Text(confirmation.commands.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }.frame(maxHeight: 180)
                }
                HStack { Spacer(); Button("取消") { model.pending = nil }.keyboardShortcut(.cancelAction); Button("确认执行") { model.confirm() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 640)
        }
        .task {
            while !Task.isCancelled { await model.refreshAwake(); try? await Task.sleep(for: .seconds(2)) }
        }
    }

    private var maintenance: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    HStack(spacing: 16) {
                        Image(systemName: model.awake ? "cup.and.saucer.fill" : "cup.and.saucer").font(.system(size: 30)).foregroundStyle(model.awake ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.awake ? "正在保持唤醒" : "防止空闲睡眠").font(.headline)
                            if model.awake, let until = model.awakeUntil { Text("结束于 \(until.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                            else { Text("退出应用时自动结束。不会更改系统永久睡眠设置。").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Picker("时长", selection: $model.awakeMinutes) { Text("30 分钟").tag(30); Text("1 小时").tag(60); Text("2 小时").tag(120); Text("直到停止").tag(0) }.frame(width: 135).disabled(model.awake)
                        Toggle("屏幕常亮", isOn: $model.keepDisplayAwake).toggleStyle(.checkbox).disabled(model.awake)
                        Button(model.awake ? "停止" : "开启") { model.toggleAwake() }.buttonStyle(.borderedProminent)
                    }.padding(8)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 255), spacing: 14)], spacing: 14) {
                    ForEach(MaintenanceAction.allCases) { action in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Image(systemName: action.symbol).font(.title2).foregroundStyle(.blue); Spacer(); if action.requiresAdministrator { Image(systemName: "lock.fill").foregroundStyle(.secondary) } }
                            Text(action.title).font(.headline)
                            Text(action.detail).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 65, alignment: .topLeading)
                            HStack { if !action.isAvailable { Text("此系统不提供").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("复核并执行…") { model.prepare(action) }.disabled(model.busy || !action.isAvailable) }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }

    private var startups: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("搜索服务名称或程序路径", text: $model.startupSearch).textFieldStyle(.roundedBorder)
                Toggle("仅用户项目", isOn: $model.userOnly).toggleStyle(.checkbox)
                Button("重新载入", systemImage: "arrow.clockwise") { model.refreshStartups() }.disabled(model.busy)
            }
            if model.startupItems.isEmpty {
                ContentUnavailableView { Label("检查启动项", systemImage: "power") } description: { Text("读取 launchd 配置，并区分用户项目与只读系统项目。") } actions: { Button("读取启动项") { model.refreshStartups() }.disabled(model.busy) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.displayedStartups, selection: $model.selectedStartupID) {
                    TableColumn("服务") { item in VStack(alignment: .leading, spacing: 3) { Text(item.label).lineLimit(1); Text(item.program).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }.width(min: 220, ideal: 340)
                    TableColumn("范围") { item in Text(item.scope.rawValue).foregroundStyle(.secondary) }.width(100)
                    TableColumn("自动启动") { item in Text(item.effectiveDisabled ? "已停用" : (item.runAtLoad || item.keepAlive ? "是" : "按需")) }.width(90)
                    TableColumn("当前实例") { item in Text(item.runtime.rawValue).foregroundStyle(.secondary) }.width(90)
                }
                if let item = model.selectedStartup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("检查运行状态") { model.inspectStartup() }.disabled(model.busy)
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            Spacer()
                            if item.canManage {
                                Menu("管理用户服务") { ForEach(StartupOperation.allCases) { action in Button(action.rawValue) { model.prepareStartup(action) } } }.disabled(model.busy)
                            } else { Label("系统和共享目录只读", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                } else { Text("选择项目后可检查状态；仅当前用户 LaunchAgents 支持管理。").font(.caption).foregroundStyle(.secondary) }
                if !model.startupIssues.isEmpty { Text("\(model.startupIssues.count) 项读取提示，详见执行输出。").font(.caption).foregroundStyle(.orange) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var updates: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) { Label("macOS", systemImage: "apple.logo").font(.headline); Text("由系统软件更新处理签名、安装与重启。").font(.caption).foregroundStyle(.secondary); Button("打开系统更新") { model.open("x-apple.systempreferences:com.apple.Software-Update-Settings.extension") } }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) { Label("App Store", systemImage: "bag").font(.headline); Text("使用 App Store 账户管理已购买应用更新。").font(.caption).foregroundStyle(.secondary); Button("打开更新页面") { model.open("macappstore://showUpdatesPage") } }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) { Text("Homebrew").font(.title3.bold()); Text(model.brew.executable ?? "未发现 Homebrew，不会自动安装").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let date = model.updatesCheckedAt { Text("检查于 \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                Button("联网检查", systemImage: "arrow.clockwise") { model.checkUpdates() }.disabled(model.busy || model.brew.executable == nil)
                Menu { Button("仅检查本地元数据") { model.checkUpdates(refreshMetadata: false) } } label: { Image(systemName: "ellipsis") }.disabled(model.busy || model.brew.executable == nil)
            }
            if model.updates.isEmpty {
                ContentUnavailableView { Label(model.updatesCheckedAt == nil ? "检查已安装的软件包" : "未发现可升级项目", systemImage: "shippingbox") } description: { Text("联网检查先刷新 Homebrew 配方库，不会安装软件包；升级会按你的选择下载并安装。固定版本项目不会自动选中。") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Button("全选") { model.selectedUpdates = Set(model.updates.filter { !$0.pinned }.map(\.id)) }
                    Button("全不选") { model.selectedUpdates = [] }
                    Spacer(); Text("已选择 \(model.selectedPackages.count) 项").font(.caption).foregroundStyle(.secondary)
                    Button("复核并升级…") { model.prepareUpdates() }.buttonStyle(.borderedProminent).disabled(model.busy || model.selectedPackages.isEmpty)
                }
                List(model.updates) { update in
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(get: { model.selectedUpdates.contains(update.id) }, set: { selected in if selected { model.selectedUpdates.insert(update.id) } else { model.selectedUpdates.remove(update.id) } })) { EmptyView() }.toggleStyle(.checkbox).labelsHidden().disabled(update.pinned || model.busy)
                        VStack(alignment: .leading, spacing: 4) { Text(update.name).font(.headline); Text(update.kind == .cask ? "应用（Cask）" : "命令行软件包").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Text(update.installedVersions).foregroundStyle(.secondary); Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(update.currentVersion).monospacedDigit()
                        if update.pinned { Label("固定", systemImage: "pin.fill").font(.caption) }
                    }.padding(.vertical, 5)
                }.listStyle(.inset)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
