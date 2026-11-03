import Foundation
import Darwin
import Security

public struct SystemApplicationIdentity: Codable, Sendable {
    public let url: URL
    public let bundleID: String
    public let teamID: String?
    public let identity: FileIdentity
    public init(_ app: InstalledApplication) { url = app.url; bundleID = app.bundleID; teamID = app.teamID; identity = app.identity }
}
public struct SystemUninstallItem: Identifiable, Codable, Sendable {
    public let url: URL
    public let identity: FileIdentity
    public let evidence: String
    public let serviceLabel: String?
    public var requiredServiceLabel: String?
    public var id: String { url.path }
}
public struct SystemUninstallPlan: Codable, Sendable {
    public let application: SystemApplicationIdentity
    public var items: [SystemUninstallItem]
    public let issues: [String]
    public var receipts: [String] = []
    public init(application: SystemApplicationIdentity, items: [SystemUninstallItem], issues: [String] = []) { self.application = application; self.items = items; self.issues = issues }
}
public struct SystemQuarantinedItem: Codable, Sendable {
    public let item: SystemUninstallItem
    public let destination: URL
    public var moved = false
    public var restored = false
    public var serviceWasLoaded = false
    public var serviceStopped = false
    private static let conflictDetail = "原位置被占用。请移开冲突项目后重试。"
    var destinationConflict: Bool?
    public var hasDestinationConflict: Bool {
        !restored && (destinationConflict ?? (detail == Self.conflictDetail))
    }
    public var detail = "尚未执行"

    mutating func markDestinationConflict() {
        destinationConflict = true
        detail = Self.conflictDetail
    }
}
public struct SystemUninstallRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let ownerUID: UInt32
    public let application: SystemApplicationIdentity
    public var phase: String
    public var items: [SystemQuarantinedItem]
}

public struct SystemUninstallPlanner: Sendable {
    public init() {}
    public func plan(_ identity: SystemApplicationIdentity) async throws -> SystemUninstallPlan {
        try SystemUninstallPolicy().validateApplication(identity)
        let app = InstalledApplication(url: identity.url, allowedRoot: identity.url.deletingLastPathComponent(), name: identity.url.deletingPathExtension().lastPathComponent,
            bundleID: identity.bundleID, version: "—", build: "—", teamID: (try? AppcastInstallValidation.strictTeam(identity.url)) ?? identity.teamID,
            size: 0, isSizeIncomplete: true, modifiedAt: nil, identity: identity.identity, isRunning: false)
        return try await plan(app)
    }
    public func plan(_ app: InstalledApplication) async throws -> SystemUninstallPlan {
        guard !app.isProtected else { throw AdminError.invalid("系统应用及本应用不能在此卸载。") }
        return try await Task.detached(priority: .utility) {
            let policy = SystemUninstallPolicy()
            let application = SystemApplicationIdentity(app)
            try policy.validateApplication(application)
            let declarations = try policy.applicationInfo(app.url)["SMPrivilegedExecutables"] as? [String: String] ?? [:]
            var items = [SystemUninstallItem(url: app.url, identity: app.identity, evidence: "明确选择的应用；仅移入管理员隔离目录", serviceLabel: nil)], issues: [String] = []
            for root in policy.dataRoots + [policy.daemonRoot, policy.agentRoot, policy.helperRoot] {
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                do {
                    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    guard files.count <= 30_000 else { issues.append("\(root.path)：项目过多，未继续识别。"); continue }
                    for url in files {
                        if policy.dataRoots.contains(root), ![application.bundleID, application.bundleID + ".plist", application.bundleID + ".log"].contains(url.lastPathComponent) { continue }
                        if root == policy.helperRoot, declarations[url.lastPathComponent] == nil { continue }
                        if [policy.daemonRoot, policy.agentRoot].contains(root), url.pathExtension != "plist" { continue }
                        do {
                            var item = SystemUninstallItem(url: url, identity: try FileIdentity.capture(url), evidence: [policy.daemonRoot, policy.agentRoot].contains(root) ? "启动服务引用所选应用或其签名 helper" : root == policy.helperRoot ? "应用签名声明、同一开发者及专属系统服务关联；必须同时选择对应服务" : "完整 Bundle ID 精确匹配；系统数据需手动复核", serviceLabel: [policy.daemonRoot, policy.agentRoot].contains(root) ? try? policy.serviceInfo(url).label : nil)
                            if root == policy.helperRoot { item.requiredServiceLabel = url.lastPathComponent }
                            try policy.validate(item, application: application); items.append(item)
                        } catch {
                            if ![policy.daemonRoot, policy.agentRoot].contains(root) { issues.append(url.path + "：" + error.localizedDescription) }
                        }
                    }
                } catch { issues.append("\(root.path)：\(error.localizedDescription)") }
            }
            var result = SystemUninstallPlan(application: application, items: items, issues: issues + ["系统扩展、驱动、非 Aqua/多用户 LaunchAgents 和共享/归属不明的 helper 请使用厂商卸载器；本流程不会删除安装收据。"])
            let escaped = NSRegularExpression.escapedPattern(for: application.bundleID)
            let receipts = try? await ToolCommandExecutor().run(ToolCommand("/usr/sbin/pkgutil", ["--pkgs=^" + escaped + "($|[.])"]), timeout: 20, maximumOutputBytes: 128 * 1024)
            if let receipts, receipts.succeeded { result.receipts = receipts.output.split(separator: "\n").map(String.init) }
            return result
        }.value
    }
}

