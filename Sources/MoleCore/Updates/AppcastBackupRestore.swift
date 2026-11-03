import Foundation
import AppKit
import CryptoKit
import Darwin

public struct AppBackupRestorePreview: Identifiable, Sendable {
    public let id: UUID
    public let applicationURL: URL
    public let backupURL: URL
    public let name: String
    public let backupVersion: String
    public let currentVersion: String?
    public let preservedVersionURL: URL?
    public let resumesInterruptedRestore: Bool
    let fingerprint: Data
    let currentIdentity: FileIdentity?
    let backupIdentity: FileIdentity
    let backupBuild: String
    let bundleID: String
    let teamID: String
}

public struct AppBackupRestoreOutcome: Sendable {
    public let applicationURL: URL
    public let preservedVersionURL: URL?
}

/// Recovery uses only this app's durable journal and requires a fresh review.
/// The installed update is retained, never overwritten or removed.
public struct AppcastBackupRestorer: Sendable {
    public init() {}
    public func preview(recordID: UUID) async throws -> AppBackupRestorePreview {
        try Task.checkCancellation()
        return try AppBackupRestoreEngine().preview(recordID: recordID)
    }
    public func restore(_ preview: AppBackupRestorePreview) async throws -> AppBackupRestoreOutcome {
        try Task.checkCancellation()
        try await AppcastInstallGate.shared.acquire()
        do {
            let engine = AppBackupRestoreEngine()
            // Both paths and Bundle ID are checked. Nothing is launched or quit.
            let running = await MainActor.run {
                NSWorkspace.shared.runningApplications.contains { app in
                    app.bundleIdentifier == preview.bundleID ||
                    [preview.applicationURL, preview.backupURL, preview.preservedVersionURL].compactMap { $0 }.contains {
                        $0.standardizedFileURL == app.bundleURL?.standardizedFileURL
                    }
                }
            }
            guard !running else { throw AppUpdateError.unavailable("请先保存工作并退出此应用的所有版本，再恢复旧版本。") }
            try Task.checkCancellation()
            // Do not use a detached task here: caller cancellation must reach the
            // last check before the synchronous, journalled commit starts.
            let outcome = try engine.restore(preview) {
                guard NSRunningApplication.runningApplications(withBundleIdentifier: preview.bundleID).isEmpty else {
                    throw AppUpdateError.unavailable("复核后此应用已启动，请退出后重新恢复。")
                }
            }
            await ActivityStore.shared.append(ActivityRecord(category: "应用更新", title: "已恢复 \(preview.name) 的旧版本", detail: "原位置：\(outcome.applicationURL.path)；换下版本：\(outcome.preservedVersionURL?.path ?? "原位置为空，无需换下")"))
            await AppcastInstallGate.shared.release()
            return outcome
        } catch {
            await ActivityStore.shared.append(ActivityRecord(category: "应用更新", title: "旧版本恢复未完成", detail: error.localizedDescription, succeeded: false))
            await AppcastInstallGate.shared.release()
            throw error
        }
    }
}

struct RestorableApplication: Sendable {
    let bundleID: String
    let teamID: String
    let build: String
    let version: String
}

