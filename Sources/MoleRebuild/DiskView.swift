import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MoleCore

struct DiskView: View {
    @ObservedObject var model: DiskViewModel
    @State private var visualization = true
    @State private var pendingTrash: TrashChoice?
    @State private var exportError: String?
    @State private var showPathEntry = false
    @State private var folderPath = ""
    private struct TrashChoice: Identifiable { let id = UUID(); let entry: DiskEntry; let root: URL; let identity: FileIdentity }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("磁盘分析").font(.largeTitle.bold())
                    Text("找到占用空间的文件，保留每一次测量的真实状态。").foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.chooseFolder) { Label("选择文件夹", systemImage: "folder.badge.plus") }.buttonStyle(.borderedProminent)
                Button("输入路径") { folderPath = model.currentURL?.path ?? FileManager.default.homeDirectoryForCurrentUser.path; showPathEntry = true }.help("输入文件夹路径")
                Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }.disabled(model.currentURL == nil).help("重新扫描（⌘R）").keyboardShortcut("r")
            }
            navigation
            if let error = model.error { message(error, color: .red) }
            if let notice = model.cacheNotice { message(notice, color: .orange) }
            if let result = model.result {
                HStack(spacing: 14) {
                    diskStat("已知占用", ByteCountFormatter.string(fromByteCount: result.totalSize, countStyle: .file), icon: "chart.pie.fill", color: .teal)
                    diskStat("当前项目", "\(result.entries.count)", icon: "square.grid.2x2.fill", color: .blue)
                    diskStat("未完整测量", "\(result.entries.filter { $0.sizeStatus != .sized }.count)", icon: "hourglass", color: .orange)
                    diskStat("读取受限", "\(result.issueCount)", icon: "lock.shield", color: .purple)
                }
                HStack {
                    TextField("搜索当前文件夹", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                    Spacer()
                    Toggle("空间图", isOn: $visualization).toggleStyle(.switch)
                    Toggle("隐藏文件", isOn: $model.showHidden).toggleStyle(.switch).onChange(of: model.showHidden) { _, _ in model.hiddenChanged() }
                    Picker("排序", selection: $model.sort) { ForEach(DiskViewModel.DiskSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 130)
                    Button { export(result) } label: { Image(systemName: "square.and.arrow.up") }.help("导出 CSV")
                }
                if visualization && result.totalSize > 0 {
                    VStack(alignment: .leading, spacing: 5) { treemap.frame(height: 180); Text("按当前已知大小绘制" + (model.entries.count > 80 ? " · 前80项单独显示，其余合并" : "") + " · 双击进入文件夹").font(.caption2).foregroundStyle(.tertiary) }
                }
                fileList
                if let selected = model.selected { details(selected, total: result.totalSize) }
            } else if model.isScanning {
                VStack(spacing: 14) { ProgressView(); Text(model.status).foregroundStyle(.secondary); Button("停止", action: model.cancel) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { welcome }
            HStack(spacing: 8) {
                if model.isScanning || model.isSizing { ProgressView().controlSize(.small); Button("停止", action: model.cancel).buttonStyle(.link) }
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let result = model.result { Text(result.scannedAt, style: .time).font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showPathEntry) { DiskPathEntryView(path: $folderPath) { url in showPathEntry = false; model.open(url) } }
        .confirmationDialog("移入废纸篓？", isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }), titleVisibility: .visible) {
            if let choice = pendingTrash {
                Button("移入废纸篓", role: .destructive) { Task { await model.trash(choice.entry, root: choice.root, identity: choice.identity) }; pendingTrash = nil }
                Button("取消", role: .cancel) { pendingTrash = nil }
            }
        } message: { if let choice = pendingTrash { Text("\(choice.entry.url.path)\n可在“操作记录”中查看恢复记录。") } }
        .alert("无法导出", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("好") { exportError = nil } } message: { Text(exportError ?? "") }
    }
    private var navigation: some View {
        HStack(spacing: 8) {
            Button(action: model.back) { Image(systemName: "chevron.left") }.disabled(!model.canBack)
            Button(action: model.forward) { Image(systemName: "chevron.right") }.disabled(!model.canForward)
            ScrollViewReader { proxy in
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(model.breadcrumbs, id: \.path) { url in
                        Button(url.path == "/" ? "Macintosh HD" : url.lastPathComponent) { model.open(url) }.buttonStyle(.plain).foregroundStyle(url == model.currentURL ? Color.primary : Color.secondary).id(url.path)
                        if url != model.currentURL { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    }
                }.font(.callout)
              }
              .onAppear { if let url = model.currentURL { proxy.scrollTo(url.path, anchor: .trailing) } }
              .onChange(of: model.currentURL) { _, url in if let url { proxy.scrollTo(url.path, anchor: .trailing) } }
            }
            if let url = model.currentURL { Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }.help("在 Finder 中显示") }
        }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
    private var welcome: some View {
        VStack(spacing: 20) {
            Image(systemName: "chart.pie.fill").font(.system(size: 64)).foregroundStyle(.teal.gradient)
            Text("空间，从这里看清").font(.title2.bold())
            Text("选择一个文件夹，查看文件大小、目录分布与空间图。\n大目录会先显示部分结果，再在后台继续计算。").multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack { shortcut("下载", "Downloads", "arrow.down.circle"); shortcut("文稿", "Documents", "doc.text"); Button("应用程序") { model.open(URL(fileURLWithPath: "/Applications")) }.buttonStyle(.bordered) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func shortcut(_ title: String, _ folder: String, _ icon: String) -> some View {
        Button { model.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(folder)) } label: { Label(title, systemImage: icon) }.buttonStyle(.bordered)
    }
    private var fileList: some View {
        VStack(spacing: 0) {
            HStack { Text("名称"); Spacer(); Text("大小").frame(width: 155, alignment: .trailing); Text("状态").frame(width: 85); Text("占比").frame(width: 85) }.font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
            Divider()
            if model.entries.isEmpty {
                ContentUnavailableView(model.search.isEmpty ? "文件夹为空" : "没有匹配项目", systemImage: "folder", description: Text(model.search.isEmpty ? "此文件夹中没有可显示的普通文件或目录。" : "试试其他名称。"))
            } else {
                List(selection: $model.selectedID) {
                    ForEach(model.entries) { entry in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path)).resizable().frame(width: 26, height: 26)
                            Text(entry.name).lineLimit(1).truncationMode(.middle)
                            if entry.isDirectory { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                            Spacer()
                            Text(sizeLabel(entry)).font(.callout.monospacedDigit()).foregroundStyle(entry.sizeStatus == .sized ? Color.primary : Color.orange).frame(width: 155, alignment: .trailing)
                            Text(entry.sizeStatus.label).font(.caption).foregroundStyle(.secondary).frame(width: 85)
                            ProgressView(value: fraction(entry)).tint(tileColor(entry)).frame(width: 85)
                        }.padding(.vertical, 4).tag(entry.id).contentShape(Rectangle())
                            .onTapGesture(count: 2) { open(entry) }
                            .contextMenu { rowActions(entry) }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
        }.background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
    private var treemap: some View {
        GeometryReader { geometry in
            let entries = treemapEntries
            let tiles = DiskTreemapLayout.tiles(entries: entries, in: CGRect(origin: .zero, size: geometry.size))
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    RoundedRectangle(cornerRadius: 5).fill(tileColor(tile.entry).gradient)
                        .overlay(alignment: .topLeading) {
                            if tile.rect.width > 65 && tile.rect.height > 40 {
                                VStack(alignment: .leading, spacing: 3) { Text(tile.entry.name).font(.caption.weight(.semibold)).lineLimit(2); if tile.rect.height > 60 { Text(tile.entry.formattedSize).font(.caption2).opacity(0.85) } }.padding(8).foregroundStyle(.white).allowsHitTesting(false)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(model.selectedID == tile.id ? .white : .clear, lineWidth: 2))
                        .frame(width: max(0, tile.rect.width - 3), height: max(0, tile.rect.height - 3))
                        .offset(x: tile.rect.minX + 1.5, y: tile.rect.minY + 1.5)
                        .onTapGesture(count: 2) { if !isAggregate(tile.entry) { open(tile.entry) } }.onTapGesture { model.selectedID = isAggregate(tile.entry) ? nil : tile.id }
                        .contextMenu { if !isAggregate(tile.entry) { rowActions(tile.entry) } }
                        .help("\(tile.entry.name) · \(tile.entry.formattedSize)")
                        .accessibilityElement(children: .ignore).accessibilityLabel(tile.entry.name).accessibilityValue(tile.entry.formattedSize).accessibilityAddTraits(.isButton)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped().accessibilityElement(children: .contain).accessibilityLabel("按已知大小绘制的空间图")
        }
    }
    private var treemapEntries: [DiskEntry] {
        let values = model.entries.filter { $0.size > 0 }
        guard values.count > 80 else { return values }
        let remainder = values.dropFirst(80).reduce(Int64(0)) { sum, item in let (value, overflow) = sum.addingReportingOverflow(item.size); return overflow ? Int64.max : value }
        let root = model.result?.url ?? URL(fileURLWithPath: "/")
        return Array(values.prefix(80)) + [DiskEntry(url: root.appendingPathComponent(".mole-rebuild-aggregate"), name: "其余 \(values.count - 80) 项", size: remainder, isDirectory: false)]
    }
    private func isAggregate(_ entry: DiskEntry) -> Bool { entry.url.lastPathComponent == ".mole-rebuild-aggregate" && entry.identityInode == nil }
    private func rowActions(_ entry: DiskEntry) -> some View {
        Group {
            Button(entry.isDirectory ? "进入文件夹" : "打开文件") { open(entry) }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Button("复制路径") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.url.path, forType: .string) }
            if entry.isDirectory { Button("完整计算此目录") { model.completeMeasurement(entry) }.disabled(model.isScanning) }
            Divider()
            Button("移入废纸篓…", role: .destructive) { requestTrash(entry) }.disabled(model.isScanning)
        }
    }
    private func details(_ entry: DiskEntry, total: Int64) -> some View {
        HStack(spacing: 14) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill").font(.title2).foregroundStyle(tileColor(entry))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.url.path).font(.caption).textSelection(.enabled).lineLimit(2)
                Text(entry.sizeStatus == .sized ? "已完成测量" : "当前大小包含估算或部分结果；空间图按当前已知值绘制。").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if entry.isDirectory && entry.sizeStatus != .sized { Button("完整计算") { model.completeMeasurement(entry) }.disabled(model.isScanning) }
            if let date = entry.modifiedAt { Text(date, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary) }
            Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
    private func diskStat(_ title: String, _ value: String, icon: String, color: Color) -> some View {
        HStack { VStack(alignment: .leading, spacing: 8) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.title2.bold().monospacedDigit()) }; Spacer(); Image(systemName: icon).font(.title2).foregroundStyle(color) }.padding(16).frame(maxWidth: .infinity).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
    private func message(_ text: String, color: Color) -> some View { Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(color).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8)) }
    private func sizeLabel(_ entry: DiskEntry) -> String { if let value = model.lowerBounds[entry.id], value > entry.size { return "计算中 · " + ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }; return entry.formattedSize }
    private func fraction(_ entry: DiskEntry) -> Double { guard let total = model.result?.totalSize, total > 0 else { return 0 }; return min(1, Double(entry.size) / Double(total)) }
    private func tileColor(_ entry: DiskEntry) -> Color { let seed = entry.name.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }; return Color(hue: Double(seed % 360) / 360, saturation: 0.55, brightness: 0.77) }
    private func open(_ entry: DiskEntry) { if entry.isDirectory { model.open(entry.url) } else { NSWorkspace.shared.open(entry.url) } }
    private func requestTrash(_ entry: DiskEntry) {
        guard let root = model.result?.url else { return }
        do {
            let identity = try FileIdentity.capture(entry.url)
            guard let scanned = entry.scanIdentity, scanned == identity else { throw PathSafetyError.changedSinceScan }
            pendingTrash = TrashChoice(entry: entry, root: root, identity: identity)
        }
        catch { model.error = error.localizedDescription }
    }
    private func export(_ result: DiskScanResult) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "\(result.url.lastPathComponent)-空间分析.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try DiskReport.csv(result).write(to: url, atomically: true, encoding: .utf8) } catch { exportError = error.localizedDescription }
    }
}

private struct DiskPathEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var path: String
    let onOpen: (URL) -> Void
    @State private var submitted = false
    private var expanded: String { (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath }
    private var valid: Bool { expanded.hasPrefix("/") && !expanded.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("打开文件夹路径").font(.title2.bold())
            Text("粘贴文件夹的完整路径，也可以使用 ~/ 开头的个人目录路径。").foregroundStyle(.secondary)
            TextField("例如 ~/Downloads", text: $path).textFieldStyle(.roundedBorder).onSubmit(submit)
            HStack { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("开始分析", action: submit).buttonStyle(.borderedProminent).disabled(!valid || submitted).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 600)
    }
    private func submit() { guard valid, !submitted else { return }; submitted = true; onOpen(URL(fileURLWithPath: expanded, isDirectory: true)) }
}