struct SystemUninstallPolicy: Sendable {
    var applicationRoots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Library/Input Methods")]
    var dataRoots = ["Caches", "Logs", "Preferences", "Application Support"].map { URL(fileURLWithPath: "/Library/" + $0) }
    var daemonRoot = URL(fileURLWithPath: "/Library/LaunchDaemons")
    var agentRoot = URL(fileURLWithPath: "/Library/LaunchAgents")
    var helperRoot = URL(fileURLWithPath: "/Library/PrivilegedHelperTools")
    var serviceOwner: uid_t = 0
    var team: @Sendable (URL) throws -> String = { try AppcastInstallValidation.strictTeam($0) }
    var requirement: @Sendable (URL, String) throws -> Void = { url, text in
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement) == errSecSuccess else { throw AdminError.invalid("系统 helper 未满足应用签名声明中的代码要求。") }
    }
    func applicationInfo(_ app: URL) throws -> [String: Any] { try AppcastInstallValidation.readInfo(app) }
    func validateApplication(_ app: SystemApplicationIdentity) throws {
        guard let root = applicationRoots.first(where: { PathSafety.contains(app.url, in: $0) }), app.url.pathExtension == "app",
              !app.url.lastPathComponent.hasPrefix("."), app.url.pathComponents.count - root.pathComponents.count <= 3,
              !app.bundleID.isEmpty, !app.bundleID.hasPrefix("com.apple."), app.bundleID != RebuildPaths.bundleIdentifier,
              app.identity.fileType == UInt32(S_IFDIR),
              app.url.standardizedFileURL == app.url else { throw AdminError.invalid("应用位置或标识受保护，不能进行系统级卸载。") }
        try PathSafety.validate(app.url, allowedRoot: root, expectedIdentity: app.identity)
        let info = try applicationInfo(app.url)
        guard info["CFBundleIdentifier"] as? String == app.bundleID, info["CFBundlePackageType"] as? String == "APPL" else { throw AdminError.invalid("应用身份已变化，请重新扫描。") }
        if let expected = app.teamID { guard try team(app.url) == expected else { throw AdminError.invalid("应用开发者签名与扫描时不符。") } }
    }
    func validate(_ item: SystemUninstallItem, application: SystemApplicationIdentity) throws {
        if item.url == application.url {
            guard item.identity == application.identity, item.serviceLabel == nil else { throw AdminError.invalid("应用项目身份不符。") }
            try validateApplication(application); return
        }
        guard item.identity.fileType == UInt32(S_IFREG) || item.identity.fileType == UInt32(S_IFDIR),
              item.url.standardizedFileURL == item.url else { throw AdminError.invalid("仅可处理普通文件或目录。") }
        if let root = dataRoots.first(where: { item.url.deletingLastPathComponent().path == $0.path }) {
            let accepted = [application.bundleID, application.bundleID + ".plist", application.bundleID + ".log"]
            guard accepted.contains(item.url.lastPathComponent), item.serviceLabel == nil else { throw AdminError.invalid("系统数据不满足完整应用标识精确匹配。") }
            try PathSafety.validate(item.url, allowedRoot: root, expectedIdentity: item.identity)
        } else if item.url.deletingLastPathComponent().path == daemonRoot.path {
            try PathSafety.validate(item.url, allowedRoot: daemonRoot, expectedIdentity: item.identity)
            let service = try serviceInfo(item.url)
            guard service.label == item.serviceLabel, !service.label.hasPrefix("com.apple."), service.label != RebuildPaths.bundleIdentifier,
                  !service.program.contains("..") else { throw AdminError.invalid("系统服务未精确引用所选应用内部程序。") }
            let program = URL(fileURLWithPath: service.program).standardizedFileURL
            if !PathSafety.contains(program, in: application.url) {
                guard program.deletingLastPathComponent().path == helperRoot.path, service.label == program.lastPathComponent else { throw AdminError.invalid("系统服务没有精确引用所选应用的专属组件。") }
                try validateHelper(program, application: application)
            }
        } else if item.url.deletingLastPathComponent().path == agentRoot.path {
            try PathSafety.validate(item.url, allowedRoot: agentRoot, expectedIdentity: item.identity)
            let service = try serviceInfo(item.url)
            let program = URL(fileURLWithPath: service.program)
            guard service.label == item.serviceLabel, !service.label.hasPrefix("com.apple."), service.label != RebuildPaths.bundleIdentifier,
                  !service.program.contains(".."), PathSafety.contains(program, in: application.url),
                  let expected = application.teamID, !expected.isEmpty, try team(application.url) == expected,
                  try team(program) == expected else { throw AdminError.invalid("全局 LaunchAgent 必须精确引用所选应用内同一开发者签名程序。") }
            var st = stat()
            guard lstat(program.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o111 != 0 else { throw AdminError.invalid("LaunchAgent 程序不是普通可执行文件。") }
            let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: item.url), format: nil) as? [String: Any] ?? [:]
            if let session = info["LimitLoadToSessionType"] {
                guard (session as? String) == "Aqua" || (session as? [String]) == ["Aqua"] else { throw AdminError.invalid("仅支持 Aqua 图形会话的全局 LaunchAgent。") }
            }
            guard info["UserName"] == nil, info["RootDirectory"] == nil else { throw AdminError.invalid("LaunchAgent 包含不支持的用户或根目录策略。") }
        } else if item.url.deletingLastPathComponent().path == helperRoot.path {
            try PathSafety.validate(item.url, allowedRoot: helperRoot, expectedIdentity: item.identity)
            guard item.identity.fileType == UInt32(S_IFREG), item.requiredServiceLabel == item.url.lastPathComponent else { throw AdminError.invalid("系统组件计划缺少对应服务。") }
            try validateHelper(item.url, application: application)
            let plist = daemonRoot.appendingPathComponent(item.url.lastPathComponent + ".plist")
            let service = try serviceInfo(plist)
            guard service.label == item.requiredServiceLabel, URL(fileURLWithPath: service.program).standardizedFileURL.path == item.url.path else { throw AdminError.invalid("系统组件缺少精确对应的服务声明。") }
        } else { throw AdminError.invalid("项目不在允许的系统目录范围内。") }
    }
    private func validateHelper(_ url: URL, application: SystemApplicationIdentity) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_uid == serviceOwner,
              status.st_mode & 0o022 == 0, status.st_nlink == 1 else { throw AdminError.invalid("系统 helper 的所有者、权限或链接数无效。") }
        let declarations = try applicationInfo(application.url)["SMPrivilegedExecutables"] as? [String: String] ?? [:]
        guard declarations[url.lastPathComponent] != nil, let expected = application.teamID, !expected.isEmpty,
              try team(application.url) == expected, try team(url) == expected else { throw AdminError.invalid("系统组件没有应用声明与同一开发者签名证据。") }
        try requirement(url, declarations[url.lastPathComponent]!)
        let began = ProcessInfo.processInfo.systemUptime
        var count = 0
        for root in applicationRoots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            var incomplete = false
            guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles], errorHandler: { _, _ in incomplete = true; return false }) else { throw AdminError.unavailable("无法检查其他应用声明，保留系统组件。") }
            while let other = iterator.nextObject() as? URL {
                count += 1
                guard count <= 30_000, ProcessInfo.processInfo.systemUptime - began <= 5 else { throw AdminError.unavailable("无法在预算内排除组件被其他应用共享，保留该组件。") }
                if other.pathExtension == "app" {
                    iterator.skipDescendants()
                    if other.path != application.url.path {
                        guard let info = try? applicationInfo(other) else { throw AdminError.unavailable("其他应用声明不可读取，无法排除共享组件。") }
                        if let peers = info["SMPrivilegedExecutables"] as? [String: String], peers[url.lastPathComponent] != nil { throw AdminError.unavailable("另一个应用也声明使用该系统组件，保留共享组件。") }
                    }
                } else if other.pathComponents.count - root.pathComponents.count >= 3 { iterator.skipDescendants() }
            }
            guard !incomplete else { throw AdminError.unavailable("应用清单不完整，保留可能共享的组件。") }
        }
    }
    func serviceInfo(_ url: URL) throws -> (label: String, program: String) {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == serviceOwner,
              st.st_mode & 0o022 == 0, st.st_size > 0, st.st_size <= 1024 * 1024,
              let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
              let label = info["Label"] as? String, !label.isEmpty, label.count <= 200,
              label.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
              let program = (info["Program"] as? String) ?? (info["ProgramArguments"] as? [String])?.first, program.hasPrefix("/") else { throw AdminError.invalid("系统服务声明或权限无效。") }
        try PathSafety.rejectSymbolicLinks(in: URL(fileURLWithPath: program))
        return (label, program)
    }
}

