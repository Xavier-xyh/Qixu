import Foundation
import CryptoKit
import Darwin

public struct ElectronUpdateConfiguration: Equatable, Sendable {
    public let provider: String
    public let feedURL: URL
    public let baseURL: URL?
    public let owner: String?
    public let repository: String?
    public internal(set) var manifestPublicKeys: [Data] = []
    public var manifestPublicKey: Data? { manifestPublicKeys.first }
    public let declarationSHA256: Data

    public static func read(application: URL) throws -> ElectronUpdateConfiguration? {
        let resources = application.appendingPathComponent("Contents/Resources")
        let file = resources.appendingPathComponent("app-update.yml")
        var status = stat()
        guard lstat(file.path, &status) == 0 else {
            guard errno == ENOENT else { throw AppUpdateError.invalid("无法读取 Electron 更新声明。") }
            return nil
        }
        try PathSafety.rejectSymbolicLinks(in: file)
        guard status.st_mode & S_IFMT == S_IFREG, status.st_size > 0, status.st_size <= 64 * 1024 else { throw AppUpdateError.invalid("Electron 更新声明类型或大小无效。") }
        return try parse(Data(contentsOf: file))
    }
    public static func parse(_ data: Data) throws -> ElectronUpdateConfiguration {
        var document = try UpdateYAML.parse(data, maximum: 64 * 1024)
        let value = document.values.removeValue(forKey: "updateManifestPublicKey")
        let keys: [Data]
        if let value {
            keys = try ElectronManifestSignature.publicKeys(document.publicKeyList ?? [value])
        } else { keys = [] }
        var configuration = try parseDeclaration(document, data: data)
        configuration.manifestPublicKeys = keys
        return configuration
    }
    private static func parseDeclaration(_ document: UpdateYAML.Document, data: Data) throws -> ElectronUpdateConfiguration {
        if ["s3", "spaces", "r2"].contains(document.values["provider"] ?? "") {
            guard document.files.isEmpty, document.values["channel"] == nil || document.values["channel"] == "latest" else { throw AppUpdateError.unavailable("仅支持公开对象存储的正式更新频道。") }
            let base = try ElectronObjectStorage.baseURL(document.values)
            return ElectronUpdateConfiguration(provider: document.values["provider"]!, feedURL: base.appendingPathComponent("latest-mac.yml"), baseURL: base, owner: nil, repository: nil, declarationSHA256: Data(SHA256.hash(data: data)))
        }
        if ["gitlab", "bitbucket"].contains(document.values["provider"] ?? "") {
            return try ElectronReleaseProviders.configuration(document, digest: Data(SHA256.hash(data: data)))
        }
        let allowed: Set<String> = ["provider", "url", "owner", "repo", "channel", "updaterCacheDirName", "useMultipleRangeRequest", "private", "releaseType", "vPrefixedTagName"]
        guard document.files.isEmpty, Set(document.values.keys).isSubset(of: allowed),
              document.values["channel"] == nil || document.values["channel"] == "latest" else { throw AppUpdateError.unavailable("此 Electron 来源包含自定义频道、认证或签名策略，请使用应用自身更新。") }
        let digest = Data(SHA256.hash(data: data))
        switch document.values["provider"] {
        case "generic":
            guard let value = document.values["url"], var base = URLComponents(string: value), base.query == nil,
                  document.values["owner"] == nil, document.values["repo"] == nil,
                  document.values["private"] == nil, document.values["releaseType"] == nil else { throw AppUpdateError.invalid("通用来源必须是无需认证和查询参数的 HTTPS 目录。") }
            if !base.path.hasSuffix("/") { base.path += "/" }
            guard let url = base.url, AppUpdateURLPolicy.allows(url) else { throw AppUpdateError.invalid("通用来源 URL 无效。") }
            return ElectronUpdateConfiguration(provider: "generic", feedURL: url.appendingPathComponent("latest-mac.yml"), baseURL: url, owner: nil, repository: nil, declarationSHA256: digest)
        case "github":
            guard let owner = document.values["owner"], let repo = document.values["repo"], validRepositoryPart(owner), validRepositoryPart(repo),
                  document.values["url"] == nil, document.values["private"] == nil || document.values["private"] == "false",
                  document.values["releaseType"] == nil || document.values["releaseType"] == "release" else { throw AppUpdateError.unavailable("仅支持明确声明的公开 GitHub 正式发布源。") }
            let feed = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
            return ElectronUpdateConfiguration(provider: "github", feedURL: feed, baseURL: nil, owner: owner, repository: repo, declarationSHA256: digest)
        default: throw AppUpdateError.unavailable("尚未支持此 Electron 更新 provider。")
        }
    }
    private static func validRepositoryPart(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 100 && text != "." && text != ".." && text.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
    }
}

