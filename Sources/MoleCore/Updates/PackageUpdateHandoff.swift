import Foundation
import CryptoKit
import Darwin

/// Preparation and handoff are not installation. Native Installer alone owns
/// target selection, administrator approval, scripts and the final outcome.
public struct PreparedPackageUpdate: Identifiable, Sendable {
    public let id: UUID
    public let packageURL: URL
    public let version: String
    public let applicationName: String
    public let signingReport: String
    let target: AppUpdateTarget
    let release: AppcastRelease
    let identity: FileIdentity
    let directoryIdentity: FileIdentity
    let sha256: Data
}

struct PackageTrustAssessment: Sendable {
    var run: @Sendable (ToolCommand) async throws -> ToolCommandResult = {
        try await ToolCommandExecutor().run($0, timeout: 60, environment: ["LC_ALL": "C", "LANG": "C"], maximumOutputBytes: 128 * 1024)
    }
    func assess(_ file: URL) async throws -> String {
        let signature = try await run(ToolCommand("/usr/sbin/pkgutil", ["--check-signature", file.path]))
        guard signature.succeeded else { throw AppUpdateError.invalid("安装包签名未通过系统验证。\(signature.output.prefix(2000))") }
        let policy = try await run(ToolCommand("/usr/sbin/spctl", ["--assess", "--type", "install", "--verbose=4", file.path]))
        guard policy.succeeded else { throw AppUpdateError.invalid("系统安装策略拒绝此包，未打开安装器。\(policy.output.prefix(2000))") }
        return String((signature.output + "\n" + policy.output).prefix(32_000))
    }
}

public struct PackageUpdateHandoff: Sendable {
    var cache = RebuildPaths.caches.appendingPathComponent("PackageUpdates", isDirectory: true)
    var download: (@Sendable (URL, URL, Int64) async throws -> Void)?
    var original: @Sendable (AppUpdateTarget) async throws -> String = { try await AppcastUpdateInstaller().validateOriginal($0) }
    var service = AppcastService()
    var trust = PackageTrustAssessment()
    var log: @Sendable (String, Bool) async -> Void = { text, succeeded in
        await ActivityStore.shared.append(ActivityRecord(category: "更新安装包", title: "准备交接系统安装器", detail: text, succeeded: succeeded))
    }
    public init() {}
    public func installedVersionStatus(_ package: PreparedPackageUpdate) async throws -> String {
        try await Task.detached(priority: .utility) {
            let app = package.target.application
            try PathSafety.rejectSymbolicLinks(in: app.url)
            let info = try AppcastInstallValidation.readInfo(app.url)
            guard info["CFBundleIdentifier"] as? String == app.bundleID,
                  let team = app.teamID, try AppcastInstallValidation.strictTeam(app.url) == team,
                  let version = info["CFBundleShortVersionString"] as? String,
                  let build = info["CFBundleVersion"] as? String else {
                throw AppUpdateError.invalid("无法确认原位置应用的身份或版本。")
            }
            if version == app.version && build == app.build {
                return "当前仍为版本 \(version)（构建 \(build)）。请确认安装器已完成，再复查。"
            }
            if version == package.release.version && build == package.release.build {
                return "已在原位置读到目标版本 \(version)（构建 \(build)）。"
            }
            return "原位置当前为版本 \(version)（构建 \(build)），目标为 \(package.release.version)（构建 \(package.release.build)）。"
        }.value
    }

