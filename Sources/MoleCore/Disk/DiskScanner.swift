import Foundation
import Darwin

public struct DiskScanner: Sendable {
    public init() {}
    public func scan(_ url: URL, options: DiskScanOptions = DiskScanOptions(), progress: (@Sendable (String, Int, Int) -> Void)? = nil) async throws -> DiskScanResult {
        let worker = Task.detached(priority: .utility) { try Self.scanNow(url.standardizedFileURL, options: options, progress: progress) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    public func measure(_ url: URL, budget: TimeInterval = 8, options: DiskScanOptions = DiskScanOptions(), progress: (@Sendable (Int64) -> Void)? = nil) async throws -> DirectorySizeProbe {
        let worker = Task.detached(priority: .utility) {
            let info = try Self.info(url)
            guard info.st_mode & S_IFMT != S_IFLNK else { throw DiskScanError.symbolicLink }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw DiskScanError.notDirectory }
            return try Self.probe(url, budget: budget, options: options, device: info.st_dev, progress: progress)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private static func scanNow(_ url: URL, options: DiskScanOptions, progress: (@Sendable (String, Int, Int) -> Void)?) throws -> DiskScanResult {
        try Task.checkCancellation()
        let root = try info(url)
        guard root.st_mode & S_IFMT != S_IFLNK else { throw DiskScanError.symbolicLink }
        guard root.st_mode & S_IFMT == S_IFDIR else { throw DiskScanError.notDirectory }
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: options.showHidden ? [] : [.skipsHiddenFiles]) }
        catch { throw DiskScanError.unreadable(error.localizedDescription) }
        var entries: [DiskEntry] = []; var skipped = 0; var issues = 0
        for (index, child) in urls.enumerated() {
            try Task.checkCancellation()
            progress?(child.lastPathComponent, index, urls.count)
            if excluded(child, options: options) { skipped += 1; continue }
            do {
                let st = try info(child)
                let kind = st.st_mode & S_IFMT
                if kind == S_IFLNK { skipped += 1; continue }
                if options.stayOnVolume && st.st_dev != root.st_dev { skipped += 1; continue }
                let identity = try FileIdentity.capture(child)
                if kind == S_IFDIR {
                    let probe = try probe(child, budget: options.directoryBudget, options: options, device: root.st_dev, progress: nil)
                    let status: DiskSizeStatus = probe.timedOut ? .incomplete : (probe.issueCount > 0 ? .partial : .sized)
                    entries.append(DiskEntry(url: child, size: probe.bytes, isDirectory: true, sizeStatus: status, modifiedAt: modified(st), issueCount: probe.issueCount, identityDevice: identity.device, identityInode: identity.inode, scanIdentity: identity))
                    issues += probe.issueCount
                } else if kind == S_IFREG {
                    entries.append(DiskEntry(url: child, size: fileSize(st), isDirectory: false, modifiedAt: modified(st), identityDevice: identity.device, identityInode: identity.inode, scanIdentity: identity))
                } else { skipped += 1 }
            } catch is CancellationError { throw CancellationError() }
            catch { issues += 1; entries.append(DiskEntry(url: child, size: 0, isDirectory: false, sizeStatus: .partial, issueCount: 1)) }
        }
        progress?("", urls.count, urls.count)
        entries.sort { $0.size == $1.size ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.size > $1.size }
        return DiskScanResult(url: url, entries: entries, skippedCount: skipped, issueCount: issues)
    }
    private struct FileKey: Hashable { let device: dev_t; let inode: ino_t }
    private static func probe(_ root: URL, budget: TimeInterval, options: DiskScanOptions, device: dev_t, progress: (@Sendable (Int64) -> Void)?) throws -> DirectorySizeProbe {
        let clock = ContinuousClock(); let start = clock.now
        let boundedBudget = budget.isFinite ? min(86_400, max(0, budget)) : 8
        let deadline = start.advanced(by: .seconds(boundedBudget))
        var stack = [root]; var seen = Set<FileKey>(); var bytes: Int64 = 0; var issues = 0; var visited = 0
        var lastProgress = start
        while let directory = stack.popLast() {
            try Task.checkCancellation()
            if clock.now >= deadline { return DirectorySizeProbe(bytes: bytes, timedOut: true, issueCount: issues, visitedFiles: visited) }
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: options.showHidden ? [] : [.skipsHiddenFiles]) }
            catch { issues += 1; continue }
            for child in children {
                try Task.checkCancellation()
                if clock.now >= deadline { return DirectorySizeProbe(bytes: bytes, timedOut: true, issueCount: issues, visitedFiles: visited) }
                if excluded(child, options: options) { continue }
                do {
                    let st = try info(child); let kind = st.st_mode & S_IFMT
                    if kind == S_IFLNK || (options.stayOnVolume && st.st_dev != device) { continue }
                    if kind == S_IFDIR { stack.append(child) }
                    else if kind == S_IFREG {
                        if st.st_nlink > 1 && !seen.insert(FileKey(device: st.st_dev, inode: st.st_ino)).inserted { continue }
                        let (sum, overflow) = bytes.addingReportingOverflow(fileSize(st)); bytes = overflow ? Int64.max : sum
                        visited += 1
                    }
                } catch { issues += 1 }
                if lastProgress.duration(to: clock.now) >= .milliseconds(150) { progress?(bytes); lastProgress = clock.now }
            }
        }
        progress?(bytes)
        return DirectorySizeProbe(bytes: bytes, timedOut: false, issueCount: issues, visitedFiles: visited)
    }
    private static func info(_ url: URL) throws -> stat {
        var st = stat()
        let result = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in guard let pointer else { return -1 }; return Darwin.lstat(pointer, &st) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return st
    }
    public static func measuredFileSize(_ url: URL) throws -> Int64 { fileSize(try info(url)) }
    private static func fileSize(_ st: stat) -> Int64 {
        let (allocated, overflow) = Int64(max(0, st.st_blocks)).multipliedReportingOverflow(by: 512)
        let disk = overflow ? Int64.max : allocated
        let selected = min(max(0, Int64(st.st_size)), disk)
        return selected > 0 ? selected : disk
    }
    private static func modified(_ st: stat) -> Date { Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1_000_000_000) }
    private static func excluded(_ url: URL, options: DiskScanOptions) -> Bool {
        let path = url.standardizedFileURL.path
        return options.excludedPaths.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