public struct ElectronUpdateService: Sendable {
    let fetch: @Sendable (URL) async throws -> Data
    public init() { fetch = { try await UpdateMetadataClient().load($0) } }
    init(fetch: @escaping @Sendable (URL) async throws -> Data) { self.fetch = fetch }

    public func check(_ target: AppUpdateTarget) async throws -> AppcastRelease? {
        guard case .electron(let configuration) = target.source, target.feedURL == configuration.feedURL,
              Self.stableVersion(target.application.version) else { throw AppUpdateError.unavailable("此应用来源或版本格式需要由其自身更新器处理。") }
        let manifest: Data, base: URL, information: URL?, expectedVersion: String?
        if ["generic", "s3", "spaces", "r2", "bitbucket"].contains(configuration.provider), let url = configuration.baseURL {
            manifest = try await fetch(configuration.feedURL); base = url; information = nil; expectedVersion = nil
        } else if configuration.provider == "gitlab" {
            return try await ElectronReleaseProviders.checkGitLab(target, configuration: configuration, fetch: fetch)
        } else if configuration.provider == "github" {
            let release = try Self.githubRelease(try await fetch(configuration.feedURL), configuration: configuration)
            manifest = try await fetch(release.manifestURL)
            base = release.manifestURL.deletingLastPathComponent().appendingPathComponent("", isDirectory: true)
            information = release.informationURL; expectedVersion = release.version
        } else { throw AppUpdateError.invalid("Electron 来源声明无效。") }
        try Task.checkCancellation()
        if let expectedVersion, try UpdateYAML.parse(manifest).values["version"] != expectedVersion { throw AppUpdateError.invalid("GitHub 发布标签与更新清单版本不一致。") }
        let releases = try Self.parseManifest(manifest, baseURL: base, informationURL: information, manifestPublicKeys: configuration.manifestPublicKeys)
        let applicable = releases.filter { AppUpdateVersion.compare($0.version, target.application.version) == .orderedDescending }
        return applicable.first
    }
    static func stableVersion(_ version: String) -> Bool {
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        return fields.count == 3 && fields.allSatisfy { $0 == "0" || !$0.hasPrefix("0") } && AppUpdateVersion.components(version) != nil
    }
    static func parseManifest(_ data: Data, baseURL: URL, informationURL: URL? = nil, architecture: String = AppcastInstallValidation.architecture, systemVersion: String? = nil, manifestPublicKey: Data? = nil, manifestPublicKeys: [Data] = []) throws -> [AppcastRelease] {
        guard AppUpdateURLPolicy.allows(baseURL) else { throw AppUpdateError.invalid("更新清单基础 URL 无效。") }
        guard manifestPublicKey == nil || manifestPublicKeys.isEmpty else { throw AppUpdateError.invalid("签名信任参数存在歧义。") }
        let keys = manifestPublicKey.map { [$0] } ?? manifestPublicKeys
        let document = try ElectronManifestSignature.verifiedDocument(data, publicKeys: keys)
        let allowed: Set<String> = ["version", "files", "path", "sha512", "releaseDate", "releaseName", "releaseNotes", "minimumSystemVersion", "stagingPercentage"]
        guard Set(document.values.keys).isSubset(of: allowed),
              let version = document.values["version"], stableVersion(version) else { throw AppUpdateError.unavailable("更新清单含不受支持的版本、签名或安装策略，请使用应用自身更新。") }
        if let percentage = document.values["stagingPercentage"] {
            guard percentage == "100" else { throw AppUpdateError.unavailable("此更新采用分批发布，请由应用自身判断是否适用。") }
        }
        let minimum = document.values["minimumSystemVersion"]
        if let minimum {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = systemVersion ?? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            guard let comparison = AppUpdateVersion.compare(current, minimum) else { throw AppUpdateError.invalid("更新清单系统版本无效。") }
            if comparison == .orderedAscending { return [] }
        }
        let entries = document.files.isEmpty ? document.values["path"].map { [["url": $0, "sha512": document.values["sha512"] ?? ""]] } ?? [] : document.files
        guard !entries.isEmpty, entries.count <= 100 else { throw AppUpdateError.invalid("更新清单未包含可识别的文件。") }
        var releases: [(Int, AppcastRelease)] = []
        for file in entries {
            guard Set(file.keys).isSubset(of: ["url", "sha512", "size", "blockMapSize", "blockMapUrl"]),
                  let path = file["url"], !path.contains("\\"),
                  !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  let url = URL(string: path, relativeTo: baseURL)?.absoluteURL, AppUpdateURLPolicy.allows(url),
                  let checksum = file["sha512"], Data(base64Encoded: checksum)?.count == 64 else { throw AppUpdateError.invalid("更新文件 URL 或 SHA-512 无效。") }
            // Do not infer x64 compatibility via Rosetta. Exact native and
            // universal names win; ambiguous names are verified before install.
            let tokens = Set(url.deletingPathExtension().lastPathComponent.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            let arm = tokens.contains("arm64") || tokens.contains("aarch64")
            let intel = tokens.contains("x64") || tokens.contains("x86") || tokens.contains("amd64") || tokens.contains("intel")
            if (architecture == "arm64" && intel && !tokens.contains("universal")) || (architecture == "x86_64" && arm && !tokens.contains("universal")) { continue }
            let format = url.pathExtension.lowercased()
            guard ["zip", "dmg"].contains(format) else { continue }
            let length: Int64?
            if let value = file["size"] {
                guard value.utf8.allSatisfy({ (48...57).contains($0) }), let size = Int64(value), size > 0 else { throw AppUpdateError.invalid("更新文件长度无效。") }
                length = size
            } else { length = nil }
            let rank = (format == "zip" ? 10 : 0) + ((architecture == "arm64" && arm) || (architecture == "x86_64" && intel) ? 2 : 0)
            releases.append((rank, AppcastRelease(build: version, version: version, downloadURL: url, length: length, minimumSystemVersion: minimum, informationURL: informationURL, sha512: checksum)))
        }
        return releases.sorted { $0.0 > $1.0 }.map { $0.1 }
    }
    private struct GitHubRelease { let manifestURL: URL; let informationURL: URL?; let version: String }
    private static func githubRelease(_ data: Data, configuration: ElectronUpdateConfiguration) throws -> GitHubRelease {
        guard data.count <= 2 * 1024 * 1024, let owner = configuration.owner, let repo = configuration.repository,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["draft"] as? Bool) == false, (object["prerelease"] as? Bool) == false,
              let tag = object["tag_name"] as? String, let assets = object["assets"] as? [[String: Any]], assets.count <= 500 else { throw AppUpdateError.invalid("GitHub 发布响应无效。") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard stableVersion(version) else { throw AppUpdateError.unavailable("此 GitHub 发布标签需要应用自身更新器处理。") }
        let candidates = assets.filter { $0["name"] as? String == "latest-mac.yml" }
        guard candidates.count == 1, let address = candidates[0]["browser_download_url"] as? String,
              let url = URL(string: address), AppUpdateURLPolicy.allows(url), url.host == "github.com", url.query == nil,
              url.path == "/\(owner)/\(repo)/releases/download/\(tag)/latest-mac.yml" else { throw AppUpdateError.unavailable("GitHub 正式发布未提供唯一的 macOS 更新清单。") }
        let information = URL(string: "https://github.com/\(owner)/\(repo)/releases/tag/\(tag)")
        return GitHubRelease(manifestURL: url, informationURL: information, version: version)
    }
}
