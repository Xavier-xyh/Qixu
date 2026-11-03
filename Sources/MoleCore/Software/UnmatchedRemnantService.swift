import Foundation
import AppKit

public struct UnmatchedRemnant: Identifiable, Sendable {
    public let url: URL
    public let allowedRoot: URL
    public let identifier: String
    public let kind: String
    public let size: Int64
    public let isSizeIncomplete: Bool
    public let identity: FileIdentity
    public var id: String { url.path }
}

public struct UnmatchedRemnantScan: Sendable {
    public let items: [UnmatchedRemnant]
    public let issues: [String]
}

public enum UnmatchedRemnantMatcher {
    /// Deliberately narrow: filenames are evidence of an identifier, not proof of abandonment.
    public static func identifier(filename: String, preferences: Bool = false) -> String? {
        var value = filename
        if preferences {
            guard value.hasSuffix(".plist") else { return nil }
            value.removeLast(6)
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, labels.count <= 12, value.utf8.count <= 255,
              labels.allSatisfy({ label in
                  guard let first = label.utf8.first, (65...90).contains(first) || (97...122).contains(first), label.utf8.count <= 63 else { return false }
                  return label.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }) else { return nil }
        let lower = value.lowercased()
        guard lower != "com.apple", !lower.hasPrefix("com.apple."),
              !overlaps(value, identifier: RebuildPaths.bundleIdentifier) else { return nil }
        return value
    }
    public static func overlaps(_ candidate: String, identifier: String) -> Bool {
        RemnantMatcher.matchesIdentifier(candidate, bundleID: identifier) || RemnantMatcher.matchesIdentifier(identifier, bundleID: candidate)
    }
    public static func isUnmatched(_ candidate: String, installedIDs: [String]) -> Bool {
        !installedIDs.contains { !$0.isEmpty && overlaps(candidate, identifier: $0) }
    }
}

struct ApplicationIdentitySnapshot: Sendable {
    var applications: [(url: URL, id: String, name: String, componentIDs: Set<String>)] = []
    var ids: [String] { applications.map(\.id) + applications.flatMap(\.componentIDs) }
    var issues = [String]()
    var isComplete: Bool { issues.isEmpty }
}

public struct UnmatchedRemnantService: Sendable {
    public static let additionalApplicationPathsKey = "additionalApplicationDiscoveryPaths"

    private let home: URL
    private let discoveryRoots: [URL]?
    private let trash: TrashService

    public init() {
        home = FileManager.default.homeDirectoryForCurrentUser
        discoveryRoots = nil
        trash = .shared
    }

    init(home: URL, discoveryRoots: [URL], trash: TrashService) {
        self.home = home
        self.discoveryRoots = discoveryRoots
        self.trash = trash
    }
    private static func roots() -> [(relative: String, kind: String, preferences: Bool)] {
        [("Library/Caches", "缓存", false), ("Library/Preferences", "偏好设置", true), ("Library/Logs", "日志", false)]
    }
    @MainActor static func runningIdentities() -> (urls: [URL], ids: [String]) {
        let applications = NSWorkspace.shared.runningApplications
        return (applications.compactMap(\.bundleURL), applications.compactMap(\.bundleIdentifier))
    }

