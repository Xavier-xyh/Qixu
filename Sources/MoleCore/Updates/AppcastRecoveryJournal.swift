import Foundation
import Darwin

/// A durable recovery hint, not proof that a filesystem step completed. After a
/// crash, inspect all three paths and their identities; no automatic restore runs.
public struct AppInstallRecoveryRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let applicationURL: URL
    public let backupURL: URL
    public let stagedURL: URL
    public let date: Date
    public var phase: String
    public var detail: String
    public let originalIdentity: FileIdentity
    public var replacementIdentity: FileIdentity?
    public var mountURL: URL?
    public var diskImageURL: URL?
    public var workingURL: URL?
    public var workingIdentity: FileIdentity?
    public var archiveIdentity: FileIdentity?
    public var originalBundleID: String?
    public var originalTeamID: String?
    public var originalBuild: String?
    public var displacedURL: URL?
    public var displacedIdentity: FileIdentity?
    public let build: String
    init(applicationURL: URL, backupURL: URL, stagedURL: URL, originalIdentity: FileIdentity, replacementIdentity: FileIdentity?, build: String) {
        id = UUID(); date = Date(); phase = "prepared"; detail = "已记录恢复路径，尚未确认替换完成。"
        self.applicationURL = applicationURL; self.backupURL = backupURL; self.stagedURL = stagedURL
        self.originalIdentity = originalIdentity; self.replacementIdentity = replacementIdentity; self.build = build
        mountURL = nil; diskImageURL = nil; workingURL = nil; workingIdentity = nil; archiveIdentity = nil
        originalBundleID = nil; originalTeamID = nil; originalBuild = nil
        displacedURL = nil; displacedIdentity = nil
    }
}

enum AppcastRecoveryJournal {
    static var directory: URL { RebuildPaths.applicationSupport.appendingPathComponent("AppUpdateRecovery", isDirectory: true) }
    static func write(_ record: AppInstallRecoveryRecord, directory: URL = directory) throws {
        let fm = FileManager.default
        try PathSafety.rejectSymbolicLinks(in: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try PathSafety.rejectSymbolicLinks(in: directory)
        var status = stat()
        guard lstat(directory.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid() else {
            throw AppUpdateError.failed("更新恢复记录目录身份无效。")
        }
        guard chmod(directory.path, 0o700) == 0 else { throw AppUpdateError.failed("无法保护更新恢复记录目录。") }
        // If the app support / journal directories were just created, flush their
        // parent entries too; persisting a JSON inode alone is not a recovery log.
        for parent in [directory.deletingLastPathComponent(), directory.deletingLastPathComponent().deletingLastPathComponent()] {
            let fd = Darwin.open(parent.path, O_RDONLY)
            guard fd >= 0 else { throw AppUpdateError.failed("无法同步更新记录的父目录。") }
            let synced = fsync(fd); Darwin.close(fd)
            guard synced == 0 else { throw AppUpdateError.failed("无法持久保存更新记录目录。") }
        }
        let destination = directory.appendingPathComponent(record.id.uuidString + ".json")
        let temporary = directory.appendingPathComponent("." + UUID().uuidString + ".tmp")
        let data = try JSONEncoder().encode(record)
        guard data.count <= 128 * 1024 else { throw AppUpdateError.failed("更新恢复记录超过限制。") }
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AppUpdateError.failed("无法创建更新恢复记录；应用未获准替换。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? fm.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, destination.path) == 0 else { throw AppUpdateError.failed("无法保存更新恢复记录。") }
        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw AppUpdateError.failed("无法同步更新恢复记录目录。") }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw AppUpdateError.failed("无法持久保存更新恢复记录；应用未获准继续替换。") }
    }
    static func records(directory: URL = directory) throws -> [AppInstallRecoveryRecord] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return [] }
        try PathSafety.rejectSymbolicLinks(in: directory)
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard files.count <= 10_000 else { throw AppUpdateError.failed("更新恢复记录过多，请检查本应用记录目录。") }
        var records: [AppInstallRecoveryRecord] = []
        for file in files {
            let identity = try FileIdentity.capture(file)
            guard identity.fileType == UInt32(S_IFREG), identity.size > 0, identity.size <= 128 * 1024 else { throw AppUpdateError.invalid("更新恢复记录文件无效：\(file.lastPathComponent)") }
            let record = try JSONDecoder().decode(AppInstallRecoveryRecord.self, from: Data(contentsOf: file))
            guard file.lastPathComponent == record.id.uuidString + ".json" else { throw AppUpdateError.invalid("更新恢复记录标识不匹配。") }
            records.append(record)
        }
        return records.sorted { $0.date > $1.date }
    }
}
