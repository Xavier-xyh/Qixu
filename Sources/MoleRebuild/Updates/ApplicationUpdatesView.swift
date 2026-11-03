import SwiftUI
import AppKit
import MoleCore

private struct ApplicationUpdateRow: Identifiable {
    let target: AppUpdateTarget
    var release: AppcastRelease?
    var status = "尚未联网检查"
    var checked = false
    var id: String { target.id }
}

@MainActor
private final class ApplicationUpdatesModel: ObservableObject {
    @Published var rows: [ApplicationUpdateRow] = []
    @Published var busy = false
    @Published var stopRequested = false
    @Published var downloadProgress: AppDownloadProgress?
    @Published var phase = "读取本机应用后，可以按需联网检查。"
    @Published var issues: [String] = []
    @Published var unsupportedCount = 0
    @Published var selection: String?
    @Published var error: String?
    @Published var pending: ApplicationUpdateRow?
    @Published var installedBackup: URL?
    @Published var hasRead = false
    @Published var recovery: [AppInstallRecoveryRecord] = []
    @Published var pendingRestore: AppBackupRestorePreview?
    @Published var restoredPreservedURL: URL?
    @Published var preparedPackage: PreparedPackageUpdate?
    @Published var handedOffPackageID: UUID?
    @Published var packageVersionStatus: String?
    private var task: Task<Void, Never>?
    private let service = AppcastService()
    private var generation = 0
    var selected: ApplicationUpdateRow? { rows.first { $0.id == selection } }
    func loadRecovery() {
        do { recovery = try AppcastUpdateInstaller().recoveryRecords() }
        catch { self.error = "无法读取更新恢复记录：\(error.localizedDescription)" }
    }
    func eject(_ record: AppInstallRecoveryRecord) {
        guard !busy else { return }
        busy = true; stopRequested = false; downloadProgress = nil; error = nil; phase = "正在核对并弹出本应用的遗留镜像…"
        task = Task {
            defer { busy = false; task = nil; loadRecovery() }
            do { try await AppcastUpdateInstaller().ejectRecoveryImage(record); phase = "镜像已弹出，应用文件未修改。" }
            catch { self.error = error.localizedDescription; phase = "未能确认镜像已弹出，请查看恢复记录。" }
        }
    }
    func cancel() {
        stopRequested = true; generation += 1; downloadProgress = nil
        task?.cancel(); phase = "正在停止；等待下载结束及必需的恢复、镜像卸载完成。"
    }
    private func receive(_ value: AppDownloadProgress, generation current: Int) {
        guard generation == current, !stopRequested, busy else { return }
        if let previous = downloadProgress, value.receivedBytes < previous.receivedBytes { return }
        downloadProgress = value
    }
    func reviewRestore(_ record: AppInstallRecoveryRecord) {
        guard !busy else { return }
        busy = true; stopRequested = false; downloadProgress = nil; error = nil; phase = "正在复核备份、当前版本和开发者签名…"
        task = Task {
            defer { busy = false; task = nil; loadRecovery() }
            do {
                let preview = try await AppcastBackupRestorer().preview(recordID: record.id)
                try Task.checkCancellation()
                pendingRestore = preview; phase = "旧版本已复核，等待确认恢复。"
            } catch is CancellationError { phase = "复核已停止，应用未移动。" }
            catch { self.error = error.localizedDescription; phase = "无法自动恢复，请核对记录和文件位置。" }
        }
    }
    func restore(_ preview: AppBackupRestorePreview) {
        guard !busy else { return }
        busy = true; stopRequested = false; downloadProgress = nil; error = nil; pendingRestore = nil; restoredPreservedURL = nil; installedBackup = nil
        phase = "重新核对恢复条件并恢复旧版本…"
        task = Task {
            defer { busy = false; task = nil; loadRecovery() }
            do {
                let outcome = try await AppcastBackupRestorer().restore(preview)
                restoredPreservedURL = outcome.preservedVersionURL
                rows.removeAll { $0.target.application.url.standardizedFileURL == outcome.applicationURL.standardizedFileURL }; selection = nil
                phase = "\(preview.name) 的旧版本已恢复。重新读取可继续检查。"
            } catch is CancellationError { phase = "恢复已在移动前停止。" }
            catch { self.error = error.localizedDescription; phase = "操作已结束，请核对恢复记录中的实际位置。" }
        }
    }
    func read() {
        guard !busy else { return }
        busy = true; stopRequested = false; downloadProgress = nil; error = nil; issues = []
        generation += 1; let current = generation
        task = Task {
            defer { generation += 1; busy = false; task = nil; loadRecovery() }
            do {
                let inventory = try await service.inventory { [weak self] text in Task { @MainActor in guard let self, self.generation == current else { return }; self.phase = "正在读取 · " + text } }
                try Task.checkCancellation()
                rows = inventory.targets.map { ApplicationUpdateRow(target: $0) }; selection = nil
                unsupportedCount = inventory.unsupportedCount; issues = inventory.issues; hasRead = true
                phase = "发现 \(rows.count) 个可识别更新来源；尚未联网检查。"
            } catch is CancellationError { phase = "读取已停止。" }
            catch { self.error = error.localizedDescription; phase = "读取未完成。" }
        }
    }
    func check(selectedOnly: Bool = false) {
        guard !busy else { return }
        let candidates = selectedOnly ? rows.filter { $0.id == selection } : rows
        guard !candidates.isEmpty else { return }
        busy = true; stopRequested = false; downloadProgress = nil; error = nil
        task = Task {
            defer { busy = false; task = nil }
            for (index, row) in candidates.enumerated() {
                if Task.isCancelled { phase = "检查已停止，保留已完成结果。"; return }
                phase = "联网检查 \(index + 1)/\(candidates.count) · \(row.target.application.name)"
                do {
                    let release = try await service.check(row.target)
                    try Task.checkCancellation()
                    if let position = rows.firstIndex(where: { $0.id == row.id }) {
                        rows[position].release = release; rows[position].checked = true
                        rows[position].status = release == nil ? "未发现适用的更新" : "可更新至 \(release!.version)"
                    }
                } catch is CancellationError { phase = "检查已停止，保留已完成结果。"; return }
                catch {
                    if let position = rows.firstIndex(where: { $0.id == row.id }) { rows[position].status = error.localizedDescription; rows[position].checked = true }
                }
            }
            phase = "检查完成 · \(rows.filter { $0.release != nil }.count) 个应用发现适用更新。"
        }
    }
    func install(_ row: ApplicationUpdateRow) {
        guard !busy, let release = row.release else { return }
        busy = true; stopRequested = false; downloadProgress = nil; error = nil; pending = nil; installedBackup = nil
        generation += 1; let current = generation
        task = Task {
            defer { generation += 1; busy = false; task = nil; loadRecovery() }
            do {
                if PackageUpdateHandoff.isPackage(release) {
                    preparedPackage = nil
                    handedOffPackageID = nil
                    packageVersionStatus = nil
                    let package = try await PackageUpdateHandoff().prepare(target: row.target, release: release, downloadProgress: { [weak self] value in Task { @MainActor in self?.receive(value, generation: current) } }) { [weak self] text in Task { @MainActor in guard let self, self.generation == current, !self.stopRequested else { return }; self.phase = text } }
                    preparedPackage = package
                    phase = "安装包已验证，尚未安装。请查看签名信息，再决定是否交给系统安装器。"
                    return
                }
                let outcome = try await AppcastUpdateInstaller().install(target: row.target, release: release, downloadProgress: { [weak self] value in Task { @MainActor in self?.receive(value, generation: current) } }) { [weak self] text in Task { @MainActor in guard let self, self.generation == current, !self.stopRequested else { return }; self.phase = text } }
                installedBackup = outcome.backupURL
                rows.removeAll { $0.id == row.id }; selection = nil
                phase = "\(row.target.application.name) 已更新，旧版本已保留。重新读取可继续检查。"
            } catch is CancellationError { phase = "已停止后续步骤；如已完成替换，以操作记录为准。" }
            catch { self.error = error.localizedDescription; phase = "操作已结束，请核对具体结果和恢复记录。" }
        }
    }
    func verifyPackageVersion() {
        guard !busy, let package = preparedPackage, handedOffPackageID == package.id else { return }
        busy = true
        stopRequested = false
        error = nil
        packageVersionStatus = nil
        phase = "正在复查原位置的应用版本…"
        task = Task {
            defer { busy = false; task = nil }
            do {
                let status = try await PackageUpdateHandoff().installedVersionStatus(package)
                try Task.checkCancellation()
                packageVersionStatus = status
                phase = "版本复查完成。"
            } catch is CancellationError {
                phase = "版本复查已停止。"
            } catch {
                phase = "未能确认安装后的版本。"
                self.error = error.localizedDescription
            }
        }
    }