    static func applicationIdentities(runningURLs: [URL] = [], discoveryRoots: [URL]? = nil) throws -> ApplicationIdentitySnapshot {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let standardRoots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications"),
                             URL(fileURLWithPath: "/System/Applications")]
        let volumes = (fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path.hasPrefix("/Volumes/") && (try? $0.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true }
        let extraRoots = [home.appendingPathComponent("Downloads"), home.appendingPathComponent("Desktop")] + volumes
        let configuredRoots = (UserDefaults.standard.stringArray(forKey: additionalApplicationPathsKey) ?? [])
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
        let roots = discoveryRoots ?? standardRoots + configuredRoots + extraRoots
        var result = ApplicationIdentitySnapshot()
        var seen = Set<String>()
        func record(_ url: URL, required: Bool) {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(canonical.path).inserted else { return }
            guard let bundle = Bundle(url: canonical), let id = bundle.bundleIdentifier, !id.isEmpty else {
                if required { result.issues.append("无法确定应用标识符：" + url.path) }
                return
            }
            let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String) ??
                (bundle.infoDictionary?["CFBundleName"] as? String) ?? canonical.deletingPathExtension().lastPathComponent
            let components = SoftwareService.embeddedBundleIdentifiers(at: canonical)
            result.applications.append((canonical, id, name, components))
        }
        let began = ProcessInfo.processInfo.systemUptime
        var scannedRoots = Set<String>()
        for root in roots where scannedRoots.insert(root.path).inserted {
            let configured = discoveryRoots?.contains(root) ?? configuredRoots.contains(root)
            guard fm.fileExists(atPath: root.path) else {
                if configured {
                    result.issues.append("无法访问自定义应用目录 \(root.path)。请重新连接磁盘、检查访问权限，或在应用目录菜单中更新核对范围。")
                }
                continue
            }
            let required = configured || standardRoots.contains(root)
            try PathSafety.rejectSymbolicLinks(in: root)
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { url, error in result.issues.append(url.path + "：" + error.localizedDescription); return true }) else { result.issues.append("无法枚举 " + root.path); continue }
            while let url = iterator.nextObject() as? URL {
                try Task.checkCancellation()
                if ProcessInfo.processInfo.systemUptime - began > 20 { result.issues.append("应用身份核对达到时间预算。"); return result }
                // Bundle metadata for application aliases is read, but links are never traversed.
                let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
                if url.pathExtension.lowercased() == "app" {
                    iterator.skipDescendants()
                    record(url, required: required)
                } else if isLink || iterator.level >= (configured ? 8 : required ? 3 : 4) { iterator.skipDescendants() }
            }
        }
        for url in runningURLs where url.pathExtension.lowercased() == "app" {
            try Task.checkCancellation()
            if ProcessInfo.processInfo.systemUptime - began > 20 {
                result.issues.append("运行中应用的身份核对达到时间预算。")
                break
            }
            record(url, required: false)
        }
        return result
    }
    public func scan(excludedPaths: [URL] = [], progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> UnmatchedRemnantScan {
        let running = await Self.runningIdentities()
        let worker = Task.detached(priority: .utility) {
            progress("重新核对已安装应用")
            let inventory = try Self.applicationIdentities(runningURLs: running.urls, discoveryRoots: discoveryRoots)
            guard inventory.isComplete else { return UnmatchedRemnantScan(items: [], issues: ["应用身份清单不完整，暂不提供未匹配候选。"] + inventory.issues) }
            let ids = inventory.ids + running.ids
            let fm = FileManager.default
            var items = [UnmatchedRemnant](), issues = [String]()
            let began = ProcessInfo.processInfo.systemUptime
            for rootInfo in Self.roots() {
                let root = home.appendingPathComponent(rootInfo.relative)
                guard fm.fileExists(atPath: root.path) else { continue }
                progress(rootInfo.kind)
                let children: [URL]
                do { try PathSafety.rejectSymbolicLinks(in: root); children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
                catch { issues.append(root.path + "：" + error.localizedDescription); continue }
                for url in children {
                    try Task.checkCancellation()
                    if ProcessInfo.processInfo.systemUptime - began > 60 { issues.append("达到 60 秒扫描预算，结果不完整。"); return UnmatchedRemnantScan(items: items, issues: issues) }
                    guard let id = UnmatchedRemnantMatcher.identifier(filename: url.lastPathComponent, preferences: rootInfo.preferences),
                          UnmatchedRemnantMatcher.isUnmatched(id, installedIDs: ids),
                          !excludedPaths.contains(where: { PathSafety.contains(url, in: $0, includeRoot: true) }) else { continue }
                    do {
                        let identity = try FileIdentity.capture(url)
                        try PathSafety.validate(url, allowedRoot: root, expectedIdentity: identity)
                        let size = try ReviewFileSizer.measure(url, budget: 0.2, maximumEntries: 30_000)
                        items.append(UnmatchedRemnant(url: url, allowedRoot: root, identifier: id, kind: rootInfo.kind, size: size.bytes, isSizeIncomplete: size.incomplete, identity: identity))
                    } catch is CancellationError { throw CancellationError() }
                    catch { issues.append(url.path + "：" + error.localizedDescription) }
                }
            }
            return UnmatchedRemnantScan(items: items.sorted { $0.size > $1.size }, issues: issues)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    public func moveReviewedToTrash(_ items: [UnmatchedRemnant]) async -> [TrashOperationResult] {
        let validRoots = Set(Self.roots().map { home.appendingPathComponent($0.relative).standardizedFileURL })
        var outcomes = [TrashOperationResult]()
        var ownerIDs: [String] = []
        var verifiedAt = -Double.infinity
        var remainingChecks = 0

        for (index, item) in items.enumerated() {
            if Task.isCancelled { break }
            do {
                let root = item.allowedRoot.standardizedFileURL
                guard validRoots.contains(root), item.url.deletingLastPathComponent().standardizedFileURL == root else {
                    throw PathSafetyError.outsideScope
                }
                try PathSafety.validate(item.url, allowedRoot: root, expectedIdentity: item.identity)

                // Use a fresh inventory for each operation, with short refresh intervals for batches.
                if remainingChecks == 0 || ProcessInfo.processInfo.systemUptime - verifiedAt >= 2 {
                    let running = await Self.runningIdentities()
                    let startedAt = ProcessInfo.processInfo.systemUptime
                    let worker = Task.detached(priority: .utility) {
                        try Self.applicationIdentities(runningURLs: running.urls, discoveryRoots: discoveryRoots)
                    }
                    let inventory = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard inventory.isComplete else {
                        let detail = "无法完整核对应用清单。\n" + inventory.issues.joined(separator: "\n")
                        outcomes.append(contentsOf: items[index...].map {
                            TrashOperationResult(url: $0.url, trashURL: nil, error: detail)
                        })
                        break
                    }
                    ownerIDs = inventory.ids + running.ids
                    verifiedAt = startedAt
                    remainingChecks = 8
                }
                remainingChecks -= 1
                let currentRunning = await Self.runningIdentities()
                guard UnmatchedRemnantMatcher.isUnmatched(item.identifier, installedIDs: ownerIDs + currentRunning.ids) else {
                    throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "现已匹配已安装或运行中的应用，请重新扫描。"])
                }
                let request = TrashRequest(url: item.url, allowedRoot: root, ownerBundleID: item.identifier, expectedIdentity: item.identity)
                let results = await trash.moveToTrash([request])
                guard !results.isEmpty else { break }
                outcomes.append(contentsOf: results)
            } catch is CancellationError {
                break
            } catch {
                outcomes.append(TrashOperationResult(url: item.url, trashURL: nil, error: error.localizedDescription))
            }
        }
        return outcomes
    }
}
