import Foundation
import Darwin
import AppKit
import Security

public struct InstalledApplication: Identifiable, Sendable {
    public let url: URL
    public let allowedRoot: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public let build: String
    public let teamID: String?
    public let size: Int64
    public let isSizeIncomplete: Bool
    public let modifiedAt: Date?
    public let identity: FileIdentity
    public let isRunning: Bool
    public var id: String { url.path }
    public var isProtected: Bool { bundleID.hasPrefix("com.apple.") || bundleID == RebuildPaths.bundleIdentifier || PathSafety.contains(url, in: URL(fileURLWithPath: "/System"), includeRoot: true) || PathSafety.contains(url, in: Bundle.main.bundleURL, includeRoot: true) }
}

public enum RemnantConfidence: String, Codable, Sendable { case strong = "强匹配", review = "需复核" }
public struct SoftwareRemnant: Identifiable, Sendable {
    public let url: URL
    public let allowedRoot: URL
    public let kind: String
    public let size: Int64
    public let isSizeIncomplete: Bool
    public let evidence: String
    public let confidence: RemnantConfidence
    public let identity: FileIdentity
    public var id: String { url.path }
    public var isSelectedByDefault: Bool { confidence == .strong }
    public func request(owner: String) -> TrashRequest { TrashRequest(url: url, allowedRoot: allowedRoot, ownerBundleID: owner, expectedIdentity: identity) }
}
public struct SoftwareInventory: Sendable {
    public let applications: [InstalledApplication]
    public let issues: [String]
}
public struct RemnantScan: Sendable {
    public let remnants: [SoftwareRemnant]
    public let issues: [String]
}

public enum RemnantMatcher {
    public static func matchesIdentifier(_ candidate: String, bundleID: String) -> Bool {
        let candidate = candidate.lowercased(), needle = bundleID.lowercased()
        guard !needle.isEmpty else { return false }
        var start = candidate.startIndex
        while start < candidate.endIndex, let range = candidate.range(of: needle, range: start..<candidate.endIndex) {
            let before = range.lowerBound == candidate.startIndex || [".", "/"].contains(String(candidate[candidate.index(before: range.lowerBound)]))
            let after = range.upperBound == candidate.endIndex || [".", "/"].contains(String(candidate[range.upperBound]))
            if before && after { return true }
            start = candidate.index(after: range.lowerBound)
        }
        return false
    }
    public static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: ".")
    }
    public static func matchesName(_ candidate: String, displayName: String) -> Bool {
        let needle = normalizedName(displayName)
        guard needle.count >= 4 else { return false }
        return ("." + normalizedName(candidate) + ".").contains("." + needle + ".")
    }
    public static func classify(candidateName: String, app: InstalledApplication, containerIdentifier: String? = nil, launchReferencesApp: Bool = false, requiresReview: Bool = false, siblingBundleIDs: [String] = [], siblingNames: [String] = [], artifactSuffix: String? = nil) -> (evidence: String, confidence: RemnantConfidence)? {
        let name = candidateName.lowercased()
        let id = app.bundleID.lowercased()
        let stem = artifactSuffix.flatMap { name.hasSuffix($0) ? String(name.dropLast($0.count)) : nil } ?? name
        let sharedID = siblingBundleIDs.contains { $0.caseInsensitiveCompare(app.bundleID) == .orderedSame }
        if let containerIdentifier, !containerIdentifier.isEmpty {
            guard !id.isEmpty, containerIdentifier.lowercased() == id else { return nil }
            return ("容器元数据精确匹配 Bundle ID", requiresReview || sharedID ? .review : .strong)
        }
        if launchReferencesApp { return ("启动程序位于应用包内", requiresReview || sharedID ? .review : .strong) }
        if matchesIdentifier(stem, bundleID: app.bundleID) {
            let matchesSibling = siblingBundleIDs.contains { matchesIdentifier(stem, bundleID: $0) }
            if matchesSibling || sharedID { return ("也匹配其他已安装应用，需确认归属", .review) }
            if stem == id { return ("Bundle ID 精确匹配", requiresReview ? .review : .strong) }
            return ("包含 Bundle ID，可能属于辅助程序或其他应用", .review)
        }
        if let team = app.teamID, candidateName.lowercased().hasPrefix(team.lowercased() + ".") { return ("Team 前缀，可能为多个应用共享", .review) }
        guard matchesName(candidateName, displayName: app.name) else { return nil }
        if siblingBundleIDs.contains(where: { matchesIdentifier(candidateName, bundleID: $0) }) || siblingNames.contains(where: { matchesName(candidateName, displayName: $0) }) { return nil }
        return ("显示名称匹配，归属尚需确认", .review)
    }
}

