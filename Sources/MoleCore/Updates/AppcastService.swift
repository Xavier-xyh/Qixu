import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct AppcastInspection: Sendable {
    public let targets: [AppUpdateTarget]
    public let issues: [String]
    public let unsupportedCount: Int
}

public struct AppcastService: Sendable {
    let fetch: @Sendable (URL) async throws -> Data
    public init() { fetch = { try await UpdateMetadataClient().load($0) } }
    init(fetch: @escaping @Sendable (URL) async throws -> Data) { self.fetch = fetch }
    public func inventory(progress: @escaping @Sendable(String) -> Void = { _ in }) async throws -> AppcastInspection {
        let inventory = try await SoftwareService().inventory(progress: progress)
        var targets: [AppUpdateTarget] = [], issues = inventory.issues
        var unsupported = 0
        for application in inventory.applications where !application.isProtected {
            try Task.checkCancellation()
            if let store = StoreUpdateConfiguration.read(application: application.url, bundleID: application.bundleID) {
                targets.append(AppUpdateTarget(application: application, feedURL: store.feedURL, publicKey: nil, source: .appStore(store))); continue
            }
            if application.bundleID == "com.microsoft.VSCode" {
                do {
                    if let code = try CodeUpdateConfiguration.read(application: application.url, bundleID: application.bundleID) {
                        targets.append(AppUpdateTarget(application: application, feedURL: code.feedURL, publicKey: nil, source: .vscode(code))); continue
                    }
                } catch { unsupported += 1; issues.append("\(application.name)：\(error.localizedDescription)"); continue }
            }
            let file = application.url.appendingPathComponent("Contents/Info.plist")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 4 * 1024 * 1024,
                  let data = try? Data(contentsOf: file),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { unsupported += 1; continue }
            guard let feed = info["SUFeedURL"] as? String else {
                do {
                    if let configuration = try ElectronUpdateConfiguration.read(application: application.url) {
                        targets.append(AppUpdateTarget(application: application, feedURL: configuration.feedURL, publicKey: nil, source: .electron(configuration)))
                    } else { unsupported += 1 }
                } catch { unsupported += 1; issues.append("\(application.name)：\(error.localizedDescription)") }
                continue
            }
            guard let url = URL(string: feed), AppUpdateURLPolicy.allows(url) else { issues.append("\(application.name)：更新来源不是可接受的 HTTPS 地址。"); continue }
            targets.append(AppUpdateTarget(application: application, feedURL: url, publicKey: info["SUPublicEDKey"] as? String, requiresSignedFeed: AppUpdateMetadata.requiresSignedFeed(info)))
        }
        return AppcastInspection(targets: targets, issues: issues, unsupportedCount: unsupported)
    }
    public func check(_ target: AppUpdateTarget) async throws -> AppcastRelease? {
        if case .vscode = target.source { return try await AdditionalUpdateServices.check(target) }
        if case .appStore = target.source { return try await AdditionalUpdateServices.check(target) }
        if case .electron = target.source { return try await ElectronUpdateService(fetch: fetch).check(target) }
        if target.requiresSignedFeed {
            guard let key = target.publicKey, Data(base64Encoded: key)?.count == 32 else { throw AppUpdateError.invalid("签名信息源缺少有效的 Ed25519 公钥。") }
        }
        guard AppUpdateVersion.components(target.application.build) != nil else { throw AppUpdateError.unavailable("此应用的版本编号格式需要由其自身更新器处理。") }
        guard AppUpdateURLPolicy.allows(target.feedURL) else { throw AppUpdateError.invalid("更新来源不符合 HTTPS 地址要求。") }
        let data = try await fetch(target.feedURL)
        let content = target.requiresSignedFeed ? try SparkleSignedFeed.verifiedContent(data, publicKey: target.publicKey ?? "") : data
        return Self.latest(try Self.parse(content), newerThan: target.application.build, includePackages: true)
    }
    /// A previously displayed release is not itself proof of a signed feed.
    /// Re-fetch and verify before downloading and again before committing files.
    func revalidateSignedRelease(_ release: AppcastRelease, target: AppUpdateTarget) async throws {
        if target.requiresSignedFeed && target.source != .sparkle { throw AppUpdateError.invalid("此来源声明了不受支持的签名信息源协议。") }
        guard target.requiresMetadataAuthentication else { return }
        guard try await check(target) == release else { throw AppUpdateError.invalid("已验证的信息源中，适用版本或更新内容已改变，请重新检查后复核。") }
    }
    public static func parse(_ data: Data) throws -> [AppcastRelease] {
        guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw AppUpdateError.invalid("更新信息源格式或大小不受支持。")
        }
        let markup = text.replacingOccurrences(of: #"(?s)<!\[CDATA\[.*?\]\]>"#, with: "", options: .regularExpression).uppercased()
        guard !markup.contains("<!DOCTYPE"), !markup.contains("<!ENTITY") else { throw AppUpdateError.invalid("更新信息源不允许外部实体或 DTD。") }
        let reader = AppcastReader()
        let parser = XMLParser(data: data); parser.shouldProcessNamespaces = true; parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse(), !reader.rejected, reader.hasChannel else { throw AppUpdateError.invalid("无法解析 RSS 更新信息源。") }
        return reader.releases
    }
    public static func latest(_ releases: [AppcastRelease], newerThan current: String, systemVersion: String? = nil, architecture: String? = nil, includePackages: Bool = false) -> AppcastRelease? {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let system = systemVersion ?? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        guard AppUpdateVersion.components(system) != nil else { return nil }
        #if arch(arm64)
        let currentArchitecture = architecture ?? "arm64"
        #else
        let currentArchitecture = architecture ?? "x86_64"
        #endif
        return releases.filter { release in
            guard AppUpdateURLPolicy.allows(release.downloadURL), AppUpdateVersion.compare(release.build, current) == .orderedDescending,
                  release.channel == nil || release.channel == "stable",
                  release.installationType == nil || release.installationType == "application" || (includePackages && release.installationType == "package") else { return false }
            if let arch = release.architecture, !arch.isEmpty {
                let accepted = arch.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                guard accepted.contains(currentArchitecture) || accepted.contains("universal") else { return false }
            }
            if let minimum = release.minimumSystemVersion { guard let comparison = AppUpdateVersion.compare(system, minimum), comparison != .orderedAscending else { return false } }
            if let maximum = release.maximumSystemVersion { guard let comparison = AppUpdateVersion.compare(system, maximum), comparison != .orderedDescending else { return false } }
            if let minimum = release.minimumUpdateVersion { guard let comparison = AppUpdateVersion.compare(current, minimum), comparison != .orderedAscending else { return false } }
            return true
        }.sorted { AppUpdateVersion.compare($0.build, $1.build) == .orderedDescending }.first
    }
    public static func automaticInstallIssue(target: AppUpdateTarget, release: AppcastRelease) -> String? {
        if target.application.isProtected { return "系统或当前应用只能使用原有更新途径。" }
        if target.requiresSignedFeed && target.source != .sparkle { return "此来源的签名信息协议不受支持，请使用应用自身更新。" }
        switch target.source {
        case .appStore: return "由 App Store 完成购买验证、下载和安装；请打开官方页面检查更新。"
        case .vscode(let configuration):
            guard target.feedURL == configuration.feedURL, let checksum = release.sha256, validHex(checksum, length: 64),
                  let artifact = release.artifactID, validHex(artifact, length: 40), release.downloadURL.pathExtension.lowercased() == "zip",
                  AppUpdateVersion.compare(release.version, target.application.version) == .orderedDescending else { return "VS Code 更新缺少可验证版本、commit 或 SHA-256。" }
        case .sparkle:
            guard let key = target.publicKey, Data(base64Encoded: key)?.count == 32 else { return "应用未提供可用更新公钥，请使用应用自身更新。" }
            guard let signature = release.signature, Data(base64Encoded: signature)?.count == 64 else { return "更新包未提供可用签名，请使用应用自身更新。" }
        case .electron(let configuration):
            guard configuration.feedURL == target.feedURL, Data(base64Encoded: release.sha512 ?? "")?.count == 64,
                  ElectronUpdateService.stableVersion(release.version),
                  AppUpdateVersion.compare(release.version, target.application.version) == .orderedDescending else { return "Electron 更新缺少可用的完整性信息或更高正式版本。" }
            guard ["zip", "dmg"].contains(release.downloadURL.pathExtension.lowercased()) else { return "此 Electron 更新需应用自身处理；本页安装支持完整 ZIP 或 DMG。" }
        }
        guard ["zip", "dmg"].contains(release.downloadURL.pathExtension.lowercased()) else { return "此更新格式需要安装器或其他处理，请使用应用自身更新。" }
        guard let length = release.length, (1...1_073_741_824).contains(length) else { return "更新包大小缺失或超过 1 GiB，请使用应用自身更新。" }
        guard let team = target.application.teamID, !team.isEmpty else { return "应用没有可复核的开发者签名身份。" }
        return nil
    }
}

