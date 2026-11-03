import Foundation

public enum DiskSizeStatus: String, Codable, Sendable, CaseIterable {
    case sized, estimated, incomplete, partial
    public var label: String {
        switch self { case .sized: return "已计算"; case .estimated: return "估算"; case .incomplete: return "待补算"; case .partial: return "部分结果" }
    }
}

public struct DiskEntry: Identifiable, Codable, Hashable, Sendable {
    public var url: URL
    public var name: String
    public var size: Int64
    public var isDirectory: Bool
    public var sizeStatus: DiskSizeStatus
    public var modifiedAt: Date?
    public var issueCount: Int
    public var identityDevice: UInt64?
    public var identityInode: UInt64?
    public var scanIdentity: FileIdentity?
    public var id: String { url.standardizedFileURL.path }
    public init(url: URL, name: String? = nil, size: Int64, isDirectory: Bool, sizeStatus: DiskSizeStatus = .sized, modifiedAt: Date? = nil, issueCount: Int = 0, identityDevice: UInt64? = nil, identityInode: UInt64? = nil, scanIdentity: FileIdentity? = nil) {
        self.url = url.standardizedFileURL; self.name = name ?? url.lastPathComponent
        self.size = max(0, size); self.isDirectory = isDirectory; self.sizeStatus = sizeStatus
        self.modifiedAt = modifiedAt; self.issueCount = issueCount
        self.identityDevice = identityDevice; self.identityInode = identityInode
        self.scanIdentity = scanIdentity
    }
    public var formattedSize: String {
        let value = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        switch sizeStatus { case .estimated: return "约 \(value)"; case .incomplete: return size > 0 ? "≥ \(value)" : "待补算"; case .partial: return "≥ \(value)"; case .sized: return value }
    }
}

public struct DiskScanResult: Codable, Sendable {
    public var url: URL
    public var entries: [DiskEntry]
    public var scannedAt: Date
    public var skippedCount: Int
    public var issueCount: Int
    public init(url: URL, entries: [DiskEntry], scannedAt: Date = Date(), skippedCount: Int = 0, issueCount: Int = 0) {
        self.url = url.standardizedFileURL; self.entries = entries; self.scannedAt = scannedAt
        self.skippedCount = skippedCount; self.issueCount = issueCount
    }
    public var totalSize: Int64 { entries.reduce(0) { sum, entry in let (value, overflow) = sum.addingReportingOverflow(entry.size); return overflow ? Int64.max : value } }
    public var incompleteCount: Int { entries.filter { $0.sizeStatus == .incomplete }.count }
    public var isComplete: Bool { entries.allSatisfy { $0.sizeStatus == .sized } && issueCount == 0 }
}

public struct DirectorySizeProbe: Sendable {
    public var bytes: Int64
    public var timedOut: Bool
    public var issueCount: Int
    public var visitedFiles: Int
}

public struct DiskScanOptions: Sendable, Codable, Equatable {
    public var directoryBudget: TimeInterval
    public var showHidden: Bool
    public var excludedPaths: Set<String>
    public var stayOnVolume: Bool
    public init(directoryBudget: TimeInterval = 0.25, showHidden: Bool = false, excludedPaths: Set<String> = [], stayOnVolume: Bool = true) {
        self.directoryBudget = directoryBudget.isFinite ? min(86_400, max(0, directoryBudget)) : 0.25; self.showHidden = showHidden
        self.excludedPaths = Set(excludedPaths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).standardizedFileURL.path }); self.stayOnVolume = stayOnVolume
    }
}

public struct DiskCacheHit: Sendable {
    public let result: DiskScanResult
    public let isFresh: Bool
    public init(result: DiskScanResult, isFresh: Bool) { self.result = result; self.isFresh = isFresh }
}

public enum DiskScanError: LocalizedError {
    case notDirectory, symbolicLink, unreadable(String)
    public var errorDescription: String? {
        switch self { case .notDirectory: return "所选路径不是文件夹。"; case .symbolicLink: return "请选择文件夹本身，而不是符号链接。"; case .unreadable(let message): return "无法读取文件夹：\(message)" }
    }
}
