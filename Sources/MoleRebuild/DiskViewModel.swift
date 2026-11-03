import SwiftUI
import AppKit
import MoleCore

@MainActor
final class DiskViewModel: ObservableObject {
    @Published var result: DiskScanResult?
    @Published var currentURL: URL?
    @Published var selectedID: String?
    @Published var isScanning = false
    @Published var isSizing = false
    @Published var status = "选择一个文件夹开始分析"
    @Published var error: String?
    @Published var cacheNotice: String?
    @Published var lowerBounds: [String: Int64] = [:]
    @Published var search = ""
    @Published var sort: DiskSort = .size
    @Published var showHidden = UserDefaults.standard.bool(forKey: "diskShowHidden")
    @Published private(set) var history: [URL] = []
    @Published private(set) var historyIndex = -1
    private let scanner = DiskScanner()
    private let cache: DiskCacheStore
    private let activity: ActivityStore
    private var task: Task<Void, Never>?
    private var folderPanel: NSOpenPanel?
    private var generation: UInt64 = 0
    private var memory: [String: DiskScanResult] = [:]
    private var memoryOptions: DiskScanOptions?
    private var accessOrder: [String] = []
    private struct NavigationState { var result: DiskScanResult?; var url: URL?; var history: [URL]; var index: Int; var selected: String? }
    private var snapshot: NavigationState?
    init(cache: DiskCacheStore = DiskCacheStore(), activity: ActivityStore = .shared) {
        self.cache = cache; self.activity = activity
    }
    enum DiskSort: String, CaseIterable { case size = "大小", name = "名称", modified = "修改时间" }
    var canBack: Bool { historyIndex > 0 }
    var canForward: Bool { historyIndex >= 0 && historyIndex < history.count - 1 }
    var selected: DiskEntry? { result?.entries.first { $0.id == selectedID } }
    var entries: [DiskEntry] {
        let values = (result?.entries ?? []).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        return values.sorted {
            switch sort {
            case .size: return $0.size == $1.size ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.size > $1.size
            case .name: return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            case .modified: return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
        }
    }
    var breadcrumbs: [URL] {
        guard var url = currentURL else { return [] }
        var values = [url]
        while url.path != "/" { url.deleteLastPathComponent(); values.insert(url, at: 0) }
        return values
    }
    private var options: DiskScanOptions {
        let excluded = (UserDefaults.standard.string(forKey: "excludedPaths") ?? "").split(separator: "\n").map(String.init) + (UserDefaults.standard.stringArray(forKey: "cleaningExcludedPaths") ?? [])
        let budget = UserDefaults.standard.double(forKey: "directoryScanBudget")
        return DiskScanOptions(directoryBudget: budget > 0 ? min(2, max(0.1, budget)) : 0.25, showHidden: showHidden, excludedPaths: Set(excluded))
    }
    func chooseFolder() {
        guard folderPanel == nil else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "分析文件夹"; panel.message = "选择需要分析的文件夹。符号链接和其他挂载卷不会被递归跟随。"
        folderPanel = panel
        // Present after navigation/sheet dismissal has settled. A nested runModal
        // loop from a SwiftUI menu action can interfere with the prior sheet.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel else { return }
            let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
                Task { @MainActor in
                    guard let self else { return }
                    let selectedURL = panel?.url
                    self.folderPanel = nil
                    if response == .OK, let selectedURL { self.open(selectedURL) }
                }
            }
            if let window = NSApplication.shared.mainWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
            else { panel.begin(completionHandler: completion) }
        }
    }
    func open(_ target: URL, force: Bool = false, historyTarget: Int? = nil) {
        let url = target.standardizedFileURL
        task?.cancel(); generation &+= 1; let token = generation
        let stable = snapshot ?? NavigationState(result: result, url: currentURL, history: history, index: historyIndex, selected: selectedID)
        snapshot = stable
        if let historyTarget { historyIndex = historyTarget }
        else if currentURL != url {
            history = Array(history.prefix(max(0, historyIndex + 1))); history.append(url); historyIndex = history.count - 1
        } else if history.isEmpty { history = [url]; historyIndex = 0 }
        currentURL = url; result = nil; selectedID = nil; error = nil; cacheNotice = nil; lowerBounds = [:]; search = ""
        isScanning = true; isSizing = false; status = "正在读取 \(url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent)…"
        let opts = options
        if memoryOptions != opts { memory = [:]; accessOrder = []; memoryOptions = opts }
        task = Task { [weak self] in
            guard let self else { return }
            if !force {
                var cached = self.memory[url.path].map { DiskCacheHit(result: $0, isFresh: true) }
                if cached == nil { cached = await self.cache.load(url, options: opts) }
                guard self.accepts(token, url) else { return }
                if let cached {
                    self.result = cached.result; self.snapshot = nil
                    self.cacheNotice = cached.isFresh ? "已显示缓存，正在核对目录" : "已显示上次结果，正在重新扫描"
                }
            }
            do {
                let fresh = try await self.scanner.scan(url, options: opts) { [weak self] name, done, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.accepts(token, url) else { return }
                        self.status = total == 0 ? "文件夹为空" : "正在计算 \(done)/\(total) · \(name)"
                    }
                }
                guard self.accepts(token, url) else { return }
                self.commit(fresh); self.snapshot = nil; self.isScanning = false
                self.cacheNotice = nil
                do { try await self.cache.save(fresh, options: opts) }
                catch { if self.accepts(token, url) { self.cacheNotice = "结果已显示；缓存未保存：\(error.localizedDescription)" } }
                guard self.accepts(token, url) else { return }
                self.isSizing = fresh.incompleteCount > 0
                var measured = fresh
                for entry in fresh.entries where entry.isDirectory && entry.sizeStatus == .incomplete {
                    try Task.checkCancellation()
                    guard self.accepts(token, url) else { return }
                    self.status = "后台补算 · \(entry.name)"
                    let probe = try await self.scanner.measure(entry.url, budget: 8, options: opts) { [weak self] bytes in
                        Task { @MainActor [weak self] in
                            guard let self, self.accepts(token, url) else { return }
                            self.lowerBounds[entry.id] = max(self.lowerBounds[entry.id] ?? entry.size, bytes)
                        }
                    }
                    guard self.accepts(token, url), let index = measured.entries.firstIndex(where: { $0.id == entry.id }) else { return }
                    let lower = max(measured.entries[index].size, self.lowerBounds[entry.id] ?? 0)
                    measured.entries[index].size = probe.timedOut ? max(lower, probe.bytes) : probe.bytes
                    measured.entries[index].sizeStatus = (probe.timedOut || probe.issueCount > 0) ? .partial : .sized
                    measured.entries[index].issueCount = probe.issueCount
                    measured.issueCount = measured.entries.reduce(0) { $0 + $1.issueCount }
                    self.lowerBounds.removeValue(forKey: entry.id); self.commit(measured)
                }
                guard self.accepts(token, url) else { return }
                self.isSizing = false; self.status = self.summary(measured)
                do { try await self.cache.save(measured, options: opts) } catch { if self.accepts(token, url) { self.cacheNotice = "缓存未保存：\(error.localizedDescription)" } }
                await self.activity.append(ActivityRecord(category: "磁盘分析", title: url.lastPathComponent, detail: self.summary(measured)))
                guard self.accepts(token, url) else { return }
                let packages: Set<String> = ["app", "bundle", "framework", "photoslibrary", "vmwarevm", "pvm"]
                let candidates = measured.entries.filter { $0.isDirectory && $0.sizeStatus == .sized && !packages.contains($0.url.pathExtension.lowercased()) }.sorted { $0.size > $1.size }.prefix(4)
                for candidate in candidates {
                    try Task.checkCancellation()
                    guard self.accepts(token, url) else { return }
                    if self.memory[candidate.id] != nil { continue }
                    if let hit = await self.cache.load(candidate.url, options: opts), hit.isFresh {
                        if self.accepts(token, url) && self.memory[candidate.id] == nil { self.remember(hit.result) }
                        continue
                    }
                    guard self.accepts(token, url) else { return }
                    guard let prefetched = try? await self.scanner.scan(candidate.url, options: opts) else { continue }
                    guard self.accepts(token, url) else { return }
                    if self.memory[candidate.id] == nil { self.remember(prefetched) }
                }
            } catch is CancellationError {
                if self.generation == token { self.isScanning = false; self.isSizing = false; self.status = "已停止" }
            } catch {
                guard self.generation == token else { return }
                self.error = error.localizedDescription; self.restoreSnapshot()
                self.isScanning = false; self.isSizing = false; self.status = "分析失败"
            }
        }
    }
    func refresh() { if let currentURL { open(currentURL, force: true) } }
    func back() { if canBack { open(history[historyIndex - 1], historyTarget: historyIndex - 1) } }
    func forward() { if canForward { open(history[historyIndex + 1], historyTarget: historyIndex + 1) } }
    func cancel() {
        generation &+= 1; task?.cancel(); task = nil
        restoreSnapshot(); isScanning = false; isSizing = false; lowerBounds = [:]; status = "已停止，保留当前结果"
    }
    func hiddenChanged() { UserDefaults.standard.set(showHidden, forKey: "diskShowHidden"); memory = [:]; refresh() }
    func completeMeasurement(_ entry: DiskEntry) {
        guard entry.isDirectory, let root = result?.url else { return }
        task?.cancel(); generation &+= 1; let token = generation
        snapshot = nil; isScanning = false; isSizing = true; lowerBounds = [:]; error = nil
        let opts = options
        status = "完整测量 · \(entry.name)（可随时停止）"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let identity = try FileIdentity.capture(entry.url)
                guard let scanned = entry.scanIdentity, scanned == identity else { throw PathSafetyError.changedSinceScan }
                let probe = try await self.scanner.measure(entry.url, budget: 86_400, options: opts) { [weak self] bytes in
                    Task { @MainActor [weak self] in
                        guard let self, self.accepts(token, root) else { return }
                        self.lowerBounds[entry.id] = max(entry.size, bytes)
                    }
                }
                guard self.accepts(token, root), var value = self.result, let index = value.entries.firstIndex(where: { $0.id == entry.id }) else { return }
                guard try FileIdentity.capture(entry.url) == identity else { throw PathSafetyError.changedSinceScan }
                value.entries[index].size = probe.bytes
                value.entries[index].sizeStatus = (probe.timedOut || probe.issueCount > 0) ? .partial : .sized
                value.entries[index].issueCount = probe.issueCount
                value.issueCount = value.entries.reduce(0) { $0 + $1.issueCount }
                self.lowerBounds = [:]; self.commit(value); self.isSizing = false
                // Ancestor totals may describe older contents. Invalidate them rather than
                // rewriting totals with incomparable, independently timed measurements.
                for key in Array(self.memory.keys) where key != root.path && root.path.hasPrefix(key.hasSuffix("/") ? key : key + "/") { self.memory.removeValue(forKey: key) }
                try await self.cache.save(value, options: opts)
                await self.activity.append(ActivityRecord(category: "磁盘分析", title: "完整测量 \(entry.name)", detail: self.summary(value)))
            } catch is CancellationError {
                if self.generation == token { self.status = "测量已停止"; self.isSizing = false; self.lowerBounds = [:] }
            } catch {
                guard self.generation == token else { return }
                self.error = error.localizedDescription; self.status = "测量未完成，保留此前结果"; self.isSizing = false; self.lowerBounds = [:]
            }
        }
    }
    func clearCache() async {
        do { try await cache.clear(); memory = [:]; accessOrder = []; cacheNotice = "已清空磁盘分析缓存" }
        catch { self.error = error.localizedDescription }
    }
    func trash(_ entry: DiskEntry, root: URL, identity: FileIdentity) async {
        let outcomes = await TrashService.shared.moveToTrash([TrashRequest(url: entry.url, allowedRoot: root, expectedIdentity: identity)])
        if let failure = outcomes.first(where: { !$0.succeeded }) { error = failure.error ?? "移入废纸篓失败" }
        if currentURL == root { refresh() }
    }
    private func accepts(_ token: UInt64, _ url: URL) -> Bool { !Task.isCancelled && token == generation && currentURL == url }
    private func commit(_ value: DiskScanResult) {
        result = value; remember(value); status = summary(value)
    }
    private func remember(_ value: DiskScanResult) {
        memory[value.url.path] = value
        accessOrder.removeAll { $0 == value.url.path }; accessOrder.append(value.url.path)
        let protected = Set(breadcrumbs.map(\.path))
        while memory.count > 80, let index = accessOrder.firstIndex(where: { !protected.contains($0) }) {
            memory.removeValue(forKey: accessOrder.remove(at: index))
        }
    }
    private func restoreSnapshot() {
        if let state = snapshot { result = state.result; currentURL = state.url; history = state.history; historyIndex = state.index; selectedID = state.selected }
        snapshot = nil
    }
    private func summary(_ value: DiskScanResult) -> String {
        "\(value.entries.count) 项 · \(ByteCountFormatter.string(fromByteCount: value.totalSize, countStyle: .file))" + (value.issueCount > 0 ? " · \(value.issueCount) 处无法完整读取" : "")
    }
}
