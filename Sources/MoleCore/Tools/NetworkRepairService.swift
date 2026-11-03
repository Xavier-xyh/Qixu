import Foundation
import SystemConfiguration
import Darwin

public struct NetworkRefreshTarget: Codable, Equatable, Sendable {
    public let locationID: String
    public let serviceID: String
    public let interfaceName: String
}

public struct NetworkServiceState: Identifiable, Sendable {
    public var id: String { target.serviceID }
    public let name: String
    public let target: NetworkRefreshTarget
    public let method: String
    public let enabled: Bool
    public let physical: Bool
    public var configuredDNS: [String]? = nil
    public var canRefresh: Bool { enabled && physical && method == "DHCP" }
}

public struct NetworkLocalState: Sendable {
    public let date: Date
    public let primaryInterfaces: [String]
    public let addresses: [String]
    public let gateways: [String]
    public let dnsServers: [String]
    public let proxyKinds: [String]
    public let services: [NetworkServiceState]
    public var preferredTarget: NetworkRefreshTarget? {
        services.first { $0.canRefresh && primaryInterfaces.contains($0.target.interfaceName) }?.target
    }
    public var report: String {
        ["检查时间：\(date.formatted())", "主接口：\(primaryInterfaces.joined(separator: ", "))",
         "地址：\(addresses.joined(separator: ", "))", "网关：\(gateways.joined(separator: ", "))",
         "DNS：\(dnsServers.joined(separator: ", "))", "系统代理：\(proxyKinds.isEmpty ? "未启用全局代理" : proxyKinds.joined(separator: ", "))"]
            .joined(separator: "\n")
    }
}

public struct NetworkCheck: Identifiable, Sendable {
    public enum State: String, Sendable { case passed, warning, failed, skipped }
    public let id: String
    public let title: String
    public let state: State
    public let detail: String
}

public struct NetworkDiagnosis: Sendable {
    public let local: NetworkLocalState
    public let checks: [NetworkCheck]
    public var report: String {
        local.report + "\n\n" + checks.map { "\($0.title) [\($0.state.rawValue)]\n\($0.detail)" }.joined(separator: "\n\n")
    }
}

