import Foundation
import AppKit

public enum CleaningCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case applications = "应用缓存", browsers = "浏览器缓存", developer = "开发工具", logs = "日志"
    public var id: String { rawValue }
    public var symbol: String {
        switch self { case .applications: return "square.stack.3d.up"; case .browsers: return "globe"; case .developer: return "hammer"; case .logs: return "doc.text" }
    }
}
public enum CandidateSafety: String, Codable, Sendable { case autoClean = "可推荐", reviewOnly = "需复核", blocked = "受保护" }
public enum CandidateAvailability: String, Codable, Sendable { case immediate = "可处理", blockedByRunningApp = "使用中", blockedBySystem = "不可处理" }

public struct CleaningCandidate: Identifiable, Sendable {
    public let url: URL
    public let allowedRoot: URL
    public let category: CleaningCategory
    public let size: Int64
    public let isSizeIncomplete: Bool
    public let modifiedAt: Date?
    public let safety: CandidateSafety
    public let availability: CandidateAvailability
    public let reason: String
    public let ownerBundleID: String?
    public let identity: FileIdentity
    public var id: String { url.path }
    public var isSelectedByDefault: Bool { safety == .autoClean && availability == .immediate }
    public var request: TrashRequest { TrashRequest(url: url, allowedRoot: allowedRoot, ownerBundleID: ownerBundleID, expectedIdentity: identity) }
}
public struct CleaningScan: Sendable {
    public let items: [CleaningCandidate]
    public let issues: [String]
    public let date: Date
}

public enum ProcessUsageDetector {
    public static func buildToolIsRunning() -> Bool {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let names = String(decoding: data.prefix(2_000_000), as: UTF8.self).lowercased()
            return ["/xcodebuild", "/xctest", "/xctrunner", "/swift-frontend", "/xcbuildservice"].contains(where: names.contains)
        } catch { return true } // Unable to establish availability: keep build artifacts for review.
    }
}

