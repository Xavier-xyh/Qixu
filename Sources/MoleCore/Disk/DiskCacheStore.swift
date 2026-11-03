import Foundation
import Darwin

public actor DiskCacheStore {
    private struct Record: Codable { var schemaVersion: Int; var path: String; var timestamp: Date; var modificationDate: Date?; var options: DiskScanOptions; var result: DiskScanResult }
    private let directory: URL
    public init(directory: URL = RebuildPaths.caches.appendingPathComponent("analyze", isDirectory: true)) { self.directory = directory }
    public static func key(for url: URL) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.standardizedFileURL.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%016llx.json", hash)
    }
    public func load(_ url: URL, options: DiskScanOptions = DiskScanOptions(), now: Date = Date()) -> DiskCacheHit? {
        let path = url.standardizedFileURL
        let file = directory.appendingPathComponent(Self.key(for: path))
        guard safeDirectory(), let values = try? path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]), values.isDirectory == true, values.isSymbolicLink != true,
              let identity = try? FileIdentity.capture(file), identity.fileType == UInt32(S_IFREG), identity.size <= 20 * 1024 * 1024,
              let data = try? Data(contentsOf: file),
              let record = try? JSONDecoder().decode(Record.self, from: data), record.schemaVersion == 1, record.path == path.path, record.options == options,
              record.result.url.standardizedFileURL == path,
              record.result.entries.allSatisfy({ $0.url.isFileURL && $0.size >= 0 && $0.issueCount >= 0 && $0.url.deletingLastPathComponent().standardizedFileURL == path }) else { return nil }
        let age = now.timeIntervalSince(record.timestamp)
        guard age >= 0 && age < 14 * 86_400 else { return nil }
        let mtimeMatches: Bool
        if let before = record.modificationDate, let after = values.contentModificationDate { mtimeMatches = abs(after.timeIntervalSince(before)) < 1 }
        else { mtimeMatches = true }
        return DiskCacheHit(result: record.result, isFresh: age < 6 * 3600 && mtimeMatches)
    }
    public func save(_ result: DiskScanResult, options: DiskScanOptions = DiskScanOptions(), now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard safeDirectory() else { throw CocoaError(.fileWriteNoPermission) }
        let path = result.url.standardizedFileURL
        let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
        guard values.isDirectory == true && values.isSymbolicLink != true else { return }
        var persisted = result
        for i in persisted.entries.indices where persisted.entries[i].sizeStatus == .estimated || persisted.entries[i].sizeStatus == .partial { persisted.entries[i].sizeStatus = .incomplete }
        let record = Record(schemaVersion: 1, path: path.path, timestamp: now, modificationDate: values.contentModificationDate, options: options, result: persisted)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(Self.key(for: path)), options: .atomic)
        try trim()
    }
    public func clear() throws {
        guard safeDirectory() else { return }
        for url in try cacheFiles() { try FileManager.default.removeItem(at: url) }
    }
    private func safeDirectory() -> Bool {
        guard let value = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return value.isDirectory == true && value.isSymbolicLink != true && directory.resolvingSymlinksInPath() == directory.standardizedFileURL
    }
    private func cacheFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]).filter {
            guard $0.pathExtension == "json", let v = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return v.isRegularFile == true && v.isSymbolicLink != true
        }
    }
    private func trim() throws {
        var files = try cacheFiles().compactMap { url -> (URL, Date, Int)? in
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
            return (url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var total = files.reduce(0) { $0 + $1.2 }
        while files.count > 100 || total > 20 * 1024 * 1024 {
            guard !files.isEmpty else { break }
            let item = files.removeFirst(); try FileManager.default.removeItem(at: item.0); total -= item.2
        }
    }
}
