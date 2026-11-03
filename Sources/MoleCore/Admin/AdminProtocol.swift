import Foundation
import Darwin

public enum AdminOperation: String, Codable, Sendable {
    case quarantine, restoreQuarantine, history, inspectSystem, hardwareLease, recoverHardware, hardwareCapabilities, refreshNetwork, setServiceDNS, restoreServiceDNS
}
public struct AdminRequest: Codable, Sendable {
    public var version = 1
    public let operation: AdminOperation
    public let client: AdminProcessIdentity
    public var uninstall: SystemUninstallPlan?
    public var recordID: UUID?
    public var hardware: HardwareLeaseRequest?
    public var dnsInput: String?
    public var network: NetworkRefreshTarget?
    public var reloadServices: Bool? = false
    public init(operation: AdminOperation, uninstall: SystemUninstallPlan? = nil, recordID: UUID? = nil, hardware: HardwareLeaseRequest? = nil, reloadServices: Bool = false, network: NetworkRefreshTarget? = nil) throws {
        self.operation = operation; self.uninstall = uninstall; self.recordID = recordID; self.hardware = hardware
        client = try AdminProcessIdentity.capture(ProcessInfo.processInfo.processIdentifier)
        self.reloadServices = reloadServices
        self.network = network
    }
}
public struct AdminProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let uid: UInt32
    public let start: UInt64
    public static func capture(_ pid: Int32) throws -> AdminProcessIdentity {
        var info = proc_bsdinfo(); let count = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, count) == count else { throw AdminError.invalid("无法核对请求进程身份。") }
        return AdminProcessIdentity(pid: pid, uid: info.pbi_uid, start: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec)
    }
    public var isAlive: Bool { (try? Self.capture(pid)) == self }
}
public struct AdminResponse: Codable, Sendable {
    public var succeeded: Bool
    public var detail: String
    public var records: [SystemUninstallRecord] = []
    public var hardware: HardwareLeaseRecord?
    public var capabilities: HardwareCapabilities?
    public var plan: SystemUninstallPlan?
    public init(succeeded: Bool, detail: String) { self.succeeded = succeeded; self.detail = detail }
}
public enum AdminError: LocalizedError {
    case invalid(String), unavailable(String), failed(String)
    public var errorDescription: String? { switch self { case .invalid(let s), .unavailable(let s), .failed(let s): return s } }
}

/// Fixed, root-owned storage. Never follows user-supplied journal paths.
struct AdminStorage {
    static let root = URL(fileURLWithPath: "/Library/Application Support/MoleRebuild/Admin", isDirectory: true)
    var root: URL = Self.root
    var requiredOwner: uid_t = 0
    func prepare() throws {
        try PathSafety.rejectSymbolicLinks(in: root)
        let fm = FileManager.default
        // A pre-existing user-owned directory is never promoted to trusted storage.
        var current = root
        while current.path != "/" {
            var st = stat()
            if lstat(current.path, &st) == 0 {
                guard st.st_mode & S_IFMT == S_IFDIR, st.st_uid == requiredOwner || (current != root && st.st_uid == 0), st.st_mode & 0o022 == 0 else { throw AdminError.invalid("管理员存储的现有目录不可信：\(current.path)") }
            }
            current.deleteLastPathComponent()
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validate(root, directory: true)
        for directory in [root, root.deletingLastPathComponent(), root.deletingLastPathComponent().deletingLastPathComponent()] { try syncDirectory(directory) }
    }
    func validate(_ url: URL, directory: Bool = false) throws {
        try PathSafety.rejectSymbolicLinks(in: url)
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_uid == requiredOwner, st.st_mode & 0o022 == 0,
              st.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), directory || st.st_nlink == 1 else { throw AdminError.invalid("管理员文件身份或权限无效。") }
    }
    func write<T: Encodable>(_ value: T, to file: URL) throws {
        guard file.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else { throw AdminError.invalid("记录路径不在管理员存储内。") }
        try prepare()
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1024 * 1024 else { throw AdminError.invalid("管理员记录超出大小限制。") }
        let temporary = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AdminError.failed("无法建立持久操作记录。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, file.path) == 0 else { throw AdminError.failed("无法提交管理员记录。") }
        try syncDirectory(root)
    }
    func read<T: Decodable>(_ type: T.Type, file: URL) throws -> T {
        guard file.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else { throw AdminError.invalid("记录路径无效。") }
        try validate(file)
        let identity = try FileIdentity.capture(file)
        guard (1...1_048_576).contains(identity.size) else { throw AdminError.invalid("管理员记录大小无效。") }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }
    func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw AdminError.failed("无法同步操作目录。") }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw AdminError.failed("操作目录同步失败，请核对记录。") }
    }
}