private final class AppcastReader: NSObject, XMLParserDelegate {
    static let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    var releases: [AppcastRelease] = []
    var rejected = false
    private(set) var hasChannel = false
    private var hasRSS = false
    private var prefixes: [String: String] = [:]
    private var depth = 0
    private var itemDepth: Int?
    private var item: [String: String] = [:]
    private var enclosures: [[String: String]] = []
    private var textKey: String?
    private var textDepth = 0
    private var text = ""
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { prefixes[prefix] = namespaceURI }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { prefixes.removeValue(forKey: prefix) }
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        depth += 1
        guard depth <= 32, releases.count < 3000 else { rejected = true; parser.abortParsing(); return }
        if depth == 1 { hasRSS = element == "rss" && (namespaceURI ?? "").isEmpty }
        if depth == 2, hasRSS, element == "channel", (namespaceURI ?? "").isEmpty { hasChannel = true }
        if element == "item", (namespaceURI ?? "").isEmpty {
            guard hasChannel, depth == 3 else { return }
            guard itemDepth == nil else { rejected = true; parser.abortParsing(); return }
            itemDepth = depth; item = [:]; enclosures = []
        }
        guard let itemDepth else { return }
        if element == "enclosure", depth == itemDepth + 1, (namespaceURI ?? "").isEmpty {
            var values = attributes.filter { !$0.key.contains(":") }
            for (key, value) in attributes {
                let parts = key.split(separator: ":", maxSplits: 1)
                if parts.count == 2, prefixes[String(parts[0])] == Self.sparkle { values["sparkle:" + parts[1]] = value }
            }
            if values["sparkle:deltaFrom"] == nil { enclosures.append(values) }
        } else if depth == itemDepth + 1, namespaceURI == Self.sparkle || ((namespaceURI ?? "").isEmpty && element == "link") {
            textKey = element; textDepth = depth; text = ""
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if textKey != nil { text += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if let string = String(data: CDATABlock, encoding: .utf8), textKey != nil { text += string } }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName qName: String?) {
        if depth == textDepth, let key = textKey { item[key] = text.trimmingCharacters(in: .whitespacesAndNewlines); textKey = nil }
        if depth == itemDepth, element == "item" {
            for enclosure in enclosures {
                guard let address = enclosure["url"], let url = URL(string: address), AppUpdateURLPolicy.allows(url),
                      let build = item["version"] ?? enclosure["sparkle:version"], AppUpdateVersion.components(build) != nil else { continue }
                let os = enclosure["sparkle:os"]
                guard os == nil || os == "macos" || os == "osx" else { continue }
                guard item["hardwareRequirements"] == nil, item["minimumAutoupdateVersion"] == nil else { continue }
                releases.append(AppcastRelease(build: build, version: item["shortVersionString"] ?? enclosure["sparkle:shortVersionString"] ?? build,
                    downloadURL: url, signature: enclosure["sparkle:edSignature"], length: enclosure["length"].flatMap(Int64.init),
                    minimumSystemVersion: item["minimumSystemVersion"], maximumSystemVersion: item["maximumSystemVersion"],
                    architecture: enclosure["sparkle:arch"], channel: item["channel"], minimumUpdateVersion: item["minimumUpdateVersion"],
                    installationType: enclosure["sparkle:installationType"], informationURL: item["link"].flatMap(URL.init(string:))))
            }
            itemDepth = nil
        }
        depth -= 1
    }
}