public struct CleaningScanner: Sendable {
    public var totalBudget: TimeInterval
    public var perItemBudget: TimeInterval
    public init(totalBudget: TimeInterval = 60, perItemBudget: TimeInterval = 0.35) { self.totalBudget = totalBudget; self.perItemBudget = perItemBudget }
    public func scan(categories: Set<CleaningCategory> = Set(CleaningCategory.allCases), excludedPaths: [URL] = [], progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> CleaningScan {
        let runningIDs = await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
        let worker = Task.detached(priority: .utility) { try perform(categories: categories, runningIDs: runningIDs, excluded: excludedPaths, progress: progress) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    private func perform(categories: Set<CleaningCategory>, runningIDs: Set<String>, excluded: [URL], progress: @Sendable (String) -> Void) throws -> CleaningScan {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        struct Root { let url: URL; let category: CleaningCategory; let owner: String?; let children: Bool }
        var roots = [Root]()
        if categories.contains(.browsers) {
            let browsers: [(String, String)] = [("Google/Chrome", "com.google.Chrome"), ("Microsoft Edge", "com.microsoft.edgemac"), ("com.apple.Safari", "com.apple.Safari"), ("Firefox", "org.mozilla.firefox"), ("BraveSoftware", "com.brave.Browser"), ("company.thebrowser.Browser", "company.thebrowser.Browser")]
            roots += browsers.map { Root(url: home.appendingPathComponent("Library/Caches/" + $0.0), category: .browsers, owner: $0.1, children: false) }
        }
        if categories.contains(.applications) { roots.append(Root(url: home.appendingPathComponent("Library/Caches"), category: .applications, owner: nil, children: true)) }
        if categories.contains(.developer) {
            roots += ["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives", "Library/Caches/org.swift.swiftpm", ".npm/_cacache", ".gradle/caches", "Library/Caches/Homebrew"].map { Root(url: home.appendingPathComponent($0), category: .developer, owner: nil, children: true) }
        }
        if categories.contains(.logs) { roots.append(Root(url: home.appendingPathComponent("Library/Logs"), category: .logs, owner: nil, children: true)) }
        let ignoredCacheNames = Set(["Google", "Microsoft Edge", "com.apple.Safari", "Firefox", "BraveSoftware", "company.thebrowser.Browser", "org.swift.swiftpm", "Homebrew", RebuildPaths.bundleIdentifier])
        let buildBusy = categories.contains(.developer) ? ProcessUsageDetector.buildToolIsRunning() : false
        let started = ProcessInfo.processInfo.systemUptime
        var items = [CleaningCandidate](), issues = [String](), seen = Set<String>()
        outer: for root in roots {
            try Task.checkCancellation()
            guard fm.fileExists(atPath: root.url.path) else { continue }
            progress(root.category.rawValue + " · " + root.url.lastPathComponent)
            do { try PathSafety.rejectSymbolicLinks(in: root.url) } catch { issues.append(root.url.path + "：" + error.localizedDescription); continue }
            let children: [URL]
            do { children = root.children ? try fm.contentsOfDirectory(at: root.url, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey], options: []) : [root.url] }
            catch { issues.append(root.url.path + "：" + error.localizedDescription); continue }
            for url in children {
                try Task.checkCancellation()
                if ProcessInfo.processInfo.systemUptime - started > totalBudget { issues.append("已达到本轮时间预算；当前列表不是全部项目。可缩小分类后重新扫描。"); break outer }
                if root.category == .applications && ignoredCacheNames.contains(url.lastPathComponent) { continue }
                if root.category == .developer && root.url.lastPathComponent == "Archives" { /* Archives retain review-only classification below. */ }
                if excluded.contains(where: { PathSafety.contains(url, in: $0, includeRoot: true) }) { continue }
                if !seen.insert(url.standardizedFileURL.path).inserted { continue }
                do {
                    let identity = try FileIdentity.capture(url)
                    let allowed = root.children ? root.url : root.url.deletingLastPathComponent()
                    try PathSafety.validate(url, allowedRoot: allowed, expectedIdentity: identity)
                    let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    let modified = attributes?.contentModificationDate
                    let olderThanWeek = modified.map { Date().timeIntervalSince($0) >= 7 * 86400 } ?? false
                    let measured = try ReviewFileSizer.measure(url, budget: perItemBudget)
                    let owner = root.owner ?? (url.lastPathComponent.contains(".") ? url.lastPathComponent : nil)
                    let running = owner.map(runningIDs.contains) ?? false
                    let busy = running || (root.category == .developer && buildBusy)
                    let recommended = olderThanWeek && !measured.incomplete && root.category != .developer && !(owner?.hasPrefix("com.apple.") ?? false)
                    let reason: String
                    if busy { reason = running ? "关联应用正在运行，执行时会再次复核。" : "发现 Xcode/Swift 构建工具，保留开发产物。" }
                    else if measured.incomplete { reason = "大小为已读取部分；权限或时间预算导致统计未完成。" }
                    else if root.category == .developer { reason = "构建缓存或归档，重建可能耗时；归档可能用于分发，需自行复核。" }
                    else if olderThanWeek { reason = "修改时间超过 7 天；仅推荐缓存和日志，执行时仍复核身份。" }
                    else { reason = "近期修改或修改时间未知，需自行复核。" }
                    items.append(CleaningCandidate(url: url, allowedRoot: allowed, category: root.category, size: measured.bytes, isSizeIncomplete: measured.incomplete, modifiedAt: modified, safety: recommended ? .autoClean : .reviewOnly, availability: busy ? .blockedByRunningApp : .immediate, reason: reason, ownerBundleID: owner, identity: identity))
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append(url.path + "：" + error.localizedDescription) }
            }
        }
        return CleaningScan(items: items.sorted { $0.size > $1.size }, issues: issues, date: Date())
    }
}
