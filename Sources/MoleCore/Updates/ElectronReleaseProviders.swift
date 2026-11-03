import Foundation

/// Declared public providers; no credentials, channel fallback or arbitrary repository discovery.
enum ElectronReleaseProviders {
    static func configuration(_ document: UpdateYAML.Document, digest: Data) throws -> ElectronUpdateConfiguration {
        let fields = document.values, provider = fields["provider"] ?? ""
        let common: Set<String> = ["provider", "channel", "updaterCacheDirName"]
        let allowed = common.union(provider == "gitlab" ? ["projectId", "host", "vPrefixedTagName", "uploadTarget"] : ["owner", "slug"])
        guard document.files.isEmpty, Set(fields.keys).isSubset(of: allowed), fields["channel"] == nil || fields["channel"] == "latest" else { throw invalid() }
        if provider == "bitbucket" {
            guard let owner = fields["owner"], let slug = fields["slug"], part(owner), part(slug) else { throw invalid() }
            let base = URL(string: "https://api.bitbucket.org/2.0/repositories/\(owner)/\(slug)/downloads/")!
            return ElectronUpdateConfiguration(provider: provider, feedURL: base.appendingPathComponent("latest-mac.yml"), baseURL: base, owner: owner, repository: slug, declarationSHA256: digest)
        }
        guard provider == "gitlab", fields["host"] == nil || fields["host"] == "gitlab.com",
              fields["vPrefixedTagName"] == nil || ["true", "false"].contains(fields["vPrefixedTagName"]!),
              fields["uploadTarget"] == nil || ["project_upload", "generic_package"].contains(fields["uploadTarget"]!),
              let project = fields["projectId"], project.count <= 400,
              project.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ part(String($0)) }),
              let encoded = project.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { throw invalid() }
        let feed = URL(string: "https://gitlab.com/api/v4/projects/\(encoded)/releases/permalink/latest")!
        return ElectronUpdateConfiguration(provider: provider, feedURL: feed, baseURL: nil, owner: nil, repository: project, declarationSHA256: digest)
    }
    static func checkGitLab(_ target: AppUpdateTarget, configuration: ElectronUpdateConfiguration, fetch: @Sendable (URL) async throws -> Data) async throws -> AppcastRelease? {
        let data = try await fetch(configuration.feedURL)
        guard data.count <= 2 * 1024 * 1024, let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              release["upcoming_release"] as? Bool == false, let tag = release["tag_name"] as? String,
              let assets = release["assets"] as? [String: Any], let links = assets["links"] as? [[String: Any]], links.count <= 500 else { throw invalid() }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard ElectronUpdateService.stableVersion(version) else { throw invalid() }
        var names: [String: URL] = [:]
        for link in links {
            guard let name = link["name"] as? String, filename(name), let address = link["direct_asset_url"] as? String,
                  let url = URL(string: address), AppUpdateURLPolicy.allows(url) else { throw invalid() }
            let key = normalized(name)
            guard names[key] == nil else { throw invalid() }
            names[key] = url
        }
        guard let manifestURL = names["latest-mac.yml"] else { throw invalid() }
        let manifest = try await fetch(manifestURL)
        try Task.checkCancellation()
        let document = try UpdateYAML.parse(manifest)
        guard document.values["version"] == version else { throw AppUpdateError.invalid("GitLab 发布标签与清单版本不一致。") }
        let filenames = document.files.isEmpty ? [document.values["path"] ?? ""] : document.files.map { $0["url"] ?? "" }
        guard filenames.allSatisfy(filename), Set(filenames.map(normalized)).count == filenames.count else { throw invalid() }
        let candidates = try ElectronUpdateService.parseManifest(manifest, baseURL: manifestURL.deletingLastPathComponent().appendingPathComponent("", isDirectory: true), manifestPublicKeys: configuration.manifestPublicKeys)
        for candidate in candidates {
            guard let url = names[normalized(candidate.downloadURL.lastPathComponent)] else { throw AppUpdateError.invalid("GitLab 发布中没有唯一对应的更新附件。") }
            if AppUpdateVersion.compare(candidate.version, target.application.version) == .orderedDescending {
                return AppcastRelease(build: candidate.build, version: candidate.version, downloadURL: url, length: candidate.length, minimumSystemVersion: candidate.minimumSystemVersion, sha512: candidate.sha512)
            }
        }
        return nil
    }
    private static func part(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value != "." && value != ".." && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
    }
    private static func filename(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".." && !value.contains(where: { "/\\%?#:".contains($0) }) && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }
    private static func normalized(_ name: String) -> String { name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-") }
    private static func invalid() -> AppUpdateError { .unavailable("此公开发布源的配置、标签或附件存在不支持或歧义内容，请使用应用自身更新。") }
}
