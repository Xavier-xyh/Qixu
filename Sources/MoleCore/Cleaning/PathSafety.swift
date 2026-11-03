import Foundation
import Darwin

public struct FileIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let fileType: UInt32
    public let size: Int64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public static func capture(_ url: URL) throws -> FileIdentity {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        return FileIdentity(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: UInt64(value.st_ino), fileType: UInt32(value.st_mode & S_IFMT), size: Int64(value.st_size), modificationSeconds: Int64(value.st_mtimespec.tv_sec), modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }
    public var isSymbolicLink: Bool { fileType == UInt32(S_IFLNK) }
}

public enum PathSafetyError: LocalizedError, Equatable {
    case invalidPath, protectedPath, outsideScope, symbolicLink, changedSinceScan, destinationExists, notInTrash, runningApplication(String), missingJournal
    public var errorDescription: String? {
        switch self {
        case .invalidPath: return "路径包含无效组件或控制字符。"
        case .protectedPath: return "该路径受保护，不能移入废纸篓。"
        case .outsideScope: return "项目不在本次明确选择的目录范围内。"
        case .symbolicLink: return "路径包含符号链接，请在 Finder 中确认真实位置。"
        case .changedSinceScan: return "文件身份自扫描后已改变，请重新扫描。"
        case .destinationExists: return "原位置已存在同名项目，恢复不会覆盖它。"
        case .notInTrash: return "恢复记录的项目不在用户废纸篓中。"
        case .runningApplication(let name): return "应用仍在运行：\(name)，请先退出。"
        case .missingJournal: return "找不到尚可恢复的操作记录。"
        }
    }
}

public enum PathSafety {
    public static func contains(_ child: URL, in root: URL, includeRoot: Bool = false) -> Bool {
        let c = child.standardizedFileURL.path, r = root.standardizedFileURL.path
        return (includeRoot && c == r) || c.hasPrefix(r == "/" ? "/" : r + "/")
    }

    public static func validate(_ url: URL, allowedRoot: URL, expectedIdentity: FileIdentity? = nil) throws {
        try validateDestination(url, allowedRoot: allowedRoot)
        let normalized = url.standardizedFileURL
        try rejectSymbolicLinks(in: normalized)
        let identity = try FileIdentity.capture(normalized)
        guard !identity.isSymbolicLink else { throw PathSafetyError.symbolicLink }
        if let expectedIdentity, identity != expectedIdentity { throw PathSafetyError.changedSinceScan }
    }

    public static func validateDestination(_ url: URL, allowedRoot: URL) throws {
        let raw = url.path
        guard url.isFileURL, raw.hasPrefix("/"), !raw.isEmpty,
              !raw.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw PathSafetyError.invalidPath }
        let normalized = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let protectedExact = ["/", "/Applications", "/Library", "/Users", "/private", "/Volumes", home.path,
                              home.appendingPathComponent("Library").path, home.appendingPathComponent("Applications").path,
                              home.appendingPathComponent("Library/Caches").path, home.appendingPathComponent("Library/Logs").path,
                              home.appendingPathComponent("Library/Application Support").path,
                              home.appendingPathComponent("Library/Containers").path,
                              home.appendingPathComponent("Library/Group Containers").path,
                              home.appendingPathComponent(".Trash").path]
        let protectedTrees = ["/System", "/bin", "/sbin", "/usr", "/etc", "/Library/Extensions"]
        guard !protectedExact.contains(normalized.path), !protectedTrees.contains(where: { normalized.path == $0 || normalized.path.hasPrefix($0 + "/") }), !contains(normalized, in: home.appendingPathComponent(".Trash"), includeRoot: true) else { throw PathSafetyError.protectedPath }
        guard contains(normalized, in: allowedRoot) else { throw PathSafetyError.outsideScope }
        try rejectSymbolicLinks(in: normalized.deletingLastPathComponent())
    }

    public static func rejectSymbolicLinks(in url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var value = stat()
            if lstat(current.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFLNK { throw PathSafetyError.symbolicLink }
        }
    }
}

public struct BoundedFileSize: Sendable {
    public let bytes: Int64
    public let incomplete: Bool
    public let unreadableCount: Int
}

/// A shared bounded walker for review screens. Links are never followed.
public enum ReviewFileSizer {
    public static func measure(_ url: URL, budget: TimeInterval = 0.4, maximumEntries: Int = 100_000) throws -> BoundedFileSize {
        let start = ProcessInfo.processInfo.systemUptime
        var root = stat()
        guard lstat(url.path, &root) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        if root.st_mode & S_IFMT == S_IFLNK { return BoundedFileSize(bytes: 0, incomplete: false, unreadableCount: 0) }
        if root.st_mode & S_IFMT != S_IFDIR { return BoundedFileSize(bytes: allocation(root), incomplete: false, unreadableCount: 0) }
        var total: Int64 = 0, visited = 0, errors = 0
        var seen = Set<String>()
        guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in errors += 1; return true }) else {
            return BoundedFileSize(bytes: 0, incomplete: true, unreadableCount: 1)
        }
        while let child = iterator.nextObject() as? URL {
            try Task.checkCancellation()
            visited += 1
            if visited > maximumEntries || ProcessInfo.processInfo.systemUptime - start > budget { return BoundedFileSize(bytes: total, incomplete: true, unreadableCount: errors) }
            var value = stat()
            guard lstat(child.path, &value) == 0 else { errors += 1; continue }
            if value.st_mode & S_IFMT == S_IFLNK { iterator.skipDescendants(); continue }
            if value.st_dev != root.st_dev { iterator.skipDescendants(); continue }
            if value.st_mode & S_IFMT == S_IFREG {
                let key = "\(value.st_dev):\(value.st_ino)"
                if seen.insert(key).inserted {
                    let sum = total.addingReportingOverflow(allocation(value)); total = sum.overflow ? Int64.max : sum.partialValue
                }
            }
        }
        return BoundedFileSize(bytes: max(total, 0), incomplete: errors > 0, unreadableCount: errors)
    }
    private static func allocation(_ value: stat) -> Int64 {
        let allocated = max(Int64(value.st_blocks) * 512, 0), logical = max(Int64(value.st_size), 0)
        let bounded = min(logical, allocated)
        return bounded > 0 ? bounded : allocated
    }
}
