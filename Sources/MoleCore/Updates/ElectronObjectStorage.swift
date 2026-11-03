import Foundation

/// Public object-storage feeds only. Never reads SDK credentials or environment.
enum ElectronObjectStorage {
    static func baseURL(_ fields: [String: String]) throws -> URL {
        let provider = fields["provider"] ?? ""
        let common: Set<String> = ["provider", "channel", "updaterCacheDirName", "path", "acl"]
        let specific: Set<String> = provider == "r2" ? ["bucket", "accountId", "publicUrl", "jurisdiction"] : provider == "s3" ? ["bucket", "region", "accelerate", "endpoint", "forcePathStyle", "storageClass", "encryption"] : ["name", "region"]
        guard ["s3", "spaces", "r2"].contains(provider), Set(fields.keys).isSubset(of: common.union(specific)),
              fields["acl"] == nil || fields["acl"] == "public-read",
              fields["forcePathStyle"] == nil || fields["forcePathStyle"] == "false",
              fields["accelerate"] == nil || ["true", "false"].contains(fields["accelerate"]!),
              fields["region"] == nil || label(fields["region"]!) else { throw invalid() }
        var origin: String
        if provider == "r2" {
            guard let bucket = fields["bucket"], (3...63).contains(bucket.count), label(bucket),
                  let account = fields["accountId"], validHex(account, length: 32),
                  fields["jurisdiction"] == nil || ["eu", "fedramp"].contains(fields["jurisdiction"]!),
                  let address = fields["publicUrl"], !address.contains("%"), let url = URL(string: address),
                  AppUpdateURLPolicy.allows(url), url.query == nil,
                  !(url.host?.lowercased().hasSuffix(".r2.cloudflarestorage.com") ?? true),
                  !url.path.hasPrefix("//"), !url.path.contains("//"),
                  url.path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }) else { throw invalid() }
            origin = address.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else if provider == "spaces" {
            guard let name = fields["name"], (3...63).contains(name.count), label(name), let region = fields["region"] else { throw invalid() }
            origin = "https://\(name).\(region).digitaloceanspaces.com"
        } else {
            guard let bucket = fields["bucket"], (3...63).contains(bucket.count),
                  bucket.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label(String($0)) }),
                  !(bucket.split(separator: ".").count == 4 && bucket.split(separator: ".").allSatisfy({ Int($0) != nil })) else { throw invalid() }
            if fields["accelerate"] == "true" {
                guard fields["endpoint"] == nil, !bucket.contains(".") else { throw invalid() }
                origin = "https://\(bucket).s3-accelerate.amazonaws.com"
            } else if let endpoint = fields["endpoint"] {
                guard let url = URL(string: endpoint), AppUpdateURLPolicy.allows(url), url.query == nil,
                      url.path.isEmpty || url.path == "/" else { throw invalid() }
                origin = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + bucket
            } else if bucket.contains(".") {
                guard let region = fields["region"] else { throw invalid() }
                origin = region == "us-east-1" ? "https://s3.amazonaws.com/\(bucket)" : "https://s3-\(region).amazonaws.com/\(bucket)"
            } else if fields["region"] == "cn-north-1" {
                origin = "https://\(bucket).s3.cn-north-1.amazonaws.com.cn"
            } else { origin = "https://\(bucket).s3.amazonaws.com" }
        }
        guard var components = URLComponents(string: origin) else { throw invalid() }
        if let path = fields["path"] {
            guard path.utf8.count <= 2048, !path.hasPrefix("//"), !path.hasSuffix("//"), !path.contains(where: { "%\\?#".contains($0) }),
                  !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw invalid() }
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmed.isEmpty {
                let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
                guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw invalid() }
                components.path += "/" + trimmed
            }
        }
        components.path += "/"
        guard let url = components.url, AppUpdateURLPolicy.allows(url) else { throw invalid() }
        return url
    }
    private static func label(_ text: String) -> Bool {
        guard (1...63).contains(text.count), let first = text.utf8.first, let last = text.utf8.last else { return false }
        func alphanumeric(_ c: UInt8) -> Bool { (97...122).contains(c) || (48...57).contains(c) }
        return alphanumeric(first) && alphanumeric(last) && text.utf8.allSatisfy { alphanumeric($0) || $0 == 45 }
    }
    private static func invalid() -> AppUpdateError { .unavailable("此对象存储更新源的地址、公开访问或路径策略不受支持，请使用应用自身更新。") }
}