/// Reads SystemConfiguration instead of guessing a Wi-Fi device name or parsing
/// localized networksetup output. No SSID, proxy credentials or PAC URL collected.
public enum NetworkConfiguration {
    public static func read() throws -> NetworkLocalState {
        guard let store = SCDynamicStoreCreate(nil, "Qixu.Network" as CFString, nil, nil),
              let prefs = SCPreferencesCreate(nil, "Qixu.Network" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(prefs),
              let location = SCNetworkSetGetSetID(set) as String? else {
            throw ToolOperationError.unavailable("无法读取系统网络配置。")
        }
        func values(_ key: String) -> [String: Any] { SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] ?? [:] }
        let ipv4 = values("State:/Network/Global/IPv4"), ipv6 = values("State:/Network/Global/IPv6")
        let primary = unique([ipv4["PrimaryInterface"] as? String, ipv6["PrimaryInterface"] as? String].compactMap { $0 })
        var addresses: [String] = [], dns = values("State:/Network/Global/DNS")["ServerAddresses"] as? [String] ?? []
        for name in primary {
            addresses += values("State:/Network/Interface/\(name)/IPv4")["Addresses"] as? [String] ?? []
            addresses += values("State:/Network/Interface/\(name)/IPv6")["Addresses"] as? [String] ?? []
        }
        for id in [ipv4["PrimaryService"] as? String, ipv6["PrimaryService"] as? String].compactMap({ $0 }) {
            dns += values("State:/Network/Service/\(id)/DNS")["ServerAddresses"] as? [String] ?? []
        }
        let proxy = SCDynamicStoreCopyProxies(store) as? [String: Any] ?? [:]
        let kinds = [("HTTPEnable", "HTTP"), ("HTTPSEnable", "HTTPS"), ("SOCKSEnable", "SOCKS"),
                     ("ProxyAutoConfigEnable", "PAC 自动配置"), ("ProxyAutoDiscoveryEnable", "自动发现")]
            .filter { (proxy[$0.0] as? NSNumber)?.boolValue == true }.map { $0.1 }
        let services = (SCNetworkSetCopyServices(set) as? [SCNetworkService] ?? []).compactMap { describe($0, location: location) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return NetworkLocalState(date: Date(), primaryInterfaces: primary, addresses: unique(addresses),
            gateways: unique([ipv4["Router"] as? String, ipv6["Router"] as? String].compactMap { $0 }),
            dnsServers: unique(dns), proxyKinds: kinds, services: services)
    }

    static func describe(_ service: SCNetworkService, location: String) -> NetworkServiceState? {
        guard let interface = SCNetworkServiceGetInterface(service),
              let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
              let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
        let type = SCNetworkInterfaceGetInterfaceType(interface) as String?
        let protocolRef = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv4)
        let config = protocolRef.flatMap { SCNetworkProtocolGetConfiguration($0) as? [String: Any] } ?? [:]
        let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS)
        let dnsConfig = dns.flatMap { SCNetworkProtocolGetConfiguration($0) } as? [String: Any]
        return NetworkServiceState(name: (SCNetworkServiceGetName(service) as String?) ?? bsd,
            target: NetworkRefreshTarget(locationID: location, serviceID: id, interfaceName: bsd),
            method: config["ConfigMethod"] as? String ?? "未配置 IPv4",
            enabled: SCNetworkServiceGetEnabled(service) && protocolRef.map { SCNetworkProtocolGetEnabled($0) } == true,
            physical: type == (kSCNetworkInterfaceTypeEthernet as String) || type == (kSCNetworkInterfaceTypeIEEE80211 as String),
            configuredDNS: dnsConfig?[kSCPropNetDNSServerAddresses as String] as? [String])
    }

    static func validateRefresh(_ target: NetworkRefreshTarget, current: NetworkServiceState) throws {
        guard target == current.target, current.canRefresh else {
            throw ToolOperationError.invalid("网卡、网络位置或 DHCP 配置已经改变。请重新读取；只支持已启用的 Wi-Fi/以太网 DHCP 服务。")
        }
    }

    /// A hint to the existing DHCP client, never a conversion of static IP to DHCP.
    /// Apple's API reports notification delivery, not successful address renewal.
    static func refresh(_ target: NetworkRefreshTarget) throws -> String {
        guard geteuid() == 0 else { throw AdminError.invalid("重新协商网络需要管理员授权。") }
        guard let prefs = SCPreferencesCreate(nil, "Qixu.NetworkRefresh" as CFString, nil),
              SCPreferencesLock(prefs, false) else { throw AdminError.unavailable("网络配置正在改变，请稍后重新读取。") }
        defer { SCPreferencesUnlock(prefs) }
        SCPreferencesSynchronize(prefs)
        guard let set = SCNetworkSetCopyCurrent(prefs), let location = SCNetworkSetGetSetID(set) as String?,
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            throw AdminError.unavailable("无法重新读取当前网络位置。")
        }
        let matches = services.filter { (SCNetworkServiceGetServiceID($0) as String?) == target.serviceID }
        guard matches.count == 1, let service = matches.first,
              let current = describe(service, location: location), let interface = SCNetworkServiceGetInterface(service) else {
            throw AdminError.invalid("目标网络服务已不存在，请重新读取。")
        }
        try validateRefresh(target, current: current)
        guard SCNetworkInterfaceForceConfigurationRefresh(interface) else {
            throw AdminError.failed("系统未接受网络重新协商请求：\(String(cString: SCErrorString(SCError())))")
        }
        return "已通知 \(current.name)（\(target.interfaceName)）立即重试网络配置。此结果只确认通知已发送；不代表 DHCP 已续租或外网已恢复。请稍后重新检测。"
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>(); return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