    func openPreparedPackage() {
        guard !busy, let package = preparedPackage else { return }
        busy = true; stopRequested = false; downloadProgress = nil; error = nil; phase = "重新验证安装包与信息源…"
        task = Task {
            defer { busy = false; task = nil }
            do {
                let url = try await PackageUpdateHandoff().validateForOpening(package)
                try Task.checkCancellation()
                let installer = URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app", isDirectory: true)
                guard Bundle(url: installer)?.bundleIdentifier == "com.apple.installer" else { throw AppUpdateError.unavailable("未找到可确认的系统安装器。") }
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: installer, configuration: NSWorkspace.OpenConfiguration())
                handedOffPackageID = package.id
                packageVersionStatus = nil
                phase = "请在系统安装器完成安装，再点击「复查本机版本」。"
                await ActivityStore.shared.append(ActivityRecord(category: "更新安装包", title: "已打开系统安装器", detail: "\(package.packageURL.path)；未确认安装结果"))
            } catch { self.error = error.localizedDescription; phase = "未能完成交接；没有自行安装或替换应用。" }
        }
    }
}

struct ApplicationUpdatesView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ApplicationUpdatesModel()
    @State private var confirmPackageOpen = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) { Text("应用更新").font(.largeTitle.bold()); Text("检查应用提供的更新来源，复核后下载并安装。").foregroundStyle(.secondary) }
                Spacer()
                if model.busy { ProgressView().controlSize(.small); Button(model.stopRequested ? "正在停止…" : "停止") { model.cancel() }.disabled(model.stopRequested) }
                else { Button(model.hasRead ? "重新读取" : "读取应用") { model.read() }; Button("联网检查") { model.check() }.buttonStyle(.borderedProminent).disabled(model.rows.isEmpty) }
            }
            ScrollView {
              VStack(alignment: .leading, spacing: 16) {
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if let backup = model.installedBackup {
                HStack { Label("旧版本已保留，可在 Finder 中查看。", systemImage: "checkmark.circle.fill").foregroundStyle(.green); Spacer(); Button("显示旧版本") { NSWorkspace.shared.activateFileViewerSelecting([backup]) } }.padding(12).background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            if let preserved = model.restoredPreservedURL {
                HStack { Label("旧版本已恢复，换下的版本已保留。", systemImage: "checkmark.circle.fill").foregroundStyle(.green); Spacer(); Button("显示换下版本") { NSWorkspace.shared.activateFileViewerSelecting([preserved]) } }.padding(12).background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            if let package = model.preparedPackage {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(model.handedOffPackageID == package.id ? "已交给系统安装器" : "\(package.applicationName) 的安装包已验证，尚未安装", systemImage: "shippingbox").fontWeight(.medium)
                        Spacer()
                        Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([package.packageURL]) }
                        Button("打开系统安装器…") { confirmPackageOpen = true }.disabled(model.busy)
                    }
                    if model.handedOffPackageID == package.id {
                        Button("复查本机版本") { model.verifyPackageVersion() }.disabled(model.busy)
                        if let status = model.packageVersionStatus {
                            Text(status).font(.callout).textSelection(.enabled)
                        }
                    }
                    DisclosureGroup("系统签名信息") { ScrollView { Text(package.signingReport).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110) }
                }.padding(12).background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.rows.isEmpty {
                ContentUnavailableView(model.hasRead ? "未发现可识别的更新来源" : "按需检查本机应用", systemImage: "arrow.down.app", description: Text("支持 Sparkle、Electron 通用/公开 GitHub、VS Code 官方来源和 App Store 公开目录。读取应用列表本身不联网，安装前需复核。"))
                    .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                Table(model.rows, selection: $model.selection) {
                    TableColumn("应用") { row in HStack(spacing: 8) { Image(nsImage: NSWorkspace.shared.icon(forFile: row.target.application.url.path)).resizable().frame(width: 28, height: 28); Text(row.target.application.name).fontWeight(.medium) } }.width(min: 140, ideal: 220)
                    TableColumn("当前版本") { Text($0.target.application.version).monospacedDigit() }.width(110)
                    TableColumn("来源") { Text($0.target.source.label).font(.caption) }.width(145)
                    TableColumn("检查结果") { Text($0.status).font(.callout).lineLimit(2).help($0.status) }.width(min: 200, ideal: 350)
                }.disabled(model.busy).frame(height: 260)
                if let row = model.selected { detail(row) }
            }
            if model.hasRead { Text("另有 \(model.unsupportedCount) 个应用未声明支持的来源。它们仍需使用自身、Homebrew 或 App Store 更新；本页不能证明这些应用均为最新版。").font(.caption).foregroundStyle(.secondary) }
            if !model.issues.isEmpty { DisclosureGroup("\(model.issues.count) 条读取提示") { ScrollView { Text(model.issues.joined(separator: "\n")).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 80) } }
            if !model.recovery.isEmpty { recoveryHistory }
            if let transfer = model.downloadProgress, model.busy, model.phase.hasPrefix("下载") {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: transfer.fractionCompleted)
                    Text(transfer.detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            }
              }.frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack { Text(model.phase).font(.caption).foregroundStyle(.secondary).lineLimit(2); Spacer(); Button("关闭") { dismiss() }.disabled(model.busy).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(minWidth: 940, minHeight: 620, idealHeight: 700)
            .sheet(item: $model.pending) { row in confirmation(row) }
            .sheet(item: $model.pendingRestore) { preview in restoreConfirmation(preview) }
            .confirmationDialog("将安装包交给系统安装器？", isPresented: $confirmPackageOpen, titleVisibility: .visible) {
                Button("复核并打开系统安装器") { model.openPreparedPackage() }
                Button("取消", role: .cancel) { }
            } message: { Text("系统安装器会解析厂商安装包，可能运行检查/安装逻辑并请求管理员授权。请在其中核对安装位置和发布者；此流程不提供通用回滚，也不自动确认安装完成。") }
            .interactiveDismissDisabled(model.busy)
            .task { model.loadRecovery() }
            .onDisappear { if model.busy { model.cancel() } }
    }
    private var recoveryHistory: some View {
        DisclosureGroup("更新记录与旧版位置（\(model.recovery.count)）") {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("可先复核备份再恢复旧版；换下版本会保留。若文件身份或签名无法确认，请在 Finder 中核对；记录本身不能证明文件仍在原处。").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.recovery.prefix(30)) { record in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.applicationURL.lastPathComponent).fontWeight(.medium)
                                Text(recoveryLabel(record.phase)).font(.caption).foregroundStyle(["needsReview", "imageNeedsEject", "restoreNeedsReview"].contains(record.phase) ? Color.orange : Color.secondary)
                                Text(record.backupURL.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                Text(record.date, style: .date).font(.caption2).foregroundStyle(.secondary)
                                if !record.detail.isEmpty { Text(record.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
                            Spacer()
                            Button("旧版位置") { NSWorkspace.shared.activateFileViewerSelecting([record.backupURL]) }.disabled(!FileManager.default.fileExists(atPath: record.backupURL.path))
                            if ["prepared", "originalBackedUp", "installed", "needsReview", "restorePrepared", "restoreCurrentPreserved", "restoreNeedsReview"].contains(record.phase) {
                                Button("复核恢复…") { model.reviewRestore(record) }.disabled(model.busy)
                            }
                            if let preserved = record.displacedURL, FileManager.default.fileExists(atPath: preserved.path) { Button("换下版本") { NSWorkspace.shared.activateFileViewerSelecting([preserved]) } }
                            if ["imageNeedsEject", "imageMounting"].contains(record.phase) { Button("核对并弹出镜像") { model.eject(record) }.disabled(model.busy) }
                            if FileManager.default.fileExists(atPath: record.stagedURL.path) { Button("暂存位置") { NSWorkspace.shared.activateFileViewerSelecting([record.stagedURL]) } }
                            Button("原目录") { NSWorkspace.shared.activateFileViewerSelecting([record.applicationURL.deletingLastPathComponent()]) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.frame(maxHeight: 180)
        }
    }
    private func recoveryLabel(_ phase: String) -> String {
        switch phase {
        case "prepared": return "已准备替换，实际状态需核对"
        case "originalBackedUp": return "已记录旧版备份，实际状态需核对"
        case "installed": return "已记录安装完成"
        case "restored": return "已记录原版本恢复"
        case "restorePrepared": return "已准备恢复旧版，实际状态需核对"
        case "restoreCurrentPreserved": return "换下版本已保留，旧版恢复尚需核对"
        case "restoreNeedsReview": return "旧版恢复需要核对"
        case "unchanged": return "未替换应用"
        case "imageMounting": return "已准备打开镜像，实际挂载状态需核对"
        case "imageDetached": return "已记录镜像卸载，应用替换状态以其他记录为准"
        case "imageNeedsEject": return "镜像需要检查并弹出"
        default: return "需要人工核对"
        }
    }
    private func detail(_ row: ApplicationUpdateRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.target.application.name).font(.headline)
            Text("\(row.target.source.label) · \(row.target.feedURL.host ?? "")").font(.caption).foregroundStyle(.secondary)
            if row.target.requiresSignedFeed { Label("需要验证信息源签名，安装前将再次复核", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary) }
            if let release = row.release {
                let isPackage = PackageUpdateHandoff.isPackage(release)
                let issue = isPackage ? PackageUpdateHandoff.eligibilityIssue(target: row.target, release: release) : AppcastService.automaticInstallIssue(target: row.target, release: release)
                Text("\(row.target.application.version) → \(release.version)").font(.title3.weight(.medium))
                if let issue { Text(issue).font(.callout).foregroundStyle(.orange) }
                HStack {
                    Button("打开应用自身更新") { NSWorkspace.shared.open(row.target.application.url) }
                    if let information = release.informationURL, AppUpdateURLPolicy.allows(information) { Link(information.host == "apps.apple.com" ? "在 App Store 中查看" : "发布页面", destination: information) }
                    Spacer()
                    Button(isPackage ? "准备安装包…" : "复核并安装…") { model.pending = row }.buttonStyle(.borderedProminent).disabled(model.busy || issue != nil)
                }
            } else {
                HStack {
                    Text(row.status).foregroundStyle(.secondary); Spacer()
                    Button("打开应用自身更新") { NSWorkspace.shared.open(row.target.application.url) }.disabled(model.busy)
                    Button("检查此应用") { model.check(selectedOnly: true) }.disabled(model.busy)
                }
            }
        }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
    private func confirmation(_ row: ApplicationUpdateRow) -> some View {
        let isPackage = row.release.map(PackageUpdateHandoff.isPackage) ?? false
        return VStack(alignment: .leading, spacing: 18) {
            Text(isPackage ? "准备 \(row.target.application.name) 的更新安装包？" : "更新 \(row.target.application.name)？").font(.title2.bold())
            Text(isPackage ? "将下载并验证安装包，尚不安装或替换当前应用。请先保存工作并退出该应用。验证后可查看系统签名信息，再决定是否打开系统安装器。" : "将下载并验证更新包，然后替换当前应用。请先保存工作并退出该应用。旧版本会保留在原应用所在目录，操作结束后可在 Finder 中查看。")
            if let release = row.release {
                LabeledContent("版本", value: "\(row.target.application.version) → \(release.version)")
                LabeledContent("下载", value: release.length.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知")
                LabeledContent("来源", value: release.downloadURL.host ?? "")
                LabeledContent("校验", value: isPackage ? "应用更新公钥、系统包签名与安装策略" : row.target.source == .sparkle ? "更新包签名与开发者签名" : release.sha256 != nil ? "SHA-256、commit 与同一开发者代码签名" : "SHA-512 与同一开发者代码签名")
            }
            Text(isPackage ? "厂商安装包可能包含脚本和额外组件；安装范围及结果需在系统安装器中复核，不套用普通应用替换的旧版备份承诺。" : row.target.source == .sparkle ? "支持可验证的 ZIP 或 DMG 应用包。安装后不会自动启动应用。" : row.release?.sha256 != nil ? "将核对完整 ZIP 的 SHA-256、commit 和同一开发者代码签名。安装后不会自动启动应用。" : "将核对完整 ZIP 或 DMG 的 SHA-512，再严格验证应用与原版本属于同一开发者。安装后不会自动启动应用。").font(.caption).foregroundStyle(.secondary)
            if case .electron(let configuration) = row.target.source, !configuration.manifestPublicKeys.isEmpty {
                Text("此应用内置信任公钥 \(configuration.manifestPublicKeys.count) 个；下载前及替换前会重新验证所选更新，验签失败不会降级。").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Button("返回") { model.pending = nil }.keyboardShortcut(.cancelAction); Spacer(); Button(isPackage ? "下载并验证" : "下载并安装") { model.install(row) }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 580)
    }
    private func restoreConfirmation(_ preview: AppBackupRestorePreview) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("恢复 \(preview.name) 的旧版本？").font(.title2.bold())
            Text("请先保存工作并退出该应用。恢复会重新核对签名、文件身份及运行状态；原位置存在其他内容时将停止。")
            LabeledContent("恢复到版本", value: preview.backupVersion)
            LabeledContent("当前版本", value: preview.currentVersion ?? "原位置为空")
            if preview.resumesInterruptedRestore { Label("将继续此前中断的恢复。", systemImage: "arrow.clockwise").font(.callout) }
            Text(preview.applicationURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if preview.preservedVersionURL != nil { Text("换下版本会保留在同一目录，恢复后可在 Finder 中查看。").font(.callout) }
            Text("恢复仅更换应用文件，不回退个人数据。旧版可能无法读取新版本生成的数据；恢复后不会自动启动。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("返回") { model.pendingRestore = nil }.keyboardShortcut(.cancelAction); Spacer(); Button("恢复旧版本") { model.restore(preview) }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 580)
    }
}
