import Foundation
import SystemConfiguration
import Darwin
import CryptoKit

public enum ServiceDNS {
    private struct Backup: Codable {
        let owner: UInt32
        let target: NetworkRefreshTarget
        let original: [String]?
        let replacement: [String]
    }

    public static func addresses(_ input: String) throws -> [String] {
        let entries = input.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        guard (1...8).contains(entries.count), Set(entries).count == entries.count,
              entries.allSatisfy({ address in
                  var v4 = in_addr()
                  var v6 = in6_addr()
                  return !address.utf8.contains(0) &&
                      (inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1)
              }) else { throw AdminError.invalid("请输入 1 至 8 个不重复的 IPv4 或 IPv6 地址，以空格或逗号分隔。") }
        return entries
    }

    static func change(target: NetworkRefreshTarget, input: String?, owner: UInt32) throws -> String {
        guard geteuid() == 0 else { throw AdminError.invalid("修改 DNS 需要管理员授权。") }
        let replacement = try input.map(addresses)
        let storage = AdminStorage()
        let key = SHA256.hash(data: Data(target.serviceID.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = storage.root.appendingPathComponent("dns-\(key).json")

        guard let prefs = SCPreferencesCreate(nil, "Qixu.ServiceDNS" as CFString, nil),
              SCPreferencesLock(prefs, false) else { throw AdminError.unavailable("网络设置正在使用，请稍后重试。") }
        defer { SCPreferencesUnlock(prefs) }
        SCPreferencesSynchronize(prefs)
        guard let set = SCNetworkSetCopyCurrent(prefs), SCNetworkSetGetSetID(set) as String? == target.locationID,
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService],
              let service = services.first(where: { SCNetworkServiceGetServiceID($0) as String? == target.serviceID }),
              let state = NetworkConfiguration.describe(service, location: target.locationID),
              state.target == target, state.enabled, state.physical,
              let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS),
              SCNetworkProtocolGetEnabled(dns) else {
            throw AdminError.invalid("目标网络服务已改变，或其 DNS 协议不可用。请重新读取。")
        }

        var configuration = SCNetworkProtocolGetConfiguration(dns) as? [String: Any] ?? [:]
        let addressKey = kSCPropNetDNSServerAddresses as String
        let current = configuration[addressKey] as? [String]
        guard configuration[addressKey] == nil || current != nil else {
            throw AdminError.invalid("现有 DNS 配置格式无法识别。")
        }

        let backup: Backup
        if FileManager.default.fileExists(atPath: file.path) {
            backup = try storage.read(Backup.self, file: file)
            guard backup.owner == owner, backup.target == target else {
                throw AdminError.invalid("该服务有另一用户或网络位置的 DNS 备份。")
            }
            guard current == backup.replacement || current == backup.original else {
                throw AdminError.invalid("DNS 已被其他操作更改，请在系统设置中核对。")
            }
            if let replacement, replacement != backup.replacement {
                throw AdminError.invalid("请先恢复此服务的原 DNS，再设置另一组地址。")
            }
        } else {
            guard let replacement else { throw AdminError.invalid("此网络服务没有 Qixu DNS 备份。") }
            backup = Backup(owner: owner, target: target, original: current, replacement: replacement)
            try storage.write(backup, to: file)
        }

        configuration[addressKey] = replacement == nil ? backup.original : backup.replacement
        guard SCNetworkProtocolSetConfiguration(dns, configuration as CFDictionary),
              SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
            throw AdminError.failed("系统未确认应用 DNS 设置。备份已保留，可重新读取后重试或恢复。")
        }
        if replacement == nil {
            try FileManager.default.removeItem(at: file)
            return "已恢复 \(state.name) 的原 DNS 设置。"
        }
        return "已为 \(state.name) 设置 DNS：\(backup.replacement.joined(separator: ", "))。原设置已备份。"
    }
}