struct SystemUninstallEngine: Sendable {
    var storage = AdminStorage()
    var policy = SystemUninstallPolicy()
    var isRunning: @Sendable (URL) -> Bool = { Self.processExists($0) }
    var agentSessionCheck: @Sendable (UInt32) throws -> Void = { try AgentSessionSafety.check(owner: $0) }
    var command: @Sendable (ToolCommand) async throws -> ToolCommandResult = { try await ToolCommandExecutor().run($0, timeout: 60, maximumOutputBytes: 64 * 1024) }
    func records(owner: UInt32) throws -> [SystemUninstallRecord] {
        try storage.prepare()
        let files = try FileManager.default.contentsOfDirectory(at: storage.root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("uninstall-") && $0.pathExtension == "json" }
        guard files.count <= 1000 else { throw AdminError.unavailable("记录过多，请先检查管理员存储。") }
        return try files.map { try storage.read(SystemUninstallRecord.self, file: $0) }.filter { $0.ownerUID == owner }.sorted { $0.date > $1.date }
    }
    func save(_ record: SystemUninstallRecord) throws { try storage.write(record, to: storage.root.appendingPathComponent("uninstall-\(record.id.uuidString).json")) }
    func quarantine(_ plan: SystemUninstallPlan, owner: UInt32) async throws -> SystemUninstallRecord {
        try policy.validateApplication(plan.application)
        guard !plan.items.isEmpty, plan.items.count <= 200, plan.items.filter({ $0.url == plan.application.url }).count == 1,
              Set(plan.items.map(\.id)).count == plan.items.count,
              (!isRunning(plan.application.url) || plan.items.contains(where: { $0.serviceLabel != nil })) else { throw AdminError.invalid("应用仍在运行或卸载计划无效。") }
        for item in plan.items { try policy.validate(item, application: plan.application) }
        let serviceLabels = Set(plan.items.filter { $0.url.deletingLastPathComponent().path == policy.daemonRoot.path }.compactMap(\.serviceLabel))
        guard plan.items.compactMap(\.requiredServiceLabel).allSatisfy(serviceLabels.contains) else { throw AdminError.invalid("隔离系统 helper 时必须同时选择其对应系统服务。") }
        if plan.items.contains(where: isAgent) { try agentSessionCheck(owner) }
        try storage.prepare()
        let id = UUID(), destination = storage.root.appendingPathComponent("quarantine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let device = try FileIdentity.capture(destination).device
        guard plan.items.allSatisfy({ $0.identity.device == device }) else { throw AdminError.unavailable("隔离位置与目标不在同一卷，未执行卸载。") }
        var record = SystemUninstallRecord(id: id, date: Date(), ownerUID: owner, application: plan.application, phase: "prepared", items: plan.items.enumerated().map { SystemQuarantinedItem(item: $0.element, destination: destination.appendingPathComponent(String($0.offset))) })
        try save(record)
        let deadline = ProcessInfo.processInfo.systemUptime + 240
        do {
            for index in record.items.indices {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw AdminError.unavailable("管理员操作超过时限，保留已完成步骤。") }
                guard let label = record.items[index].item.serviceLabel else { continue }
                if isAgent(record.items[index].item) { try await checkUserDomain(label: label, owner: owner) }
                let domain = try serviceDomain(record.items[index].item, owner: owner)
                let query = try await command(ToolCommand("/bin/launchctl", ["print", domain + "/" + label]))
                guard query.succeeded || query.exitCode == 113 else { throw AdminError.failed("无法确认系统服务加载状态，未卸载应用。") }
                if query.succeeded {
                    if isAgent(record.items[index].item) {
                        try agentSessionCheck(owner)
                        guard query.output.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "path = " + record.items[index].item.url.path }) else { throw AdminError.invalid("已加载 LaunchAgent 的配置路径不匹配，未停止服务。") }
                    }
                    try policy.validate(record.items[index].item, application: plan.application)
                    record.items[index].serviceWasLoaded = true; record.items[index].detail = "准备停止已加载服务"; try save(record)
                    let result = try await command(ToolCommand("/bin/launchctl", ["bootout", domain + "/" + label]))
                    guard result.succeeded else { throw AdminError.failed("停止系统服务失败，未继续卸载应用。") }
                    record.items[index].serviceStopped = true; record.items[index].detail = "服务已停止"; try save(record)
                }
            }
            for index in record.items.indices.sorted(by: { record.items[$0].item.url == plan.application.url && record.items[$1].item.url != plan.application.url }) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw AdminError.unavailable("管理员操作超过时限，保留已完成步骤。") }
                let entry = record.items[index]
                if plan.items.contains(where: isAgent) { try agentSessionCheck(owner) }
                if entry.item.url == plan.application.url, isRunning(plan.application.url) { throw AdminError.unavailable("应用在复核后已启动，未继续移动。") }
                // Revalidate each actual path after any async launchctl operation.
                if entry.item.url == plan.application.url { try policy.validateApplication(plan.application) }
                else {
                    // Association was checked before moving the app. Its sealed
                    // Info.plist is now inside quarantine, so recheck the exact
                    // candidate identity here rather than reading a missing app.
                    try PathSafety.rejectSymbolicLinks(in: entry.item.url)
                    guard try FileIdentity.capture(entry.item.url) == entry.item.identity else { throw AdminError.invalid("关联项目在移动前已改变。") }
                }
                record.phase = "moving"; record.items[index].detail = "准备移动（若中断，恢复会核对两处实际身份）"; try save(record)
                try move(entry.item.url, to: entry.destination, identity: entry.item.identity)
                record.items[index].moved = true; record.items[index].detail = "已隔离"; try save(record)
            }
            record.phase = "quarantined"; try save(record)
            return record
        } catch {
            record.phase = "needsReview"; try? save(record)
            throw AdminError.failed("系统级卸载未全部完成，已完成项目保留在隔离记录 \(id.uuidString)。\(error.localizedDescription)")
        }
    }
    func restore(id: UUID, owner: UInt32) throws -> SystemUninstallRecord {
        guard var record = try records(owner: owner).first(where: { $0.id == id }) else { throw AdminError.invalid("没有属于当前用户的隔离记录。") }
        for index in record.items.indices {
            let entry = record.items[index]
            let existsSource = try? FileIdentity.capture(entry.item.url)
            let existsDestination = try? FileIdentity.capture(entry.destination)
            if entry.restored { continue }
            if existsSource == entry.item.identity, existsDestination == nil { record.items[index].restored = true; record.items[index].detail = "原位置仍为记录中的项目，无需覆盖"; try save(record); continue }
            if existsSource != nil {
                record.items[index].markDestinationConflict()
                record.phase = "restoreNeedsReview"
                try save(record)
                continue
            }
            guard existsDestination == entry.item.identity,
                  entry.destination.deletingLastPathComponent().deletingLastPathComponent().path == storage.root.path,
                  entry.destination.deletingLastPathComponent().lastPathComponent.hasPrefix("quarantine-") else { throw AdminError.invalid("原位置被占用或隔离项目身份变化，恢复不会覆盖。") }
            try storage.validate(entry.destination.deletingLastPathComponent(), directory: true)
            guard policy.applicationRoots.contains(where: { PathSafety.contains(entry.item.url, in: $0) }) || (policy.dataRoots + [policy.daemonRoot, policy.agentRoot, policy.helperRoot]).contains(where: { $0.path == entry.item.url.deletingLastPathComponent().path }) else { throw AdminError.invalid("恢复目的地已不在允许范围。") }
            try PathSafety.rejectSymbolicLinks(in: entry.item.url.deletingLastPathComponent())
            record.phase = "restoring"; try save(record)
            try move(entry.destination, to: entry.item.url, identity: entry.item.identity)
            record.items[index].restored = true; record.items[index].detail = "已恢复文件；系统服务不会自动重新启动"; try save(record)
        }
        record.phase = record.items.allSatisfy(\.restored) ? "restored" : "restoreNeedsReview"
        try save(record)
        return record
    }
    func reloadServices(_ input: SystemUninstallRecord) async throws -> SystemUninstallRecord {
        var record = input
        try policy.validateApplication(record.application)
        do {
            for index in record.items.indices where record.items[index].serviceWasLoaded && record.items[index].serviceStopped {
                let item = record.items[index].item
                guard let label = item.serviceLabel, record.items[index].restored else { continue }
                try policy.validate(item, application: record.application)
                let domain = try serviceDomain(item, owner: record.ownerUID)
                if isAgent(item) { try agentSessionCheck(record.ownerUID); try await checkUserDomain(label: label, owner: record.ownerUID) }
                let existing = try await command(ToolCommand("/bin/launchctl", ["print", domain + "/" + label]))
                guard existing.exitCode == 113 else { throw AdminError.unavailable("服务标签已存在或状态不可确认，未覆盖当前服务：\(label)") }
                try policy.validate(item, application: record.application)
                record.items[index].detail = "文件已恢复，准备按明确确认重新加载服务"; try save(record)
                let result = try await command(ToolCommand("/bin/launchctl", ["bootstrap", domain, item.url.path]))
                guard result.succeeded else { throw AdminError.failed("重新加载系统服务失败：\(label)") }
                record.items[index].serviceStopped = false; record.items[index].detail = "文件已恢复，服务已重新加载"; try save(record)
            }
        } catch { record.phase = "restoredServicesNeedReview"; try? save(record); throw error }
        record.phase = "restored"; try save(record); return record
    }
    private func checkUserDomain(label: String, owner: UInt32) async throws {
        let result = try await command(ToolCommand("/bin/launchctl", ["print", "user/\(owner)/" + label]))
        guard result.exitCode == 113 else { throw AdminError.unavailable("同名用户域服务存在或状态无法确认，保留全局 LaunchAgent。") }
    }
    private func isAgent(_ item: SystemUninstallItem) -> Bool { item.url.deletingLastPathComponent().path == policy.agentRoot.path }
    private func serviceDomain(_ item: SystemUninstallItem, owner: UInt32) throws -> String {
        if isAgent(item) {
            guard owner >= 500, owner != UInt32.max else { throw AdminError.invalid("LaunchAgent 请求用户无效。") }
            return "gui/\(owner)"
        }
        return "system"
    }
    private func move(_ source: URL, to destination: URL, identity: FileIdentity) throws {
        try PathSafety.rejectSymbolicLinks(in: source); try PathSafety.rejectSymbolicLinks(in: destination.deletingLastPathComponent())
        guard try FileIdentity.capture(source) == identity, renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw AdminError.failed("文件身份改变或移动失败，未覆盖目标。") }
        try storage.syncDirectory(source.deletingLastPathComponent()); try storage.syncDirectory(destination.deletingLastPathComponent())
        guard try FileIdentity.capture(destination) == identity else { throw AdminError.failed("移动后身份异常，请保留隔离记录。") }
    }
    private static func processExists(_ app: URL) -> Bool {
        var pids = [pid_t](repeating: 0, count: 131072)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0, count < pids.count else { return true }
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0, PathSafety.contains(URL(fileURLWithPath: String(cString: path)), in: app) { return true }
        }
        return false
    }
}