private final class NoNetworkRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct NetworkDiagnosticService: Sendable {
    public init() {}
    public func diagnose() async throws -> NetworkDiagnosis {
        let local = try await Task.detached { try NetworkConfiguration.read() }.value
        try Task.checkCancellation()
        async let gateway = checkGateway(local.gateways.first)
        async let dns = checkDNS()
        async let https = checkHTTPS()
        let checks = try await [gateway, dns, https]
        return NetworkDiagnosis(local: local, checks: [Self.localCheck(local)] + checks)
    }
    static func localCheck(_ local: NetworkLocalState) -> NetworkCheck {
        let usable = local.addresses.contains { address in
            if address.contains(":") {
                var value = in6_addr()
                let literal = String(address.split(separator: "%", maxSplits: 1).first ?? "")
                guard inet_pton(AF_INET6, literal, &value) == 1 else { return false }
                let bytes = withUnsafeBytes(of: value) { Array($0) }
                // Link-local is fe80::/10, not just the common fe80:: spelling.
                let linkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80
                let loopbackOrUnspecified = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] <= 1
                return !linkLocal && !loopbackOrUnspecified && bytes[0] != 0xff
            }
            var value = in_addr()
            guard inet_pton(AF_INET, address, &value) == 1 else { return false }
            let bytes = withUnsafeBytes(of: value) { Array($0) }
            return bytes[0] != 0 && bytes[0] != 127 && bytes[0] < 224 && !(bytes[0] == 169 && bytes[1] == 254)
        }
        return NetworkCheck(id: "local", title: "本机地址", state: usable ? .passed : .warning,
            detail: usable ? "主接口已分配地址。\(local.primaryInterfaces.joined(separator: ", "))" : "未读到主接口的可用地址。检查连接状态；仅有 169.254 或链路本地地址时，可复核 DHCP 服务。")
    }
    func checkGateway(_ gateway: String?) async throws -> NetworkCheck {
        var address = in_addr()
        guard let gateway, inet_pton(AF_INET, gateway, &address) == 1 else {
            return NetworkCheck(id: "gateway", title: "局域网网关", state: .skipped, detail: "没有可用的 IPv4 网关；IPv6 或部分 VPN 路由不适用此 ICMP 检测。")
        }
        return try await commandCheck(ToolCommand("/sbin/ping", ["-n", "-c", "2", "-W", "1000", "-t", "4", gateway]), id: "gateway", title: "局域网网关",
            evaluate: { $0.succeeded ? .passed : .warning }, note: "网关可能屏蔽 ICMP；无响应不能单独判定断网。")
    }
    func checkDNS() async throws -> NetworkCheck {
        try await commandCheck(ToolCommand("/usr/bin/dscacheutil", ["-q", "host", "-a", "name", "www.apple.com"]), id: "dns", title: "系统域名解析",
            evaluate: { $0.succeeded && Self.containsDNSAddress($0.output) ? .passed : .failed }, note: "使用系统解析器查询 www.apple.com，可能命中本机缓存；不能证明每个 DNS 服务器都正常。")
    }
    static func containsDNSAddress(_ output: String) -> Bool {
        output.split(separator: "\n").contains { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { return false }
            var ipv4 = in_addr(), ipv6 = in6_addr()
            return (parts[0] == "ip_address" && inet_pton(AF_INET, parts[1], &ipv4) == 1)
                || (parts[0] == "ipv6_address" && inet_pton(AF_INET6, parts[1], &ipv6) == 1)
        }
    }
    private func commandCheck(_ command: ToolCommand, id: String, title: String,
                              evaluate: (ToolCommandResult) -> NetworkCheck.State, note: String) async throws -> NetworkCheck {
        do {
            let result = try await ToolCommandExecutor().run(command, timeout: 8, maximumOutputBytes: 32 * 1024)
            return NetworkCheck(id: id, title: title, state: evaluate(result), detail: note + "\n" + result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch is CancellationError { throw CancellationError() }
        catch { return NetworkCheck(id: id, title: title, state: .warning, detail: "检测未完成：\(error.localizedDescription)\n\(note)") }
    }
    func checkHTTPS() async throws -> NetworkCheck {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 12
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: NoNetworkRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let url = URL(string: "https://www.apple.com/library/test/success.html")!
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 32 * 1024 else { return NetworkCheck(id: "https", title: "HTTPS 连通性", state: .warning, detail: "响应超过预期大小，可能受到代理或认证门户影响。") }
                data.append(byte)
            }
            return Self.evaluateHTTPS(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return NetworkCheck(id: "https", title: "HTTPS 连通性", state: .failed,
                detail: "Apple 检测地址连接失败：\(error.localizedDescription)。检查 DNS、代理/VPN、网络认证和系统时间；单个站点失败不代表整个互联网不可用。")
        }
    }
    static func evaluateHTTPS(status: Int, body: Data) -> NetworkCheck {
        let text = String(decoding: body, as: UTF8.self).lowercased().filter { !$0.isWhitespace }
        let success = status == 200 && text.contains("<title>success</title>") && text.contains("<body>success</body>")
        return NetworkCheck(id: "https", title: "HTTPS 连通性", state: success ? .passed : .warning,
            detail: success ? "Apple 检测地址通过 HTTPS 返回预期内容。使用系统网络栈；此结果仅代表该地址可达。"
                : "检测地址返回 HTTP \(status)，内容不符合预期。可能需要网络登录，或代理/站点阻止了请求；未跟随重定向。")
    }
}
