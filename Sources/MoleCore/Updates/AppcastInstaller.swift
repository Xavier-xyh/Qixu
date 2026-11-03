import Foundation
import AppKit
import CryptoKit
import Security
import Darwin
import zlib

public struct AppInstallOutcome: Sendable {
    public let applicationURL: URL
    public let backupURL: URL
    public let date: Date
    public init(applicationURL: URL, backupURL: URL, date: Date) {
        self.applicationURL = applicationURL; self.backupURL = backupURL; self.date = date
    }
}

actor AppcastInstallGate {
    static let shared = AppcastInstallGate()
    private var busy = false
    func acquire() throws { guard !busy else { throw AppUpdateError.unavailable("另一个应用更新正在安装，请等待完成。") }; busy = true }
    func release() { busy = false }
}

/// Sparkle Ed25519 and declared Electron SHA-512 ZIP/DMG installation.
/// All replacements require the original developer's strict code signature.
/// No scripts, app launch, elevation, delta update or signed-feed bypass.
public struct AppcastUpdateInstaller: Sendable {
    private let download: AppArchiveTransfer
    public init() {
        download = { try await AppcastArchiveDownload().download($0, to: $1, length: $2, progress: $3) }
    }
    // Transport injection for integration validation. Every archive still passes
    // the production length, digest, identity and developer-signature checks.
    init(download: @escaping @Sendable (URL, URL, Int64) async throws -> Void) {
        self.download = { url, file, length, _ in try await download(url, file, length) }
    }
    public func install(target: AppUpdateTarget, release: AppcastRelease, downloadProgress: @escaping @Sendable (AppDownloadProgress) -> Void = { _ in }, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> AppInstallOutcome {
        try await AppcastInstallGate.shared.acquire()
        do {
            let outcome = try await installLocked(target: target, release: release, downloadProgress: downloadProgress, progress: progress)
            await ActivityStore.shared.append(ActivityRecord(category: "应用更新", title: "已更新 \(target.application.name)", detail: "版本 \(release.build)；旧版备份：\(outcome.backupURL.path)"))
            await AppcastInstallGate.shared.release()
            return outcome
        } catch {
            await ActivityStore.shared.append(ActivityRecord(category: "应用更新", title: "更新 \(target.application.name) 未完成", detail: error.localizedDescription, succeeded: false))
            await AppcastInstallGate.shared.release()
            throw error
        }
    }
    private func installLocked(target: AppUpdateTarget, release: AppcastRelease, downloadProgress: @escaping @Sendable (AppDownloadProgress) -> Void, progress: @escaping @Sendable (String) -> Void) async throws -> AppInstallOutcome {
        guard AppcastService.automaticInstallIssue(target: target, release: release) == nil,
              AppUpdateURLPolicy.allows(target.feedURL), AppUpdateURLPolicy.allows(release.downloadURL),
              ["zip", "dmg"].contains(release.downloadURL.pathExtension.lowercased()),
              release.installationType == nil || release.installationType == "application",
              let length = release.length, (1...1_073_741_824).contains(length) else {
            throw AppUpdateError.invalid("更新格式、完整性信息、版本或长度不符合安装要求。")
        }
        if target.source == .sparkle, AppUpdateVersion.compare(release.build, target.application.build) != .orderedDescending { throw AppUpdateError.invalid("Sparkle 更新的 build 必须更高。") }
        try AppcastInstallValidation.validateSystem(minimum: release.minimumSystemVersion, maximum: release.maximumSystemVersion)
        progress("复核当前应用身份与签名…")
        let originalTeam = try await validateOriginal(target)
        if target.requiresMetadataAuthentication { progress("验证签名信息源与所选版本…"); try await AppcastService().revalidateSignedRelease(release, target: target) }
        let working = try privateDirectory(parent: FileManager.default.temporaryDirectory)
        var preserveWorking = false
        defer { if !preserveWorking { try? FileManager.default.removeItem(at: working) } }
        let format = release.downloadURL.pathExtension.lowercased()
        let archive = working.appendingPathComponent("update." + format)
        progress("下载更新包…")
        try await download(release.downloadURL, archive, length, downloadProgress)
        try Task.checkCancellation()
        progress("验证更新包完整性信息…")
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard data.count == length else { throw AppUpdateError.invalid("更新包长度已改变。") }
        try AppcastInstallValidation.verifyPackage(data, target: target, release: release)
        let appURL = target.application.url
        let parent = appURL.deletingLastPathComponent()
        let stage = try privateDirectory(parent: parent)
        var preserveStage = false
        defer { if !preserveStage { try? FileManager.default.removeItem(at: stage) } }
        let stagedApp = stage.appendingPathComponent(appURL.lastPathComponent)
        let backup = parent.appendingPathComponent(".\(appURL.deletingPathExtension().lastPathComponent).MoleRebuild-backup-\(UUID().uuidString).app")
        var imageRecovery: AppInstallRecoveryRecord?
        if format == "zip" {
            let entries = try AppcastArchivePolicy.inspect(data)
            let extracted = try privateDirectory(parent: working)
            progress("安全展开更新包…")
            let result = try await ToolCommandExecutor().run(ToolCommand("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path]), timeout: 300)
            guard result.succeeded else { throw AppUpdateError.failed("更新包展开失败：\(result.output.prefix(2000))") }
            try Task.checkCancellation()
            try AppcastArchivePolicy.validateExtracted(extracted, entries: entries)
            let roots = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            let apps = roots.filter { $0.pathExtension.lowercased() == "app" }
            guard apps.count == 1, roots.allSatisfy({ $0 == apps[0] || $0.lastPathComponent == "__MACOSX" || $0.lastPathComponent == ".DS_Store" }) else {
                throw AppUpdateError.unavailable("更新包必须只包含一个根目录应用；其他格式请使用应用自带更新器。")
            }
            progress("复制并验证新应用身份、签名与兼容性…")
            // Verify the actual bytes to be committed, inside our same-volume
            // stage. Strict source-declaration path checks must not traverse
            // the operating system's /var alias used by temporary extraction.
            try FileManager.default.copyItem(at: apps[0], to: stagedApp)
            try validateReplacement(stagedApp, target: target, release: release, team: originalTeam)
        } else {
            let mount = try privateDirectory(parent: working)
            var record = AppInstallRecoveryRecord(applicationURL: appURL, backupURL: backup, stagedURL: stagedApp,
                originalIdentity: target.application.identity, replacementIdentity: nil, build: release.build)
            record.originalBundleID = target.application.bundleID
            record.originalTeamID = originalTeam
            record.originalBuild = target.application.build
            record.mountURL = mount; record.diskImageURL = archive
            record.workingURL = working; record.workingIdentity = try FileIdentity.capture(working)
            record.archiveIdentity = try FileIdentity.capture(archive)
            record.phase = "imageMounting"; record.detail = "已验证镜像完整性，准备只读挂载。原应用尚未移动。"
            try AppcastRecoveryJournal.write(record)
            var preparationError: Error?
            do {
                progress("只读挂载已验证的镜像…")
                try await AppcastDiskImage.attach(image: archive, mount: mount)
                try Task.checkCancellation()
                let application = try AppcastDiskImage.application(in: mount, bundleID: target.application.bundleID)
                try AppcastDiskImage.validateApplicationTree(application)
                try validateReplacement(application, target: target, release: release, team: originalTeam)
                progress("复制并复核应用…")
                try FileManager.default.copyItem(at: application, to: stagedApp)
                try AppcastDiskImage.validateApplicationTree(stagedApp)
                try validateReplacement(stagedApp, target: target, release: release, team: originalTeam)
                try Task.checkCancellation()
            } catch { preparationError = error }
            progress("卸载只读更新镜像…")
            do { try await AppcastDiskImage.cleanup(image: archive, mount: mount) }
            catch {
                // Never recursively delete a directory while it may still be a mount.
                preserveWorking = true
                let cleanupError = AppcastDiskImageCleanupError(mountURL: mount, imageURL: archive, detail: error.localizedDescription)
                record.phase = "imageNeedsEject"; record.detail = cleanupError.localizedDescription
                record.replacementIdentity = try? FileIdentity.capture(stagedApp)
                do { try AppcastRecoveryJournal.write(record) }
                catch { throw AppUpdateError.failed("镜像无法确认卸载，恢复状态也未能更新。请保留：\(mount.path)；镜像：\(archive.path)。初始恢复记录仍包含这些路径。") }
                throw cleanupError
            }
            record.phase = "imageDetached"; record.detail = "镜像已卸载；原应用尚未移动。"
            record.replacementIdentity = try? FileIdentity.capture(stagedApp)
            try AppcastRecoveryJournal.write(record)
            if let preparationError { throw preparationError }
            imageRecovery = record
        }
        try Task.checkCancellation()
        progress("最终复核并保留旧版…")
        try await AppcastService().revalidateSignedRelease(release, target: target)
        guard try await validateOriginal(target) == originalTeam else { throw AppUpdateError.invalid("原应用签名身份已改变。") }
        try Task.checkCancellation()
        try PathSafety.validate(appURL, allowedRoot: target.application.allowedRoot, expectedIdentity: target.application.identity)
        let stagedIdentity = try FileIdentity.capture(stagedApp)
        try PathSafety.rejectSymbolicLinks(in: parent)
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw AppUpdateError.unavailable("没有替换此应用的权限；请使用应用自带更新器。") }
        // The two renames are deliberately NOT an atomic transaction. A durable
        // manifest must exist first so a crash between them leaves recovery paths.
        // Commit has no suspension or cancellation points: once the old app moves,
        // finish or restore before reporting cancellation. Never overwrite a collision.
        guard let replacementBuild = try AppcastInstallValidation.readInfo(stagedApp)["CFBundleVersion"] as? String, !replacementBuild.isEmpty else { throw AppUpdateError.invalid("新应用缺少 build。") }
        var recovery = imageRecovery ?? AppInstallRecoveryRecord(applicationURL: appURL, backupURL: backup, stagedURL: stagedApp,
            originalIdentity: target.application.identity, replacementIdentity: stagedIdentity, build: replacementBuild)
        recovery.replacementIdentity = stagedIdentity
        recovery.originalBundleID = target.application.bundleID
        recovery.originalTeamID = originalTeam
        recovery.originalBuild = target.application.build
        recovery.phase = "prepared"; recovery.detail = "新版本已验证，暂存准备已完成，尚未确认替换完成。"
        try AppcastRecoveryJournal.write(recovery) // Failure here MUST precede any application move.
        do {
            try Task.checkCancellation()
            try PathSafety.validate(appURL, allowedRoot: target.application.allowedRoot, expectedIdentity: target.application.identity)
        } catch {
            recovery.phase = "unchanged"; recovery.detail = "替换前已取消或应用身份改变，未移动应用。"; try? AppcastRecoveryJournal.write(recovery)
            throw error
        }
        guard renamex_np(appURL.path, backup.path, UInt32(RENAME_EXCL)) == 0 else {
            recovery.phase = "unchanged"; recovery.detail = "无法移动旧版，原应用未替换。"; try? AppcastRecoveryJournal.write(recovery)
            throw AppUpdateError.failed("无法保留旧版，未替换应用：\(String(cString: strerror(errno)))")
        }
        do {
            guard try FileIdentity.capture(backup) == target.application.identity else { throw AppUpdateError.invalid("移动后的旧版身份不符。") }
            recovery.phase = "originalBackedUp"; recovery.detail = "旧版已保留，正在放入新版本。"
            try AppcastRecoveryJournal.write(recovery)
        } catch {
            let restored = renamex_np(backup.path, appURL.path, UInt32(RENAME_EXCL)) == 0
            recovery.phase = restored ? "restored" : "needsReview"
            recovery.detail = "安装记录或旧版复核失败；" + (restored ? "旧版已恢复。" : "旧版保留在备份路径，请人工检查。")
            try? AppcastRecoveryJournal.write(recovery)
            throw AppUpdateError.failed("\(recovery.detail)备份路径：\(backup.path)。\(error.localizedDescription)")
        }
        if renamex_np(stagedApp.path, appURL.path, UInt32(RENAME_EXCL)) != 0 {
            let installError = String(cString: strerror(errno))
            if renamex_np(backup.path, appURL.path, UInt32(RENAME_EXCL)) == 0 {
                recovery.phase = "restored"; recovery.detail = "安装失败，旧版已恢复。"; try? AppcastRecoveryJournal.write(recovery)
                throw AppUpdateError.failed("安装失败，原应用已恢复：\(installError)")
            }
            recovery.phase = "needsReview"; recovery.detail = "安装失败，旧版备份未能恢复。"; try? AppcastRecoveryJournal.write(recovery)
            throw AppUpdateError.failed("安装失败，原位置被占用或无法恢复。旧版完整保留在：\(backup.path)。错误：\(installError)")
        }
        do {
            guard try FileIdentity.capture(appURL) == stagedIdentity else { throw AppUpdateError.invalid("替换后的文件身份异常。") }
            try validateReplacement(appURL, target: target, release: release, team: originalTeam)
        } catch {
            // Keep both versions on failure. Only move the exact installed object;
            // never displace another app that appeared at the destination.
            if (try? FileIdentity.capture(appURL)) == stagedIdentity,
               renamex_np(appURL.path, stagedApp.path, UInt32(RENAME_EXCL)) == 0 {
                preserveStage = true
                if renamex_np(backup.path, appURL.path, UInt32(RENAME_EXCL)) == 0 {
                    recovery.phase = "restored"; recovery.detail = "新版本校验失败，旧版已恢复；新版本保留在暂存路径。"; try? AppcastRecoveryJournal.write(recovery)
                    throw AppUpdateError.failed("安装校验失败，旧版已恢复。待检查的新版本保留在：\(stagedApp.path)。\(error.localizedDescription)")
                }
            }
            recovery.phase = "needsReview"; recovery.detail = "安装后校验失败，请检查原位置、备份与暂存目录。"; try? AppcastRecoveryJournal.write(recovery)
            throw AppUpdateError.failed("安装校验失败，请手动检查应用。旧版备份保留在：\(backup.path)。暂存路径：\(stagedApp.path)。\(error.localizedDescription)")
        }
        recovery.phase = "installed"; recovery.detail = "新版本已验证，旧版保留在备份路径。"
        do { try AppcastRecoveryJournal.write(recovery) }
        catch { throw AppUpdateError.failed("新版本已安装，旧版已保留，但更新记录状态写入失败。请检查：\(appURL.path)；备份：\(backup.path)。") }
        progress("更新完成，旧版已保留。")
        return AppInstallOutcome(applicationURL: appURL, backupURL: backup, date: Date())
    }
    public func recoveryRecords() throws -> [AppInstallRecoveryRecord] { try AppcastRecoveryJournal.records() }
    public func ejectRecoveryImage(_ record: AppInstallRecoveryRecord) async throws {
        try Task.checkCancellation()
        try await AppcastInstallGate.shared.acquire()
        do {
            try await ejectRecoveryImageLocked(id: record.id)
            await ActivityStore.shared.append(ActivityRecord(category: "应用更新", title: "已弹出遗留更新镜像", detail: record.id.uuidString))
            await AppcastInstallGate.shared.release()
        } catch {
            await ActivityStore.shared.append(ActivityRecord(category: "应用更新", title: "遗留更新镜像弹出未完成", detail: error.localizedDescription, succeeded: false))
            await AppcastInstallGate.shared.release()
            throw error
        }
    }
    private func ejectRecoveryImageLocked(id: UUID) async throws {
        // Use only the fresh record from our own journal, never paths supplied by UI.
        guard var stored = try recoveryRecords().first(where: { $0.id == id }), ["imageNeedsEject", "imageMounting"].contains(stored.phase),
              let image = stored.diskImageURL, let mount = stored.mountURL,
              let working = stored.workingURL, let workingIdentity = stored.workingIdentity,
              let archiveIdentity = stored.archiveIdentity,
              image.deletingLastPathComponent().resolvingSymlinksInPath().path == working.resolvingSymlinksInPath().path,
              mount.deletingLastPathComponent().resolvingSymlinksInPath().path == working.resolvingSymlinksInPath().path,
              image.lastPathComponent == "update.dmg",
              working.lastPathComponent.hasPrefix(".MoleRebuild-update-"), mount.lastPathComponent.hasPrefix(".MoleRebuild-update-"),
              working.deletingLastPathComponent().resolvingSymlinksInPath().path == FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path,
              try FileIdentity.capture(image) == archiveIdentity,
              let currentWorking = try? FileIdentity.capture(working), !currentWorking.isSymbolicLink,
              currentWorking.device == workingIdentity.device, currentWorking.inode == workingIdentity.inode else {
            throw AppUpdateError.invalid("恢复记录或私有镜像身份已改变，无法自动弹出；请在 Finder 中检查。")
        }
        let info = try await Task.detached(priority: .utility) {
            try await ToolCommandExecutor().run(ToolCommand("/usr/bin/hdiutil", ["info", "-plist"]), timeout: 30)
        }.value
        guard info.succeeded else { throw AppUpdateError.failed("无法确认遗留镜像状态。") }
        let devices = try AppcastDiskImage.validateRecoveryBinding(info: Data(info.output.utf8), image: image, mount: mount)
        guard !devices.isEmpty || !AppcastDiskImage.isMountPoint(mount) else { throw AppUpdateError.invalid("恢复挂载点正由其他镜像占用，未执行弹出。") }
        try await AppcastDiskImage.cleanup(image: image, mount: mount)
        stored.phase = "imageDetached"; stored.detail = "遗留更新镜像已弹出；没有修改应用。"
        // Delete only an unchanged private directory whose two direct children are
        // exactly this recorded image and mount directory. Otherwise detach only.
        let children = try? FileManager.default.contentsOfDirectory(at: working, includingPropertiesForKeys: nil)
        if (try? FileIdentity.capture(working)) == workingIdentity,
           let children, Set(children.map(\.lastPathComponent)) == Set([image.lastPathComponent, mount.lastPathComponent]),
           !AppcastDiskImage.isMountPoint(mount), (try? FileIdentity.capture(image)) == archiveIdentity {
            do { try FileManager.default.removeItem(at: working); stored.detail += "已清理本次私有暂存目录。" }
            catch { stored.detail += "暂存目录清理失败，已保留：\(working.path)。" }
        } else { stored.detail += "暂存目录身份或内容有变化，保留供检查：\(working.path)。" }
        try AppcastRecoveryJournal.write(stored)
    }
    private func privateDirectory(parent: URL) throws -> URL {
        let path = parent.appendingPathComponent(".MoleRebuild-update-XXXXXX").path
        var template = Array(path.utf8CString)
        guard let pointer = mkdtemp(&template) else { throw AppUpdateError.failed("无法创建私有更新目录；请检查可用空间和目录权限。") }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }
    func validateOriginal(_ target: AppUpdateTarget) async throws -> String {
        let app = target.application
        guard !app.isProtected, !app.bundleID.isEmpty, !app.bundleID.hasPrefix("com.apple."),
              app.bundleID != Bundle.main.bundleIdentifier, app.bundleID != RebuildPaths.bundleIdentifier,
              app.url.pathExtension.lowercased() == "app", !PathSafety.contains(Bundle.main.bundleURL, in: app.url, includeRoot: true) else {
            throw AppUpdateError.invalid("受保护应用或当前应用不能在此替换。")
        }
        try PathSafety.validate(app.url, allowedRoot: app.allowedRoot, expectedIdentity: app.identity)
        let info = try AppcastInstallValidation.readInfo(app.url)
        guard info["CFBundleIdentifier"] as? String == app.bundleID, info["CFBundleVersion"] as? String == app.build,
              info["CFBundleShortVersionString"] as? String == app.version else {
            throw AppUpdateError.invalid("当前应用的标识或版本已改变，请重新扫描。")
        }
        switch target.source {
        case .appStore: throw AppUpdateError.unavailable("App Store 应用须由商店完成安装。")
        case .vscode(let configuration):
            guard try CodeUpdateConfiguration.read(application: app.url, bundleID: app.bundleID) == configuration else { throw AppUpdateError.invalid("VS Code 产品声明已改变。") }
        case .sparkle:
            guard info["SUFeedURL"] as? String == target.feedURL.absoluteString, info["SUPublicEDKey"] as? String == target.publicKey,
                  AppUpdateMetadata.requiresSignedFeed(info) == target.requiresSignedFeed else { throw AppUpdateError.invalid("当前应用的更新密钥、来源或签名策略已改变。") }
        case .electron(let configuration):
            guard info["SUFeedURL"] == nil, try ElectronUpdateConfiguration.read(application: app.url) == configuration else { throw AppUpdateError.invalid("Electron 来源声明自读取后已改变，请重新读取。") }
        }
        let team = try AppcastInstallValidation.strictTeam(app.url)
        guard !team.isEmpty, team == app.teamID else { throw AppUpdateError.invalid("当前应用开发者身份已改变，或没有可验证的开发者签名。") }
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == app.bundleID || $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL }
        }
        guard !running else { throw AppUpdateError.unavailable("请先退出 \(app.name)，再安装更新。") }
        try PathSafety.validate(app.url, allowedRoot: app.allowedRoot, expectedIdentity: app.identity)
        return team
    }
    private func validateReplacement(_ url: URL, target: AppUpdateTarget, release: AppcastRelease, team: String) throws {
        let identity = try FileIdentity.capture(url)
        guard identity.fileType == UInt32(S_IFDIR), !identity.isSymbolicLink else { throw AppUpdateError.invalid("新应用不是普通应用目录。") }
        let info = try AppcastInstallValidation.readInfo(url)
        guard info["CFBundlePackageType"] as? String == "APPL",
              info["CFBundleIdentifier"] as? String == target.application.bundleID,
              AppcastInstallValidation.matchesRelease(info, target: target, release: release),
              try AppcastInstallValidation.strictTeam(url) == team else { throw AppUpdateError.invalid("新应用版本、标识或开发者签名不匹配。") }
        if case .vscode = target.source {
            guard let configuration = try CodeUpdateConfiguration.read(application: url, bundleID: target.application.bundleID), configuration.commit == release.artifactID else { throw AppUpdateError.invalid("VS Code 安装包 commit 与更新响应不一致。") }
        }
        try AppcastInstallValidation.validateSystem(minimum: info["LSMinimumSystemVersion"] as? String, maximum: nil)
        if let architectures = info["LSMinimumSystemVersionByArchitecture"] as? [String: String], let minimum = architectures[AppcastInstallValidation.architecture] {
            try AppcastInstallValidation.validateSystem(minimum: minimum, maximum: nil)
        }
        // The executable's Mach-O architecture list is checked without loading code.
        guard let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              !executable.contains("/"), executable != ".", executable != ".." else { throw AppUpdateError.invalid("新应用可执行文件声明无效。") }
        let executableURL = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        let resolved = executableURL.resolvingSymlinksInPath()
        guard PathSafety.contains(resolved, in: url) else { throw AppUpdateError.invalid("新应用可执行文件越过应用边界。") }
        try AppcastInstallValidation.validateMachO(Data(contentsOf: resolved, options: .mappedIfSafe))
    }
}