public struct SoftwareService: Sendable {
    public init() {}
    public func inventory(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SoftwareInventory {
        let running = await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
        let worker = Task.detached(priority: .utility) {
            let fm = FileManager.default
            let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true), URL(fileURLWithPath: "/System/Applications", isDirectory: true)]
            var applications = [InstalledApplication](), issues = [String](), seen = Set<String>()
            for root in roots where fm.fileExists(atPath: root.path) {
                guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { url, error in issues.append(url.path + "：" + error.localizedDescription); return true }) else { continue }
                while let url = iterator.nextObject() as? URL {
                    try Task.checkCancellation()
                    let depth = url.pathComponents.count - root.pathComponents.count
                    let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                    if values?.isSymbolicLink == true { iterator.skipDescendants(); continue }
                    if url.pathExtension.lowercased() == "app" {
                        iterator.skipDescendants()
                        guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                        progress(url.deletingPathExtension().lastPathComponent)
                        do {
                            let identity = try FileIdentity.capture(url)
                            guard let bundle = Bundle(url: url) else { continue }
                            let info = bundle.infoDictionary ?? [:]
                            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
                            let id = bundle.bundleIdentifier ?? ""
                            let measured = try ReviewFileSizer.measure(url, budget: 0.08, maximumEntries: 15_000)
                            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                            applications.append(InstalledApplication(url: url, allowedRoot: root, name: name, bundleID: id, version: info["CFBundleShortVersionString"] as? String ?? "—", build: info["CFBundleVersion"] as? String ?? "—", teamID: Self.teamIdentifier(url), size: measured.bytes, isSizeIncomplete: measured.incomplete, modifiedAt: modified, identity: identity, isRunning: running.contains(id)))
                        } catch is CancellationError { throw CancellationError() }
                        catch { issues.append(url.path + "：" + error.localizedDescription) }
                    } else if depth >= 3 { iterator.skipDescendants() }
                }
            }
            return SoftwareInventory(applications: applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, issues: issues)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    public func remnants(for app: InstalledApplication, siblings: [InstalledApplication] = [], progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> RemnantScan {
        let worker = Task.detached(priority: .utility) {
            let fm = FileManager.default, home = FileManager.default.homeDirectoryForCurrentUser
            let roots: [(path: String, kind: String, review: Bool, suffix: String?)] = [
                ("Library/Caches", "缓存", false, nil),
                ("Library/Logs", "日志", true, ".log"),
                ("Library/Preferences", "偏好设置", false, ".plist"),
                ("Library/Preferences/ByHost", "本机偏好设置", true, ".plist"),
                ("Library/Saved Application State", "窗口状态", false, ".savedstate"),
                ("Library/Application Support", "应用支持数据", true, nil),
                ("Library/Containers", "应用容器", true, nil),
                ("Library/Group Containers", "共享容器", true, nil),
                ("Library/LaunchAgents", "用户启动项", true, ".plist"),
                ("Library/HTTPStorages", "HTTP 存储", true, nil),
                ("Library/WebKit", "WebKit 数据", true, nil),
                ("Library/Cookies", "Cookie 数据", true, ".binarycookies"),
                ("Library/Application Scripts", "应用脚本", true, nil)
            ]
            var remnants = [SoftwareRemnant](), issues = [String](), seen = Set<String>()
            let began = ProcessInfo.processInfo.systemUptime
            let siblingIDs = siblings.filter { $0.id != app.id }.map(\.bundleID).filter { !$0.isEmpty }
            let siblingNames = siblings.filter { $0.id != app.id }.map(\.name)
            let componentIDs = Self.embeddedComponentIDs(in: app)
            for (rootIndex, rootInfo) in roots.enumerated() {
                let (relative, kind, review, suffix) = rootInfo
                let unfinishedRoots = roots[rootIndex...].map(\.path).joined(separator: "、")
                try Task.checkCancellation()
                let root = home.appendingPathComponent(relative, isDirectory: true)
                progress(kind)
                let children: [URL]
                do { try PathSafety.rejectSymbolicLinks(in: root); children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { continue }
                catch { issues.append(root.path + "：" + error.localizedDescription); continue }
                for candidate in children {
                    try Task.checkCancellation()
                    if ProcessInfo.processInfo.systemUptime - began > 60 { issues.append("达到扫描时间预算，未完成：" + unfinishedRoots); return RemnantScan(remnants: remnants.sorted { $0.size > $1.size }, issues: issues) }
                    // ByHost is a shared directory and has its own scan root.
                    if relative == "Library/Preferences", candidate.lastPathComponent.lowercased() == "byhost" { continue }
                    let identity: FileIdentity
                    do { identity = try FileIdentity.capture(candidate); try PathSafety.validate(candidate, allowedRoot: root, expectedIdentity: identity) }
                    catch { continue }
                    let match = Self.matchRemnant(candidate, in: root, app: app, review: review,
                        suffix: suffix, siblingIDs: siblingIDs, siblingNames: siblingNames, componentIDs: componentIDs)
                    if match == nil, relative == "Library/Application Support", identity.fileType == UInt32(S_IFDIR) {
                        let nested: [URL]
                        do {
                            nested = try fm.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                        } catch {
                            issues.append(candidate.path + "：" + error.localizedDescription)
                            continue
                        }
                        for child in nested {
                            try Task.checkCancellation()
                            if ProcessInfo.processInfo.systemUptime - began > 60 {
                                issues.append("达到扫描时间预算，未完成：" + unfinishedRoots + "。停止位置：" + candidate.path)
                                return RemnantScan(remnants: remnants.sorted { $0.size > $1.size }, issues: issues)
                            }
                            guard let evidence = Self.nestedSupportEvidence(child, app: app, siblingIDs: siblingIDs, siblingNames: siblingNames),
                                  let childIdentity = try? FileIdentity.capture(child),
                                  (try? PathSafety.validate(child, allowedRoot: root, expectedIdentity: childIdentity)) != nil else { continue }
                            do {
                                let size = try ReviewFileSizer.measure(child, budget: 0.3, maximumEntries: 50_000)
                                remnants.append(SoftwareRemnant(url: child, allowedRoot: root, kind: kind, size: size.bytes,
                                    isSizeIncomplete: size.incomplete, evidence: evidence, confidence: .review, identity: childIdentity))
                            } catch is CancellationError { throw CancellationError() }
                            catch { issues.append(child.path + "：" + error.localizedDescription) }
                        }
                    }
                    guard let match, seen.insert(candidate.path).inserted else { continue }
                    do {
                        let measured = try ReviewFileSizer.measure(candidate, budget: 0.3, maximumEntries: 50_000)
                        remnants.append(SoftwareRemnant(url: candidate, allowedRoot: root, kind: kind, size: measured.bytes, isSizeIncomplete: measured.incomplete, evidence: match.evidence, confidence: match.confidence, identity: identity))
                    } catch is CancellationError { throw CancellationError() }
                    catch { issues.append(candidate.path + "：" + error.localizedDescription) }
                }
            }
            return RemnantScan(remnants: remnants.sorted { $0.size > $1.size }, issues: issues)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    public func uninstall(_ application: InstalledApplication, selectedRemnants: [SoftwareRemnant]) async -> [TrashOperationResult] {
        if application.isProtected { return [TrashOperationResult(url: application.url, trashURL: nil, error: PathSafetyError.protectedPath.localizedDescription)] }
        var eligible = [SoftwareRemnant]()
        var skipped = [TrashOperationResult]()
        if !selectedRemnants.isEmpty {
            let running = await UnmatchedRemnantService.runningIdentities()
            let worker = Task.detached(priority: .utility) { (try UnmatchedRemnantService.applicationIdentities(runningURLs: running.urls), Self.embeddedComponentIDs(in: application)) }
            let snapshot = await withTaskCancellationHandler(operation: { try? await worker.value }, onCancel: { worker.cancel() })
            let inventory = snapshot?.0
            let componentIDs = snapshot?.1 ?? []
            let runningIDs = await MainActor.run {
                NSWorkspace.shared.runningApplications.filter {
                    $0.bundleURL?.standardizedFileURL != application.url.standardizedFileURL
                }.compactMap(\.bundleIdentifier)
            }
            let applicationURL = application.url.resolvingSymlinksInPath().standardizedFileURL
            let siblings = inventory?.applications.filter { $0.url != applicationURL } ?? []
            let siblingIDs = siblings.map(\.id) + siblings.flatMap(\.componentIDs) + runningIDs
            let siblingNames = siblings.map(\.name)
            for item in selectedRemnants {
                let error: String?
                if inventory?.isComplete != true {
                    error = "无法完整核对已安装应用，已保留此项。"
                } else if siblingIDs.contains(where: { $0.caseInsensitiveCompare(application.bundleID) == .orderedSame }) {
                    error = "另一份应用仍使用此 Bundle ID，已保留此项。"
                } else {
                    error = Self.remnantRecheckError(item, app: application, siblingIDs: siblingIDs, siblingNames: siblingNames, componentIDs: componentIDs)
                }
                if let error { skipped.append(TrashOperationResult(url: item.url, trashURL: nil, error: error)) }
                else { eligible.append(item) }
            }
        }
        guard !Task.isCancelled else { return skipped }
        let appResults = await TrashService.shared.moveToTrash([TrashRequest(url: application.url, allowedRoot: application.allowedRoot, ownerBundleID: application.bundleID, expectedIdentity: application.identity)])
        guard appResults.first?.succeeded == true else { return appResults + skipped }
        return appResults + skipped + (await TrashService.shared.moveToTrash(eligible.map { $0.request(owner: application.bundleID) }))
    }

    private static func remnantRecheckError(_ item: SoftwareRemnant, app: InstalledApplication, siblingIDs: [String], siblingNames: [String], componentIDs: Set<String>) -> String? {
        do { try PathSafety.validate(item.url, allowedRoot: item.allowedRoot, expectedIdentity: item.identity) }
        catch { return error.localizedDescription }

        let root = item.allowedRoot
        let candidate = item.url.lastPathComponent
        let targetMatches = RemnantMatcher.matchesIdentifier(candidate, bundleID: app.bundleID)
        if siblingIDs.contains(where: { id in
            // An exact target ID can coexist with an installed app whose ID is a shorter prefix.
            guard id.caseInsensitiveCompare(app.bundleID) != .orderedSame else { return false }
            return RemnantMatcher.matchesIdentifier(candidate, bundleID: id) &&
                (!targetMatches || !RemnantMatcher.matchesIdentifier(app.bundleID, bundleID: id))
        }) {
            return "文件名现在匹配另一款应用，已保留此项。"
        }
        let suffixes = ["Preferences": ".plist", "ByHost": ".plist", "LaunchAgents": ".plist",
                        "Saved Application State": ".savedstate", "Cookies": ".binarycookies", "Logs": ".log"]
        let evidence: String?
        if item.url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL {
            evidence = matchRemnant(item.url, in: root, app: app, review: item.confidence == .review,
                suffix: suffixes[root.lastPathComponent], siblingIDs: siblingIDs, siblingNames: siblingNames, componentIDs: componentIDs)?.evidence
        } else {
            evidence = nestedSupportEvidence(item.url, app: app, siblingIDs: siblingIDs, siblingNames: siblingNames)
        }
        return evidence == item.evidence ? nil : "归属证据已变化，请重新扫描。"
    }

    private static func nestedSupportEvidence(_ url: URL, app: InstalledApplication, siblingIDs: [String], siblingNames: [String]) -> String? {
        let name = url.lastPathComponent
        if !app.bundleID.isEmpty, name.caseInsensitiveCompare(app.bundleID) == .orderedSame,
           !siblingIDs.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "厂商目录下的子项精确匹配 Bundle ID"
        }
        let normalized = RemnantMatcher.normalizedName(name)
        guard normalized.count >= 4, normalized == RemnantMatcher.normalizedName(app.name),
              !siblingNames.contains(where: { RemnantMatcher.normalizedName($0) == normalized }),
              !siblingIDs.contains(where: { RemnantMatcher.matchesIdentifier(name, bundleID: $0) }) else { return nil }
        return "厂商目录下的子项名称与应用同名，需确认归属"
    }

    private static func matchRemnant(_ url: URL, in root: URL, app: InstalledApplication, review: Bool,
                                     suffix: String?, siblingIDs: [String], siblingNames: [String], componentIDs: Set<String>) -> (evidence: String, confidence: RemnantConfidence)? {
        let name = url.lastPathComponent.lowercased()
        let stem = suffix.flatMap { name.hasSuffix($0) ? String(name.dropLast($0.count)) : nil } ?? name
        if ["Caches", "Preferences", "Logs"].contains(root.lastPathComponent),
           componentIDs.contains(stem),
           !siblingIDs.contains(where: { UnmatchedRemnantMatcher.overlaps(stem, identifier: $0) }) {
            return ("应用内嵌组件 Bundle ID 精确匹配：" + stem, .review)
        }
        let containerID = root.lastPathComponent == "Containers" ? readRemnantPlist(
            url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        )?["MCMMetadataIdentifier"] as? String : nil

        var references = false
        if root.lastPathComponent == "LaunchAgents", url.pathExtension.lowercased() == "plist",
           let plist = readRemnantPlist(url),
           let executable = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first,
           executable.hasPrefix("/") {
            let program = URL(fileURLWithPath: executable)
            references = PathSafety.contains(program, in: app.url) &&
                (try? PathSafety.rejectSymbolicLinks(in: program)) != nil
        }
        return RemnantMatcher.classify(candidateName: url.lastPathComponent, app: app, containerIdentifier: containerID,
            launchReferencesApp: references, requiresReview: review, siblingBundleIDs: siblingIDs,
            siblingNames: siblingNames, artifactSuffix: suffix)
    }

    private static func embeddedComponentIDs(in app: InstalledApplication) -> Set<String> {
        guard (try? PathSafety.validate(app.url, allowedRoot: app.allowedRoot, expectedIdentity: app.identity)) != nil else { return [] }
        return Set(embeddedBundleIdentifiers(at: app.url).compactMap {
            guard let id = UnmatchedRemnantMatcher.identifier(filename: $0),
                  id.caseInsensitiveCompare(app.bundleID) != .orderedSame else { return nil }
            return id.lowercased()
        })
    }

    static func embeddedBundleIdentifiers(at appURL: URL) -> Set<String> {
        let locations = ["Contents/PlugIns", "Contents/Extensions", "Contents/XPCServices",
                         "Contents/Helpers", "Contents/Library/LoginItems", "Contents/Library/SystemExtensions"]
        let extensions = ["appex", "app", "xpc", "systemextension", "dext"]
        var ids = Set<String>()
        for location in locations {
            if Task.isCancelled { break }
            let folder = appURL.appendingPathComponent(location)
            guard (try? PathSafety.rejectSymbolicLinks(in: folder)) != nil,
                  let children = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for child in children where extensions.contains(child.pathExtension.lowercased()) {
                let info = child.appendingPathComponent("Contents/Info.plist")
                guard let id = readRemnantPlist(info)?["CFBundleIdentifier"] as? String, !id.isEmpty else { continue }
                ids.insert(id.lowercased())
            }
        }
        // Standard locations are checked first so large resource trees cannot crowd them out.
        let contents = appURL.appendingPathComponent("Contents")
        guard (try? PathSafety.rejectSymbolicLinks(in: contents)) != nil,
              let iterator = FileManager.default.enumerator(at: contents,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return ids }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        var visited = 0
        while let child = iterator.nextObject() as? URL {
            visited += 1
            if Task.isCancelled || visited > 12_000 || ProcessInfo.processInfo.systemUptime > deadline { break }
            guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else {
                iterator.skipDescendants()
                continue
            }
            if extensions.contains(child.pathExtension.lowercased()),
               let id = readRemnantPlist(child.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String,
               !id.isEmpty {
                ids.insert(id.lowercased())
            }
            if iterator.level >= 10 { iterator.skipDescendants() }
        }
        return ids
    }

    private static func readRemnantPlist(_ url: URL) -> [String: Any]? {
        guard (try? PathSafety.rejectSymbolicLinks(in: url)) != nil,
              let identity = try? FileIdentity.capture(url), identity.fileType == UInt32(S_IFREG),
              (1...1_000_000).contains(identity.size),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_000_001), data.count <= 1_000_000,
              (try? FileIdentity.capture(url)) == identity else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func teamIdentifier(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
