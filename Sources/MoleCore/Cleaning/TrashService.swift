import Foundation
import AppKit
import Darwin

public struct TrashRequest: Sendable {
    public let url: URL
    public let allowedRoot: URL
    public let ownerBundleID: String?
    public let expectedIdentity: FileIdentity?
    public init(url: URL, allowedRoot: URL, ownerBundleID: String? = nil, expectedIdentity: FileIdentity? = nil) {
        self.url = url; self.allowedRoot = allowedRoot; self.ownerBundleID = ownerBundleID; self.expectedIdentity = expectedIdentity
    }
}

public struct TrashOperationResult: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let trashURL: URL?
    public let error: String?
    public var succeeded: Bool { error == nil }
}

public struct TrashJournalEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let originalURL: URL
    public let trashURL: URL
    public let date: Date
    public var restoredAt: Date?
    public let identity: FileIdentity?
    public let allowedRoot: URL
}

public actor TrashService {
    public static let shared = TrashService()
    private let journalFile: URL
    public init(directory: URL = RebuildPaths.applicationSupport) { journalFile = directory.appendingPathComponent("trash-journal.json") }
    public func history() -> [TrashJournalEntry] {
        guard let data = try? Data(contentsOf: journalFile), let entries = try? JSONDecoder().decode([TrashJournalEntry].self, from: data) else { return [] }
        return entries
    }
    private func save(_ entries: [TrashJournalEntry]) throws {
        try FileManager.default.createDirectory(at: journalFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(entries.prefix(1000))).write(to: journalFile, options: .atomic)
    }
    public func moveToTrash(_ requests: [TrashRequest]) async -> [TrashOperationResult] {
        var results = [TrashOperationResult]()
        var entries = history()
        var handled = [URL]()
        for request in requests.sorted(by: { $0.url.pathComponents.count < $1.url.pathComponents.count }) {
            if Task.isCancelled { break }
            let url = request.url.standardizedFileURL
            do {
                guard !handled.contains(where: { PathSafety.contains(url, in: $0, includeRoot: true) }) else { continue }
                try PathSafety.validate(request.url, allowedRoot: request.allowedRoot, expectedIdentity: request.expectedIdentity)
                let validatedIdentity = try FileIdentity.capture(url)
                let exclusions = (UserDefaults.standard.stringArray(forKey: "cleaningExcludedPaths") ?? []).map { URL(fileURLWithPath: $0) }
                if exclusions.contains(where: { PathSafety.contains(url, in: $0, includeRoot: true) }) { throw PathSafetyError.protectedPath }
                if url.path.contains("/Library/Developer/Xcode/DerivedData/"), ProcessUsageDetector.buildToolIsRunning() { throw PathSafetyError.runningApplication("Xcode / Swift 构建工具") }
                let running = await MainActor.run { NSWorkspace.shared.runningApplications.compactMap { app -> (String, URL?)? in
                    guard let id = app.bundleIdentifier else { return nil }; return (id, app.bundleURL)
                } }
                if let owner = request.ownerBundleID, let app = running.first(where: { $0.0 == owner }) { throw PathSafetyError.runningApplication(app.0) }
                if let app = running.first(where: { pair in pair.1.map { PathSafety.contains($0, in: url, includeRoot: true) || PathSafety.contains(url, in: $0, includeRoot: true) } ?? false }) { throw PathSafetyError.runningApplication(app.0) }
                if let ownURL = Bundle.main.bundleURL as URL?, PathSafety.contains(ownURL, in: url, includeRoot: true) || PathSafety.contains(url, in: ownURL, includeRoot: true) { throw PathSafetyError.protectedPath }
                if url.pathExtension.lowercased() == "app", let id = Bundle(url: url)?.bundleIdentifier, id.hasPrefix("com.apple.") || id == RebuildPaths.bundleIdentifier { throw PathSafetyError.protectedPath }
                // A recoverable operation needs a writable journal before changing the file system.
                // MainActor checks above can suspend this actor, so merge the latest journal
                // and revalidate immediately before the synchronous file-system operation.
                entries = history()
                try save(entries)
                try Task.checkCancellation()
                try PathSafety.validate(request.url, allowedRoot: request.allowedRoot, expectedIdentity: request.expectedIdentity ?? validatedIdentity)
                var destination: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                guard let moved = destination as URL? else { throw CocoaError(.fileWriteUnknown) }
                let identity = try? FileIdentity.capture(moved)
                entries.insert(TrashJournalEntry(id: UUID(), originalURL: url, trashURL: moved, date: Date(), restoredAt: nil, identity: identity, allowedRoot: request.allowedRoot.standardizedFileURL), at: 0)
                do { try save(entries) } catch {
                    // Preserve a useful result even if journal persistence fails after the move.
                    results.append(TrashOperationResult(url: url, trashURL: moved, error: "项目已移入废纸篓，但恢复记录写入失败：\(error.localizedDescription)"))
                    await ActivityStore.shared.append(ActivityRecord(category: "文件操作", title: "恢复记录失败", detail: moved.path, succeeded: false))
                    handled.append(url); continue
                }
                handled.append(url)
                results.append(TrashOperationResult(url: url, trashURL: moved, error: nil))
                await ActivityStore.shared.append(ActivityRecord(category: "文件操作", title: "移入废纸篓", detail: url.path))
            } catch {
                results.append(TrashOperationResult(url: url, trashURL: nil, error: error.localizedDescription))
                await ActivityStore.shared.append(ActivityRecord(category: "文件操作", title: "未处理 \(url.lastPathComponent)", detail: error.localizedDescription, succeeded: false))
            }
        }
        return results
    }
    public func restore(_ entry: TrashJournalEntry) async throws {
        var entries = history()
        guard let index = entries.firstIndex(where: { $0.id == entry.id && $0.restoredAt == nil }), entries[index].trashURL == entry.trashURL else { throw PathSafetyError.missingJournal }
        let stored = entries[index]
        let homeTrash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        // FileManager may select an external volume's .Trashes/<uid>; validate its final ancestor as well.
        let path = stored.trashURL.standardizedFileURL.path
        let externalTrash = path.hasPrefix("/Volumes/") && path.contains("/.Trashes/\(getuid())/")
        guard PathSafety.contains(stored.trashURL, in: homeTrash) || externalTrash else { throw PathSafetyError.notInTrash }
        try PathSafety.rejectSymbolicLinks(in: stored.trashURL)
        if let identity = stored.identity, try FileIdentity.capture(stored.trashURL) != identity { throw PathSafetyError.changedSinceScan }
        try PathSafety.validateDestination(stored.originalURL, allowedRoot: stored.allowedRoot)
        guard !FileManager.default.fileExists(atPath: stored.originalURL.path) else { throw PathSafetyError.destinationExists }
        try PathSafety.rejectSymbolicLinks(in: stored.originalURL.deletingLastPathComponent())
        guard FileManager.default.fileExists(atPath: stored.originalURL.deletingLastPathComponent().path) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.moveItem(at: stored.trashURL, to: stored.originalURL)
        entries[index].restoredAt = Date()
        try save(entries)
        await ActivityStore.shared.append(ActivityRecord(category: "文件操作", title: "从废纸篓恢复", detail: stored.originalURL.path))
    }
}