enum AppcastInstallValidation {
    static func matchesRelease(_ info: [String: Any], target: AppUpdateTarget, release: AppcastRelease) -> Bool {
        switch target.source {
        case .appStore: return false
        case .sparkle: return info["CFBundleVersion"] as? String == release.build && AppUpdateVersion.compare(release.build, target.application.build) == .orderedDescending
        case .electron, .vscode:
            return info["CFBundleShortVersionString"] as? String == release.version &&
                !(info["CFBundleVersion"] as? String ?? "").isEmpty &&
                AppUpdateVersion.compare(release.version, target.application.version) == .orderedDescending
        }
    }
    static func verifyPackage(_ data: Data, target: AppUpdateTarget, release: AppcastRelease) throws {
        switch target.source {
        case .appStore: throw AppUpdateError.unavailable("App Store 应用不能走普通包安装流程。")
        case .vscode:
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard let expected = release.sha256, validHex(expected, length: 64), actual == expected.lowercased() else { throw AppUpdateError.invalid("VS Code SHA-256 校验失败，未展开或安装。") }
        case .sparkle: try verifyArchive(data, publicKey: target.publicKey ?? "", signature: release.signature ?? "")
        case .electron:
            guard let expected = Data(base64Encoded: release.sha512 ?? ""), expected.count == 64,
                  Data(SHA512.hash(data: data)) == expected else { throw AppUpdateError.invalid("Electron 更新包 SHA-512 不匹配，未展开或安装。") }
        }
    }
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    static func verifyArchive(_ data: Data, publicKey: String, signature: String) throws {
        guard let key = Data(base64Encoded: publicKey), key.count == 32,
              let signature = Data(base64Encoded: signature), signature.count == 64,
              let signingKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              signingKey.isValidSignature(signature, for: data) else { throw AppUpdateError.invalid("更新包 Ed25519 签名无效，未展开或安装。") }
    }
    static func readInfo(_ application: URL) throws -> [String: Any] {
        let file = application.appendingPathComponent("Contents/Info.plist")
        let identity = try FileIdentity.capture(file)
        guard identity.fileType == UInt32(S_IFREG), identity.size > 0, identity.size <= 4 * 1024 * 1024,
              let result = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] else { throw AppUpdateError.invalid("应用信息文件无效。") }
        return result
    }
    static func strictTeam(_ url: URL) throws -> String {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic" as CFString, SecCSFlags(), &requirement) == errSecSuccess, let requirement else { throw AppUpdateError.invalid("无法读取应用代码签名。") }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw AppUpdateError.invalid("应用代码签名严格验证失败；请使用厂商安装方式。") }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dict = information as? [String: Any], let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { throw AppUpdateError.invalid("应用没有可验证的 Team ID。") }
        return team
    }
    static func validateSystem(minimum: String?, maximum: String?) throws {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        if let minimum { guard let comparison = AppUpdateVersion.compare(current, minimum), comparison != .orderedAscending else { throw AppUpdateError.unavailable("此更新要求更高版本的 macOS。") } }
        if let maximum { guard let comparison = AppUpdateVersion.compare(current, maximum), comparison != .orderedDescending else { throw AppUpdateError.unavailable("此更新不支持当前 macOS 版本。") } }
    }
    static func validateMachO(_ data: Data) throws {
        let expected: UInt32 = architecture == "arm64" ? 0x0100000c : 0x01000007
        func word(_ offset: Int, big: Bool) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            let bytes = (0..<4).map { UInt32(data[offset + $0]) }
            return big ? (bytes[0] << 24 | bytes[1] << 16 | bytes[2] << 8 | bytes[3]) : (bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0])
        }
        if word(0, big: false) == 0xfeedfacf, word(4, big: false) == expected { return }
        if let magic = word(0, big: true), magic == 0xcafebabe || magic == 0xcafebabf,
           let count = word(4, big: true), count > 0, count <= 32 {
            let stride = magic == 0xcafebabf ? 32 : 20
            for index in 0..<Int(count) where word(8 + stride * index, big: true) == expected { return }
        }
        throw AppUpdateError.unavailable("新应用不包含当前机器所需的可执行架构。")
    }
}

