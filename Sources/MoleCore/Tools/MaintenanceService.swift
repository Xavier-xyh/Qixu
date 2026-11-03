import Foundation

public enum MaintenanceAction: String, CaseIterable, Identifiable, Sendable {
    case dns, spotlightStatus, spotlightReindex, memoryPurge, quickLook, periodic, diskVerify, systemDiagnostics
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dns: return "刷新 DNS 缓存"
        case .spotlightStatus: return "检查 Spotlight"
        case .spotlightReindex: return "重建 Spotlight 索引"
        case .memoryPurge: return "释放可清除内存"
        case .quickLook: return "重建快速查看缓存"
        case .periodic: return "执行系统周期维护"
        case .diskVerify: return "验证启动卷"
        case .systemDiagnostics: return "系统诊断摘要"
        }
    }
    public var symbol: String {
        switch self {
        case .dns: return "network"
        case .spotlightStatus, .spotlightReindex: return "magnifyingglass"
        case .memoryPurge: return "memorychip"
        case .quickLook: return "eye"
        case .periodic: return "calendar.badge.clock"
        case .diskVerify: return "externaldrive.badge.checkmark"
        case .systemDiagnostics: return "stethoscope"
        }
    }
    public var detail: String {
        switch self {
        case .dns: return "清空名称缓存并通知 mDNSResponder 重新加载；后续域名访问会重新解析。"
        case .spotlightStatus: return "读取启动卷的 Spotlight 索引状态，不修改索引。"
        case .spotlightReindex: return "请求重新建立启动卷索引，可能持续一段时间并占用 CPU；命令结束不代表索引完成。"
        case .memoryPurge: return "请求系统回收可清除缓存。缓存将按需重建，可能暂时降低后续访问速度。"
        case .quickLook: return "重置当前用户的 Quick Look 生成器及缩略图缓存，之后按需生成。"
        case .periodic: return "使用当前 macOS 提供的 daily / weekly / monthly 维护；较新系统可能不再提供 periodic。"
        case .diskVerify: return "读取并验证启动卷文件系统；不会执行修复，过程可能较慢。"
        case .systemDiagnostics: return "读取系统版本、运行时长与当前防睡眠声明，输出保留在本页供检查。"
        }
    }
    public var requiresAdministrator: Bool {
        [.dns, .spotlightReindex, .memoryPurge, .periodic].contains(self)
    }
    public var commands: [ToolCommand] {
        switch self {
        case .dns: return [ToolCommand("/usr/bin/dscacheutil", ["-flushcache"]), ToolCommand("/usr/bin/killall", ["-HUP", "mDNSResponder"])]
        case .spotlightStatus: return [ToolCommand("/usr/bin/mdutil", ["-s", "/"])]
        case .spotlightReindex: return [ToolCommand("/usr/bin/mdutil", ["-E", "/"])]
        case .memoryPurge: return [ToolCommand("/usr/sbin/purge")]
        case .quickLook: return [ToolCommand("/usr/bin/qlmanage", ["-r"]), ToolCommand("/usr/bin/qlmanage", ["-r", "cache"])]
        case .periodic: return [ToolCommand("/usr/sbin/periodic", ["daily", "weekly", "monthly"])]
        case .diskVerify: return [ToolCommand("/usr/sbin/diskutil", ["verifyVolume", "/"])]
        case .systemDiagnostics: return [ToolCommand("/usr/bin/sw_vers"), ToolCommand("/usr/bin/uptime"), ToolCommand("/usr/bin/pmset", ["-g", "assertions"])]
        }
    }
    public var isAvailable: Bool { commands.allSatisfy { FileManager.default.isExecutableFile(atPath: $0.executable) } }
    public var commandDescription: String { commands.map(\.display).joined(separator: "\n") }
}

public struct MaintenanceService: Sendable {
    public init() {}
    public func execute(_ action: MaintenanceAction) async throws -> [ToolCommandResult] {
        guard action.isAvailable else { throw ToolOperationError.unavailable("当前系统不提供 \(action.title) 所需的命令。") }
        let executor = ToolCommandExecutor()
        if action.requiresAdministrator {
            let script = CommandEscaping.privilegedScript(action.commands)
            let result = try await executor.run(ToolCommand("/usr/bin/osascript", ["-e", script]), timeout: 600)
            guard result.succeeded else { throw ToolOperationError.failed(result.output.isEmpty ? "管理员操作未完成（\(result.exitCode)）。" : result.output) }
            return [result]
        }
        var results: [ToolCommandResult] = []
        for command in action.commands {
            try Task.checkCancellation()
            let result = try await executor.run(command, timeout: 600)
            results.append(result)
            guard result.succeeded else { throw ToolOperationError.failed("\(command.display)\n\(result.output)") }
        }
        return results
    }
}

public struct KeepAwakeState: Sendable {
    public let active: Bool
    public let until: Date?
    public let keepsDisplayAwake: Bool
}

public actor KeepAwakeService {
    public static let shared = KeepAwakeService()
    private var process: Process?
    private var until: Date?
    private var display = false
    public func state() -> KeepAwakeState {
        KeepAwakeState(active: process?.isRunning == true, until: until, keepsDisplayAwake: display)
    }
    public func start(seconds: Int?, keepDisplayAwake: Bool) throws {
        stop()
        let value = Process(); value.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        var arguments = ["-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        if keepDisplayAwake { arguments.append("-d") }
        if let seconds {
            guard (60...86_400).contains(seconds) else { throw ToolOperationError.invalid("防睡眠时长必须介于 1 分钟和 24 小时。") }
            arguments += ["-t", String(seconds)]
        }
        value.arguments = arguments; value.standardOutput = FileHandle.nullDevice; value.standardError = FileHandle.nullDevice
        try value.run(); process = value; display = keepDisplayAwake
        until = seconds.map { Date().addingTimeInterval(TimeInterval($0)) }
    }
    public func stop() {
        if process?.isRunning == true { process?.terminate() }
        process = nil; until = nil
    }
}
