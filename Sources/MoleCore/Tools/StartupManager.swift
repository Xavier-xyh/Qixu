import Foundation

public enum StartupScope: String, CaseIterable, Sendable {
    case user = "用户启动项", shared = "共享启动项", daemon = "系统服务", apple = "Apple 系统项目"
}
public enum StartupRuntime: String, Sendable { case loaded = "已加载", unloaded = "未加载", unknown = "未检查" }

public struct StartupItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let label: String
    public let program: String
    public let arguments: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let configuredDisabled: Bool
    public let scope: StartupScope
    public var overrideDisabled: Bool?
    public var runtime: StartupRuntime = .unknown
    public var effectiveDisabled: Bool { overrideDisabled ?? configuredDisabled }
    public var canManage: Bool { scope == .user }
    public static func decode(data: Data, url: URL, scope: StartupScope) throws -> StartupItem {
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let plist = value as? [String: Any], let label = plist["Label"] as? String, !label.isEmpty else {
            throw ToolOperationError.invalid("启动项没有有效 Label：\(url.lastPathComponent)")
        }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let program = plist["Program"] as? String ?? arguments.first ?? "未指定"
        let keepAlive: Bool
        if let b = plist["KeepAlive"] as? Bool { keepAlive = b }
        else { keepAlive = plist["KeepAlive"] is [String: Any] }
        return StartupItem(url: url, label: label, program: program, arguments: arguments,
            runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
            configuredDisabled: plist["Disabled"] as? Bool ?? false, scope: scope)
    }
}

public enum StartupOperation: String, CaseIterable, Identifiable, Sendable {
    case enable = "允许下次启动", disable = "停用并卸载", load = "立即加载", unload = "仅卸载本次"
    public var id: String { rawValue }
}

public struct StartupScan: Sendable {
    public var items: [StartupItem]
    public var issues: [String]
}

public actor StartupManager {
    private let userRoot: URL
    private let uid: UInt32
    private let executor = ToolCommandExecutor()
    public init(userRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"), uid: UInt32 = getuid()) {
        self.userRoot = userRoot.standardizedFileURL; self.uid = uid
    }
    public func scan() async throws -> StartupScan {
        let roots: [(URL, StartupScope)] = [(userRoot, .user), (URL(fileURLWithPath: "/Library/LaunchAgents"), .shared),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon), (URL(fileURLWithPath: "/System/Library/LaunchAgents"), .apple),
            (URL(fileURLWithPath: "/System/Library/LaunchDaemons"), .apple)]
        var items: [StartupItem] = []; var issues: [String] = []
        for (root, scope) in roots {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            do {
                for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) where url.pathExtension == "plist" {
                    try Task.checkCancellation()
                    do {
                        if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { continue }
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        guard data.count <= 2 * 1024 * 1024 else { continue }
                        items.append(try StartupItem.decode(data: data, url: url, scope: scope))
                    } catch { issues.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
                }
            } catch { issues.append("\(root.path)：\(error.localizedDescription)") }
        }
        let result = try await executor.run(ToolCommand("/bin/launchctl", ["print-disabled", "gui/\(uid)"]))
        if result.succeeded {
            let overrides = Self.parseDisabledOutput(result.output)
            for i in items.indices where items[i].scope == .user || items[i].scope == .shared { items[i].overrideDisabled = overrides[items[i].label] }
        } else { issues.append("无法读取用户启动覆盖设置：\(result.output)") }
        return StartupScan(items: items.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }, issues: issues)
    }
    public static func parseDisabledOutput(_ output: String) -> [String: Bool] {
        let expression = try? NSRegularExpression(pattern: #"\"([^\"]+)\"\s*=>\s*(true|false)"#)
        let string = output as NSString
        var values: [String: Bool] = [:]
        for match in expression?.matches(in: output, range: NSRange(location: 0, length: string.length)) ?? [] {
            values[string.substring(with: match.range(at: 1))] = string.substring(with: match.range(at: 2)) == "true"
        }
        return values
    }
    public static func isValidLabel(_ label: String) -> Bool {
        label.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,199}$"#, options: .regularExpression) != nil
    }
    public func validatedUserItem(_ item: StartupItem) throws -> StartupItem {
        let url = item.url.standardizedFileURL
        guard item.scope == .user, url.deletingLastPathComponent() == userRoot, url.pathExtension == "plist", Self.isValidLabel(item.label) else {
            throw ToolOperationError.invalid("仅允许管理当前用户 LaunchAgents 目录内的有效启动项。")
        }
        var current = url
        while current.path != "/" {
            let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw ToolOperationError.invalid("启动项路径包含符号链接，拒绝执行。") }
            current.deleteLastPathComponent()
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 2 * 1024 * 1024 else { throw ToolOperationError.invalid("启动项文件过大。") }
        let latest = try StartupItem.decode(data: data, url: url, scope: .user)
        guard latest.label == item.label else { throw ToolOperationError.invalid("启动项在复核后已发生变化，请重新载入。") }
        return latest
    }
    public func runtime(for item: StartupItem) async throws -> (StartupRuntime, String) {
        guard Self.isValidLabel(item.label) else { throw ToolOperationError.invalid("此 Label 不能用作 launchctl 服务目标。") }
        let domain = item.scope == .daemon || item.url.path.hasPrefix("/System/Library/LaunchDaemons/") ? "system" : "gui/\(uid)"
        let result = try await executor.run(ToolCommand("/bin/launchctl", ["print", "\(domain)/\(item.label)"]))
        let missing = result.output.localizedCaseInsensitiveContains("could not find service") || result.output.localizedCaseInsensitiveContains("could not find domain")
        return (result.succeeded ? .loaded : (missing ? .unloaded : .unknown), result.output)
    }
    public func commands(for operation: StartupOperation, item: StartupItem) throws -> [ToolCommand] {
        let item = try validatedUserItem(item)
        let target = "gui/\(uid)/\(item.label)"
        switch operation {
        case .enable: return [ToolCommand("/bin/launchctl", ["enable", target])]
        case .disable: return [ToolCommand("/bin/launchctl", ["disable", target]), ToolCommand("/bin/launchctl", ["bootout", target])]
        case .load: return [ToolCommand("/bin/launchctl", ["bootstrap", "gui/\(uid)", item.url.path])]
        case .unload: return [ToolCommand("/bin/launchctl", ["bootout", target])]
        }
    }
    public func execute(_ operation: StartupOperation, item: StartupItem) async throws -> [ToolCommandResult] {
        let commands = try commands(for: operation, item: item)
        var results: [ToolCommandResult] = []
        for command in commands {
            try Task.checkCancellation()
            _ = try validatedUserItem(item)
            if command.arguments.first == "bootout" {
                let (state, _) = try await runtime(for: item)
                if state == .unloaded { continue }
            }
            let result = try await executor.run(command)
            results.append(result)
            guard result.succeeded else { throw ToolOperationError.failed("\(command.display)\n\(result.output)") }
        }
        return results
    }
}
