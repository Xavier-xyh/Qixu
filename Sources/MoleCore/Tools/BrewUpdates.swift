import Foundation

public enum BrewPackageKind: String, Codable, Sendable { case formula, cask }
public struct BrewUpdate: Identifiable, Hashable, Sendable {
    public var id: String { kind.rawValue + ":" + name }
    public let name: String
    public let installedVersions: String
    public let currentVersion: String
    public let kind: BrewPackageKind
    public let pinned: Bool
    public init(name: String, installedVersions: String, currentVersion: String, kind: BrewPackageKind, pinned: Bool = false) {
        self.name = name; self.installedVersions = installedVersions; self.currentVersion = currentVersion; self.kind = kind; self.pinned = pinned
    }
}

public struct BrewUpdateService: Sendable {
    public let executable: String?
    public init(executable: String? = nil) {
        self.executable = executable ?? ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static func validPackageName(_ value: String) -> Bool {
        !value.hasPrefix("/") && !value.contains("..") && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9@+_.:/-]{0,240}$"#, options: .regularExpression) != nil
    }
    public static func parseOutdated(_ data: Data) throws -> [BrewUpdate] {
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any], dictionary["formulae"] is [Any], dictionary["casks"] is [Any] else {
            throw ToolOperationError.invalid("Homebrew 返回的 JSON 结构无法识别。")
        }
        var results: [BrewUpdate] = []
        for (key, kind) in [("formulae", BrewPackageKind.formula), ("casks", .cask)] {
            for entry in dictionary[key] as? [[String: Any]] ?? [] {
                guard let name = entry["name"] as? String, validPackageName(name), let current = entry["current_version"] as? String else { continue }
                let versions = (entry["installed_versions"] as? [String])?.joined(separator: ", ") ?? entry["installed_versions"] as? String ?? "未知"
                results.append(BrewUpdate(name: name, installedVersions: versions, currentVersion: current, kind: kind, pinned: entry["pinned"] as? Bool ?? false))
            }
        }
        return results.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func upgradeCommand(for update: BrewUpdate) throws -> ToolCommand {
        guard let executable else { throw ToolOperationError.unavailable("未找到 Homebrew。") }
        guard Self.validPackageName(update.name), !update.pinned else { throw ToolOperationError.invalid("包名无效或此包已固定版本。") }
        return ToolCommand(executable, update.kind == .formula ? ["upgrade", "--formula", update.name] : ["upgrade", "--cask", "--greedy", update.name])
    }
    public func check(refreshMetadata: Bool = true) async throws -> [BrewUpdate] {
        guard let executable else { throw ToolOperationError.unavailable("此电脑未发现 Homebrew；不会自动安装。") }
        if refreshMetadata {
            let refresh = try await ToolCommandExecutor().run(ToolCommand(executable, ["update", "--quiet"]), timeout: 300, environment: Self.environment)
            guard refresh.succeeded else { throw ToolOperationError.failed("Homebrew 元数据刷新失败：\n\(refresh.output)") }
            try Task.checkCancellation()
        }
        let result = try await ToolCommandExecutor().run(ToolCommand(executable, ["outdated", "--json=v2", "--greedy"]), timeout: 180, environment: Self.environment)
        guard result.succeeded else { throw ToolOperationError.failed(result.output.isEmpty ? "Homebrew 检查失败（\(result.exitCode)）。" : result.output) }
        return try Self.parseOutdated(Data(result.output.utf8))
    }
    public func upgrade(_ update: BrewUpdate) async throws -> ToolCommandResult {
        let result = try await ToolCommandExecutor().run(upgradeCommand(for: update), timeout: 1800, environment: Self.environment)
        guard result.succeeded else { throw ToolOperationError.failed(result.output.isEmpty ? "Homebrew 更新失败（\(result.exitCode)）。" : result.output) }
        return result
    }
    private static var environment: [String: String] { ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1"] }
}