/// Internal dependency injection is used only by isolated filesystem fixtures.
/// Production always validates an Apple-anchored developer signature and ordinary app roots.
struct AppBackupRestoreEngine: Sendable {
    var journal = AppcastRecoveryJournal.directory
    var roots = [URL(fileURLWithPath: "/Applications", isDirectory: true), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    var inspect: @Sendable (URL) throws -> RestorableApplication = { try verifiedApplication($0) }
    var beforeMove: @Sendable (Int) throws -> Void = { _ in }

    func preview(recordID: UUID, preferredPreservedURL: URL? = nil) throws -> AppBackupRestorePreview {
        try Task.checkCancellation()
        guard let record = try AppcastRecoveryJournal.records(directory: journal).first(where: { $0.id == recordID }),
              ["prepared", "originalBackedUp", "installed", "needsReview", "restorePrepared", "restoreCurrentPreserved", "restoreNeedsReview"].contains(record.phase) else {
            throw AppUpdateError.unavailable("没有可恢复的安装记录；请在 Finder 中核对版本位置。")
        }
        let app = record.applicationURL, backup = record.backupURL, parent = app.deletingLastPathComponent()
        guard let root = roots.first(where: { PathSafety.contains(app, in: $0) }),
              app.pathExtension == "app", !app.lastPathComponent.hasPrefix("."),
              app.standardizedFileURL == app, backup.standardizedFileURL == backup,
              backup.deletingLastPathComponent() == parent,
              backup.lastPathComponent.hasPrefix(".\(app.deletingPathExtension().lastPathComponent).MoleRebuild-backup-"),
              let suffix = backup.lastPathComponent.components(separatedBy: ".MoleRebuild-backup-").last,
              suffix.hasSuffix(".app"), UUID(uuidString: String(suffix.dropLast(4))) != nil,
              record.originalIdentity.fileType == UInt32(S_IFDIR),
              !PathSafety.contains(Bundle.main.bundleURL, in: app, includeRoot: true) else {
            throw AppUpdateError.invalid("备份记录的应用路径或目录范围无效。")
        }
        try PathSafety.validateDestination(app, allowedRoot: root)
        try PathSafety.validate(backup, allowedRoot: root, expectedIdentity: record.originalIdentity)
        guard FileManager.default.isWritableFile(atPath: parent.path) else { throw AppUpdateError.unavailable("应用目录不可写，请在 Finder 中恢复或使用厂商安装方式。") }
        let old = try inspect(backup)
        try validateApplicationID(old.bundleID)
        guard !old.teamID.isEmpty else { throw AppUpdateError.invalid("旧版本缺少可验证的开发者身份。") }
        if let expected = record.originalBundleID { guard old.bundleID == expected else { throw AppUpdateError.invalid("备份应用标识已改变。") } }
        if let expected = record.originalTeamID { guard old.teamID == expected else { throw AppUpdateError.invalid("备份开发者签名与安装记录不一致。") } }
        if let expected = record.originalBuild { guard old.build == expected else { throw AppUpdateError.invalid("备份版本与安装记录不一致。") } }
        let current = try identityIfPresent(app)
        guard current != record.originalIdentity else { throw AppUpdateError.unavailable("原位置已是记录中的旧版本，无需重复恢复。") }
        var preserved: URL?
        var currentVersion: String?
        let resuming = ["restorePrepared", "restoreCurrentPreserved", "restoreNeedsReview"].contains(record.phase)
        if let current {
            try PathSafety.validate(app, allowedRoot: root, expectedIdentity: current)
            guard current == record.replacementIdentity else { throw AppUpdateError.invalid("原位置已出现其他内容，恢复不会覆盖它。") }
            let installed = try inspect(app)
            guard installed.bundleID == old.bundleID, installed.teamID == old.teamID, installed.build == record.build else {
                throw AppUpdateError.invalid("当前版本与更新记录或旧版开发者身份不一致。")
            }
            currentVersion = installed.version
            preserved = record.displacedURL ?? preferredPreservedURL ?? parent.appendingPathComponent(".\(app.deletingPathExtension().lastPathComponent).MoleRebuild-displaced-\(UUID().uuidString).app")
            try validatePreservedPath(preserved!, app: app, root: root)
            guard try identityIfPresent(preserved!) == nil else { throw AppUpdateError.invalid("换下版本的保留位置已被占用，未移动应用。") }
            if resuming { guard record.displacedIdentity == current else { throw AppUpdateError.invalid("中断恢复记录的当前版本身份无效。") } }
        } else {
            // Old journals have no pinned identity metadata. Without a current
            // signed version to compare, leave those ambiguous records to Finder.
            guard record.originalBundleID == old.bundleID, record.originalTeamID == old.teamID, record.originalBuild == old.build else {
                throw AppUpdateError.unavailable("旧记录缺少开发者与版本信息，且原位置为空；请在 Finder 中核对恢复。")
            }
            if resuming, let url = record.displacedURL {
                guard let expected = record.displacedIdentity else { throw AppUpdateError.invalid("中断恢复记录缺少换下版本的身份。") }
                try validatePreservedPath(url, app: app, root: root)
                try PathSafety.validate(url, allowedRoot: root, expectedIdentity: expected)
                let replacement = try inspect(url)
                guard replacement.bundleID == old.bundleID, replacement.teamID == old.teamID, replacement.build == record.build,
                      expected == record.replacementIdentity else { throw AppUpdateError.invalid("中断恢复所保留的版本不匹配。") }
                preserved = url; currentVersion = replacement.version
            } else if resuming, record.displacedIdentity != nil {
                throw AppUpdateError.invalid("中断恢复记录缺少换下版本的位置。")
            }
        }
        try PathSafety.validate(backup, allowedRoot: root, expectedIdentity: record.originalIdentity)
        return AppBackupRestorePreview(id: record.id, applicationURL: app, backupURL: backup,
            name: app.deletingPathExtension().lastPathComponent, backupVersion: old.version, currentVersion: currentVersion,
            preservedVersionURL: preserved, resumesInterruptedRestore: resuming,
            fingerprint: try fingerprint(record), currentIdentity: current, backupIdentity: record.originalIdentity,
            backupBuild: old.build, bundleID: old.bundleID, teamID: old.teamID)
    }

    func restore(_ review: AppBackupRestorePreview, beforeCommit: () throws -> Void = {}) throws -> AppBackupRestoreOutcome {
        let checked = try preview(recordID: review.id, preferredPreservedURL: review.preservedVersionURL)
        guard checked.fingerprint == review.fingerprint, checked.currentIdentity == review.currentIdentity,
              checked.backupIdentity == review.backupIdentity, checked.preservedVersionURL == review.preservedVersionURL,
              checked.backupBuild == review.backupBuild, checked.bundleID == review.bundleID, checked.teamID == review.teamID else {
            throw AppUpdateError.invalid("恢复状态在复核后发生变化，请重新复核。")
        }
        guard var record = try AppcastRecoveryJournal.records(directory: journal).first(where: { $0.id == review.id }),
              try fingerprint(record) == review.fingerprint else { throw AppUpdateError.invalid("恢复记录已改变，请重新复核。") }
        let app = checked.applicationURL, backup = checked.backupURL
        let preserved = checked.preservedVersionURL
        try beforeCommit()
        // Persist the intended location before moving anything. The file moves
        // use exclusive renames without suspension; failed verification later
        // attempts to restore the previous layout while retaining both apps.
        record.displacedURL = preserved
        record.displacedIdentity = checked.currentIdentity ?? record.displacedIdentity
        record.phase = "restorePrepared"; record.detail = "已复核旧版，准备恢复；换下版本的保留位置已记录。"
        try AppcastRecoveryJournal.write(record, directory: journal)
        try Task.checkCancellation()
        try checkIdentity(backup, expected: checked.backupIdentity)
        try checkIdentity(app, expected: checked.currentIdentity)
        var movedCurrent = false
        do {
            if checked.currentIdentity != nil, let preserved {
                try beforeMove(1)
                try checkIdentity(app, expected: checked.currentIdentity)
                try exclusiveMove(app, to: preserved)
                movedCurrent = true
                try checkIdentity(preserved, expected: checked.currentIdentity)
                record.phase = "restoreCurrentPreserved"; record.detail = "当前版本已保留，准备将旧版放回原位置。"
                try AppcastRecoveryJournal.write(record, directory: journal)
            }
            try beforeMove(2)
            try checkIdentity(backup, expected: checked.backupIdentity)
            try exclusiveMove(backup, to: app)
        } catch {
            if movedCurrent, let preserved,
               (try? identityIfPresent(app)) == nil,
               (try? FileIdentity.capture(preserved)) == checked.currentIdentity,
               (try? exclusiveMove(preserved, to: app)) != nil {
                record.phase = "installed"; record.detail = "旧版恢复未完成，换下操作已撤回；两个版本均保留。"
                record.displacedURL = nil; record.displacedIdentity = nil
            } else {
                record.phase = "restoreNeedsReview"; record.detail = "旧版恢复未完成，请核对原位置、旧版备份与换下版本位置。"
            }
            try? AppcastRecoveryJournal.write(record, directory: journal)
            throw AppUpdateError.failed("\(record.detail)\(error.localizedDescription) 旧版：\(backup.path)；换下版本：\(preserved?.path ?? "无")。")
        }
        // Identity after rename and a second strict signature check catch changed
        // contents. On failure keep the suspect app and restore the prior layout.
        do {
            try checkIdentity(app, expected: checked.backupIdentity)
            let restored = try inspect(app)
            guard restored.bundleID == checked.bundleID, restored.teamID == checked.teamID, restored.build == checked.backupBuild else { throw AppUpdateError.invalid("恢复后的应用身份或版本异常。") }
        } catch {
            if (try? FileIdentity.capture(app)) == checked.backupIdentity,
               (try? exclusiveMove(app, to: backup)) != nil {
                if let preserved, let expected = record.displacedIdentity,
                   (try? FileIdentity.capture(preserved)) == expected {
                    try? exclusiveMove(preserved, to: app)
                }
            }
            record.phase = "restoreNeedsReview"; record.detail = "恢复后验证未通过；保留所有版本，请在 Finder 中核对。"
            try? AppcastRecoveryJournal.write(record, directory: journal)
            throw AppUpdateError.failed("\(record.detail)\(error.localizedDescription)")
        }
        record.phase = "restored"; record.detail = "旧版已恢复到原位置。" + (preserved == nil ? "原位置原本为空。" : "换下版本已保留：\(preserved!.path)。")
        do { try AppcastRecoveryJournal.write(record, directory: journal) }
        catch { throw AppUpdateError.failed("旧版本已恢复，但最终记录写入失败。请检查原位置：\(app.path)；换下版本：\(preserved?.path ?? "无")。") }
        return AppBackupRestoreOutcome(applicationURL: app, preservedVersionURL: preserved)
    }

    private func validatePreservedPath(_ url: URL, app: URL, root: URL) throws {
        let prefix = ".\(app.deletingPathExtension().lastPathComponent).MoleRebuild-displaced-"
        guard url.standardizedFileURL == url, url.deletingLastPathComponent() == app.deletingLastPathComponent(),
              url.lastPathComponent.hasPrefix(prefix), url.lastPathComponent.hasSuffix(".app"),
              UUID(uuidString: String(url.lastPathComponent.dropFirst(prefix.count).dropLast(4))) != nil else { throw AppUpdateError.invalid("换下版本的保留路径无效。") }
        try PathSafety.validateDestination(url, allowedRoot: root)
    }
    private func validateApplicationID(_ id: String) throws {
        guard !id.isEmpty, !id.hasPrefix("com.apple."), id != RebuildPaths.bundleIdentifier, id != Bundle.main.bundleIdentifier else {
            throw AppUpdateError.invalid("系统应用或本应用不能在此恢复。")
        }
    }
    private func fingerprint(_ record: AppInstallRecoveryRecord) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: try encoder.encode(record)))
    }
    private func identityIfPresent(_ url: URL) throws -> FileIdentity? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return try FileIdentity.capture(url) }
        guard errno == ENOENT else { throw AppUpdateError.failed("无法核对路径状态：\(url.path)") }
        return nil
    }
    private func checkIdentity(_ url: URL, expected: FileIdentity?) throws {
        try PathSafety.rejectSymbolicLinks(in: url)
        guard try identityIfPresent(url) == expected else { throw AppUpdateError.invalid("文件身份已改变，停止恢复：\(url.path)") }
    }
    private func exclusiveMove(_ from: URL, to: URL) throws {
        try PathSafety.rejectSymbolicLinks(in: from.deletingLastPathComponent())
        try PathSafety.rejectSymbolicLinks(in: to.deletingLastPathComponent())
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else { throw AppUpdateError.failed("无法移动应用且未覆盖目标：\(String(cString: strerror(errno)))") }
        let parentFD = Darwin.open(to.deletingLastPathComponent().path, O_RDONLY)
        guard parentFD >= 0 else { throw AppUpdateError.failed("应用已移动，但无法打开父目录进行同步，请核对恢复记录。") }
        defer { Darwin.close(parentFD) }
        guard fsync(parentFD) == 0 else { throw AppUpdateError.failed("应用已移动，但父目录同步失败，请核对恢复记录。") }
    }
    private static func verifiedApplication(_ url: URL) throws -> RestorableApplication {
        try AppcastDiskImage.validateApplicationTree(url)
        let info = try AppcastInstallValidation.readInfo(url)
        guard info["CFBundlePackageType"] as? String == "APPL",
              let bundleID = info["CFBundleIdentifier"] as? String,
              let build = info["CFBundleVersion"] as? String, !build.isEmpty,
              let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty,
              !executable.contains("/"), executable != ".", executable != ".." else { throw AppUpdateError.invalid("备份应用的声明无效。") }
        try AppcastInstallValidation.validateSystem(minimum: info["LSMinimumSystemVersion"] as? String, maximum: nil)
        if let byArchitecture = info["LSMinimumSystemVersionByArchitecture"] as? [String: String] {
            try AppcastInstallValidation.validateSystem(minimum: byArchitecture[AppcastInstallValidation.architecture], maximum: nil)
        }
        let binary = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).resolvingSymlinksInPath()
        guard PathSafety.contains(binary, in: url) else { throw AppUpdateError.invalid("应用可执行文件越过应用边界。") }
        try AppcastInstallValidation.validateMachO(Data(contentsOf: binary, options: .mappedIfSafe))
        let teamID = try AppcastInstallValidation.strictTeam(url)
        return RestorableApplication(bundleID: bundleID, teamID: teamID, build: build, version: info["CFBundleShortVersionString"] as? String ?? build)
    }
}