struct AppcastZIPEntry: Sendable {
    let path: String
    let isDirectory: Bool
    let linkTarget: String?
    let uncompressedSize: Int
}

/// Parse central and local headers before the system extractor sees the archive.
/// ZIP64, encryption, unknown compression, special files, path aliases and entry
/// descendants through a symbolic link are rejected rather than guessed at.
enum AppcastArchivePolicy {
    static let maximumExpandedBytes = 4 * 1024 * 1024 * 1024
    static func validatePath(_ path: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw AppUpdateError.invalid("ZIP 包含不安全路径。") }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.dropLast().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              let last = components.last, last != ".", last != "..",
              !components[0].contains(":"), components.count <= 128 else { throw AppUpdateError.invalid("ZIP 包含越界或歧义路径。") }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
    static func normalizedLink(path: String, target: String) throws -> String {
        guard !target.isEmpty, target.utf8.count <= 4096, !target.hasPrefix("/"), !target.contains("\\"),
              !target.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw AppUpdateError.invalid("ZIP 符号链接目标无效。") }
        var components = path.split(separator: "/").dropLast().map(String.init)
        for part in target.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !components.isEmpty else { throw AppUpdateError.invalid("ZIP 符号链接指向展开目录之外。") }
                components.removeLast()
            } else { components.append(String(part)) }
        }
        guard !components.isEmpty else { throw AppUpdateError.invalid("ZIP 符号链接不能指向展开根目录。") }
        return components.joined(separator: "/")
    }
    static func inspect(_ data: Data) throws -> [AppcastZIPEntry] {
        func invalid() -> AppUpdateError { .invalid("ZIP 目录损坏、不受支持或超过安全预算。") }
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - 2 else { throw invalid() }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - 4 else { throw invalid() }
            return Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        guard data.count >= 22 else { throw invalid() }
        var end: Int?
        for index in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if try u32(index) == 0x06054b50, index + 22 + (try u16(index + 20)) == data.count { end = index; break }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw invalid() }
        let count = try u16(end + 10), diskCount = try u16(end + 8)
        let centralSize = try u32(end + 12), centralOffset = try u32(end + 16)
        guard count > 0, count < 65535, count == diskCount, centralOffset + centralSize == end else { throw invalid() }
        let inspectionBegan = ProcessInfo.processInfo.systemUptime
        var cursor = centralOffset, total = 0, results: [AppcastZIPEntry] = [], names = Set<String>(), ranges: [Range<Int>] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - inspectionBegan <= 180 else { throw AppUpdateError.invalid("ZIP 安全检查超时。") }
            guard try u32(cursor) == 0x02014b50 else { throw invalid() }
            let flags = try u16(cursor + 8), method = try u16(cursor + 10)
            let compressed = try u32(cursor + 20), expanded = try u32(cursor + 24)
            let nameLength = try u16(cursor + 28), extraLength = try u16(cursor + 30), commentLength = try u16(cursor + 32)
            let disk = try u16(cursor + 34), external = try u32(cursor + 38), local = try u32(cursor + 42)
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= end, nameLength > 0, disk == 0, flags & 0xf7f1 == 0, method == 0 || method == 8,
                  compressed < 0xffffffff, expanded < 0xffffffff, local < centralOffset,
                  let rawPath = String(data: data[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8) else { throw invalid() }
            func checkExtra(_ start: Int, _ length: Int) throws {
                var offset = start
                while offset < start + length {
                    guard offset + 4 <= start + length else { throw invalid() }
                    let tag = try u16(offset), size = try u16(offset + 2)
                    guard tag != 0x0001, tag != 0x7075, offset + 4 + size <= start + length else { throw invalid() }
                    offset += 4 + size
                }
            }
            try checkExtra(cursor + 46 + nameLength, extraLength)
            let path = try validatePath(rawPath)
            guard names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw AppUpdateError.invalid("ZIP 包含重复或大小写歧义的路径。") }
            total += expanded
            guard total <= maximumExpandedBytes else { throw invalid() }
            let mode = (external >> 16) & 0xffff, kind = mode & 0xf000
            guard [0, 0x4000, 0x8000, 0xa000].contains(kind), mode & 0x0c00 == 0 else { throw invalid() }
            let directory = rawPath.hasSuffix("/") || kind == 0x4000
            guard !directory || (expanded == 0 && kind != 0xa000) else { throw invalid() }
            guard try u32(local) == 0x04034b50, try u16(local + 6) == flags, try u16(local + 8) == method else { throw invalid() }
            let localNameLength = try u16(local + 26), localExtraLength = try u16(local + 28)
            let payload = local + 30 + localNameLength + localExtraLength
            guard localNameLength == nameLength, payload <= centralOffset, payload + compressed <= centralOffset,
                  data[(local + 30)..<(local + 30 + localNameLength)] == data[(cursor + 46)..<(cursor + 46 + nameLength)] else { throw invalid() }
            try checkExtra(local + 30 + localNameLength, localExtraLength)
            guard method != 0 || compressed == expanded else { throw invalid() }
            if flags & 8 == 0 {
                guard try u32(local + 18) == compressed, try u32(local + 22) == expanded,
                      try u32(local + 14) == u32(cursor + 16) else { throw invalid() }
            }
            let range = local..<(payload + compressed)
            ranges.append(range)
            // Verify actual expansion and CRC in fixed memory before ditto writes
            // anything. A forged size header cannot turn into a disk-filling bomb.
            try validatePayload(data, range: payload..<(payload + compressed), method: method,
                expectedLength: expanded, expectedCRC: UInt32(try u32(cursor + 16)), began: inspectionBegan)
            var target: String?
            if kind == 0xa000 {
                guard expanded > 0, expanded <= 4096, compressed <= 16384 else { throw invalid() }
                let bytes = Data(data[payload..<(payload + compressed)])
                let targetData = try inflateLink(bytes, method: method, length: expanded)
                guard let value = String(data: targetData, encoding: .utf8) else { throw invalid() }
                _ = try normalizedLink(path: path, target: value)
                target = value
            }
            results.append(AppcastZIPEntry(path: path, isDirectory: directory, linkTarget: target, uncompressedSize: expanded))
            cursor = next
        }
        guard cursor == end else { throw invalid() }
        let orderedRanges = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<orderedRanges.count where orderedRanges[index].lowerBound < orderedRanges[index - 1].upperBound { throw invalid() }
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        let links = Dictionary(uniqueKeysWithValues: results.compactMap { entry in entry.linkTarget.map { (key(entry.path), $0) } })
        for entry in results {
            let parts = entry.path.split(separator: "/")
            for index in 1..<parts.count where links[key(parts.prefix(index).joined(separator: "/"))] != nil { throw AppUpdateError.invalid("ZIP 条目不能写入符号链接目录。") }
        }
        for entry in results where entry.linkTarget != nil {
            // Resolve links before processing '..', matching filesystem semantics.
            var pending = entry.path.split(separator: "/").dropLast().map(String.init) + entry.linkTarget!.split(separator: "/").map(String.init)
            var resolved: [String] = [], seen = Set<String>(), steps = 0
            while !pending.isEmpty {
                steps += 1
                guard steps <= 1024 else { throw AppUpdateError.invalid("ZIP 符号链接链过长。") }
                let part = pending.removeFirst()
                if part == "." { continue }
                if part == ".." {
                    guard !resolved.isEmpty else { throw AppUpdateError.invalid("ZIP 符号链接解析后越界。") }
                    resolved.removeLast(); continue
                }
                resolved.append(part)
                let current = key(resolved.joined(separator: "/"))
                if let target = links[current] {
                    guard seen.insert(current).inserted, seen.count <= 40 else { throw AppUpdateError.invalid("ZIP 符号链接存在循环。") }
                    resolved.removeLast()
                    pending = target.split(separator: "/").map(String.init) + pending
                }
            }
            guard !resolved.isEmpty else { throw AppUpdateError.invalid("ZIP 符号链接指向展开根目录。") }
        }
        return results
    }
    private static func validatePayload(_ data: Data, range: Range<Int>, method: Int, expectedLength: Int, expectedCRC: UInt32, began: TimeInterval) throws {
        var checksum = crc32(0, nil, 0)
        func checkBudget() throws {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime - began <= 180 else { throw AppUpdateError.invalid("ZIP 安全检查超时。") }
        }
        if method == 0 {
            try data.withUnsafeBytes { pointer in
                var offset = range.lowerBound
                while offset < range.upperBound {
                    try checkBudget()
                    let size = min(65536, range.upperBound - offset)
                    checksum = crc32(checksum, pointer.bindMemory(to: Bytef.self).baseAddress!.advanced(by: offset), uInt(size))
                    offset += size
                }
            }
        } else {
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw AppUpdateError.invalid("无法验证 ZIP 压缩数据。") }
            defer { inflateEnd(&stream) }
            var output = [UInt8](repeating: 0, count: 65536)
            try data.withUnsafeBytes { source in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: source.bindMemory(to: Bytef.self).baseAddress!.advanced(by: range.lowerBound))
                stream.avail_in = uInt(range.count)
                while true {
                    try checkBudget()
                    let status: Int32 = output.withUnsafeMutableBytes { destination in
                        stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(destination.count)
                        return inflate(&stream, Z_NO_FLUSH)
                    }
                    let size = output.count - Int(stream.avail_out)
                    guard stream.total_out <= expectedLength else { throw AppUpdateError.invalid("ZIP 实际展开内容超过声明大小。") }
                    checksum = output.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(size)) }
                    if status == Z_STREAM_END { break }
                    guard status == Z_OK, size > 0 || stream.avail_in > 0 else { throw AppUpdateError.invalid("ZIP 压缩数据损坏。") }
                }
            }
            guard stream.total_in == range.count, stream.total_out == expectedLength else { throw AppUpdateError.invalid("ZIP 实际长度与目录不符。") }
        }
        guard UInt32(checksum) == expectedCRC else { throw AppUpdateError.invalid("ZIP 内容校验失败。") }
    }
    private static func inflateLink(_ data: Data, method: Int, length: Int) throws -> Data {
        if method == 0 {
            guard data.count == length else { throw AppUpdateError.invalid("ZIP 链接长度无效。") }; return data
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw AppUpdateError.invalid("无法读取 ZIP 链接。") }
        defer { inflateEnd(&stream) }
        var output = Data(count: length)
        let result: Int32 = data.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(length)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, stream.total_out == length, stream.total_in == data.count else { throw AppUpdateError.invalid("ZIP 链接压缩内容无效。") }
        return output
    }
    static func validateExtracted(_ root: URL, entries: [AppcastZIPEntry]) throws {
        // Directory enumeration may canonicalize /var to /private/var. Use the
        // same physical root for enumeration and relative-path calculation.
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let expected = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        var count = 0, total: Int64 = 0
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in false }) else { throw AppUpdateError.invalid("无法检查展开目录。") }
        while let file = iterator.nextObject() as? URL {
            try Task.checkCancellation()
            count += 1
            guard count <= 150_000 else { throw AppUpdateError.invalid("展开目录条目过多。") }
            let identity = try FileIdentity.capture(file)
            // Resolve ancestors consistently but preserve the final component:
            // resolving a symlink itself would lose its declared archive name.
            let physicalPath = file.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(file.lastPathComponent).path
            guard physicalPath.hasPrefix(root.path + "/") else { throw AppUpdateError.invalid("展开目录存在越界路径。") }
            let relative = String(physicalPath.dropFirst(root.path.count + 1))
            guard PathSafety.contains(file, in: root) else { throw AppUpdateError.invalid("展开目录存在越界路径。") }
            switch identity.fileType {
            case UInt32(S_IFLNK):
                iterator.skipDescendants()
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
                guard expected[relative]?.linkTarget == target, PathSafety.contains(file.resolvingSymlinksInPath(), in: root) else { throw AppUpdateError.invalid("展开后的符号链接不匹配或越界。") }
            case UInt32(S_IFREG):
                guard let entry = expected[relative], entry.linkTarget == nil, !entry.isDirectory,
                      identity.size == entry.uncompressedSize else { throw AppUpdateError.invalid("展开后的文件与 ZIP 声明不符：\(relative.prefix(512))（实际 \(identity.size) 字节，声明 \(expected[relative].map { String($0.uncompressedSize) } ?? "缺失")）。") }
                total += identity.size
                guard total <= maximumExpandedBytes else { throw AppUpdateError.invalid("展开内容超过预算。") }
            case UInt32(S_IFDIR): break // Extractors may create omitted parent directories.
            default: throw AppUpdateError.invalid("展开目录包含特殊文件。")
            }
        }
        // Files removed or omitted by an extractor must not silently pass validation.
        // ditto consumes __MACOSX AppleDouble entries into resource forks/xattrs;
        // those signed, CRC-checked metadata files need not exist as separate paths.
        for entry in entries where !entry.isDirectory && !entry.path.hasPrefix("__MACOSX/") {
            let path = root.appendingPathComponent(entry.path)
            _ = try FileIdentity.capture(path)
        }
    }
}