    public static func isPackage(_ release: AppcastRelease) -> Bool {
        release.installationType == "package" || ["pkg", "mpkg"].contains(release.downloadURL.pathExtension.lowercased())
    }
    public static func eligibilityIssue(target: AppUpdateTarget, release: AppcastRelease) -> String? {
        guard target.source == .sparkle, !target.application.isProtected else { return "此来源的安装器更新请使用应用自身更新。" }
        guard ["pkg", "mpkg"].contains(release.downloadURL.pathExtension.lowercased()), release.installationType == nil || release.installationType == "package" else { return "仅支持直接下载的平面 PKG/MPKG；归档内安装器请使用应用自身更新。" }
        guard AppUpdateURLPolicy.allows(target.feedURL), AppUpdateURLPolicy.allows(release.downloadURL),
              Data(base64Encoded: target.publicKey ?? "")?.count == 32, Data(base64Encoded: release.signature ?? "")?.count == 64,
              let length = release.length, (1...1_073_741_824).contains(length),
              AppUpdateVersion.compare(release.build, target.application.build) == .orderedDescending,
              !(target.application.teamID ?? "").isEmpty else { return "安装包缺少更高版本、已知长度、应用公钥或包签名，无法准备交接。" }
        return nil
    }
    public func prepare(target: AppUpdateTarget, release: AppcastRelease, downloadProgress: @escaping @Sendable (AppDownloadProgress) -> Void = { _ in }, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> PreparedPackageUpdate {
        try await AppcastInstallGate.shared.acquire()
        do {
            let result = try await prepareLocked(target: target, release: release, downloadProgress: downloadProgress, progress: progress)
            await log("已验证包，尚未安装：\(result.packageURL.path)", true)
            await AppcastInstallGate.shared.release(); return result
        } catch {
            await log(error.localizedDescription, false)
            await AppcastInstallGate.shared.release(); throw error
        }
    }
    private func prepareLocked(target: AppUpdateTarget, release: AppcastRelease, downloadProgress: @escaping @Sendable (AppDownloadProgress) -> Void, progress: @escaping @Sendable (String) -> Void) async throws -> PreparedPackageUpdate {
        if let issue = Self.eligibilityIssue(target: target, release: release) { throw AppUpdateError.unavailable(issue) }
        try AppcastInstallValidation.validateSystem(minimum: release.minimumSystemVersion, maximum: release.maximumSystemVersion)
        progress("复核应用身份与信息源…")
        _ = try await original(target)
        try await service.revalidateSignedRelease(release, target: target)
        let length = release.length!
        try prepareCache(requiredBytes: length)
        let id = UUID(), directory = cache.appendingPathComponent("package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
        let file = directory.appendingPathComponent("update.pkg")
        progress("下载并验证安装包签名…")
        if let download { try await download(release.downloadURL, file, length) }
        else { try await AppcastArchiveDownload().download(release.downloadURL, to: file, length: length, progress: downloadProgress) }
        try Task.checkCancellation()
        let identity = try FileIdentity.capture(file)
        guard identity.fileType == UInt32(S_IFREG), identity.size == length else { throw AppUpdateError.invalid("安装包类型或长度不符。") }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard data.starts(with: Data("xar!".utf8)) else { throw AppUpdateError.invalid("下载内容不是支持的平面安装包。") }
        try AppcastInstallValidation.verifyPackage(data, target: target, release: release)
        let hash = Data(SHA256.hash(data: data))
        progress("由系统核对安装包签名与安装策略…")
        let report = try await trust.assess(file)
        try Task.checkCancellation()
        _ = try await original(target)
        try await service.revalidateSignedRelease(release, target: target)
        try PathSafety.rejectSymbolicLinks(in: file)
        guard try FileIdentity.capture(file) == identity, Data(SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))) == hash else { throw AppUpdateError.invalid("安装包在验证期间已改变，未准备交接。") }
        let metadata = ["phase": "verified-not-installed", "application": target.application.bundleID, "versionFromFeed": release.version, "package": file.path, "sha256": hash.map { String(format: "%02x", $0) }.joined(), "signingReport": report]
        try JSONEncoder().encode(metadata).write(to: directory.appendingPathComponent("verification.json"), options: .atomic)
        let directoryIdentity = try FileIdentity.capture(directory)
        retained = true
        progress("包已验证，尚未安装；请复核系统签名信息后选择是否打开安装器。")
        return PreparedPackageUpdate(id: id, packageURL: file, version: release.version, applicationName: target.application.name,
            signingReport: report, target: target, release: release, identity: identity,
            directoryIdentity: directoryIdentity, sha256: hash)
    }
    /// Called immediately before the UI opens the fixed system Installer app.
    /// There is no /usr/sbin/installer invocation or administrator execution here.
    public func validateForOpening(_ package: PreparedPackageUpdate) async throws -> URL {
        let directory = package.packageURL.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL.path == cache.standardizedFileURL.path,
              directory.lastPathComponent.hasPrefix("package-"), package.packageURL.lastPathComponent == "update.pkg" else { throw AppUpdateError.invalid("安装包不在本应用准备的缓存位置。") }
        try PathSafety.rejectSymbolicLinks(in: package.packageURL)
        try validateDirectory(cache)
        try validateDirectory(directory)
        let currentDirectory = try FileIdentity.capture(directory)
        guard currentDirectory.fileType == UInt32(S_IFDIR), currentDirectory.device == package.directoryIdentity.device,
              currentDirectory.inode == package.directoryIdentity.inode,
              try FileIdentity.capture(package.packageURL) == package.identity else { throw AppUpdateError.invalid("安装包或缓存目录身份已改变。") }
        let bytes = try Data(contentsOf: package.packageURL, options: .mappedIfSafe)
        guard Data(SHA256.hash(data: bytes)) == package.sha256 else { throw AppUpdateError.invalid("安装包已改变，未打开系统安装器。") }
        _ = try await original(package.target)
        try await service.revalidateSignedRelease(package.release, target: package.target)
        try AppcastInstallValidation.verifyPackage(bytes, target: package.target, release: package.release)
        _ = try await trust.assess(package.packageURL)
        guard try FileIdentity.capture(package.packageURL) == package.identity else { throw AppUpdateError.invalid("安装包在复核期间已改变。") }
        return package.packageURL
    }
    private func prepareCache(requiredBytes: Int64) throws {
        try PathSafety.rejectSymbolicLinks(in: cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validateDirectory(cache)
        let directories = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        guard directories.count < 32 else { throw AppUpdateError.unavailable("安装包缓存项目过多，请在 Finder 中检查：\(cache.path)") }
        var total = requiredBytes
        for directory in directories where directory.lastPathComponent.hasPrefix("package-") {
            try validateDirectory(directory)
            if let item = try? FileIdentity.capture(directory.appendingPathComponent("update.pkg")), item.fileType == UInt32(S_IFREG) {
                guard item.size >= 0, item.size <= 2_147_483_648, total <= 2_147_483_648 - item.size else { throw AppUpdateError.unavailable("安装包缓存将超过 2 GiB，请在 Finder 中检查：\(cache.path)") }
                total += item.size
            }
        }
        guard total <= 2_147_483_648 else { throw AppUpdateError.unavailable("安装包缓存将超过 2 GiB，请在安装结束后自行检查并清理：\(cache.path)") }
    }
    private func validateDirectory(_ directory: URL) throws {
        try PathSafety.rejectSymbolicLinks(in: directory)
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw AppUpdateError.invalid("安装包缓存的权限或身份无效。") }
    }
}
