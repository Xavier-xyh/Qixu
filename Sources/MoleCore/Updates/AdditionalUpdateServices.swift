import Foundation
import CryptoKit
import Darwin

public struct CodeUpdateConfiguration: Equatable, Sendable {
    public let feedURL: URL
    public let commit: String
    public let declarationSHA256: Data
    public static func read(application: URL, bundleID: String) throws -> CodeUpdateConfiguration? {
        guard bundleID == "com.microsoft.VSCode" else { return nil }
        let file = application.appendingPathComponent("Contents/Resources/app/product.json")
        try PathSafety.rejectSymbolicLinks(in: file)
        let identity = try FileIdentity.capture(file)
        guard identity.fileType == UInt32(S_IFREG), (1...4_194_304).contains(identity.size) else { throw AppUpdateError.invalid("VS Code 产品声明大小或类型无效。") }
        return try parse(Data(contentsOf: file))
    }
    static func parse(_ data: Data) throws -> CodeUpdateConfiguration {
        guard data.count <= 4 * 1024 * 1024, let product = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              product["updateUrl"] as? String == "https://update.code.visualstudio.com", product["quality"] as? String == "stable",
              product["darwinBundleIdentifier"] as? String == "com.microsoft.VSCode",
              let commit = product["commit"] as? String, validHex(commit, length: 40) else { throw AppUpdateError.unavailable("此 VS Code 发行渠道或产品身份不在支持范围。") }
        #if arch(arm64)
        let platform = "darwin-arm64"
        #else
        let platform = "darwin"
        #endif
        return CodeUpdateConfiguration(feedURL: URL(string: "https://update.code.visualstudio.com/api/update/\(platform)/stable/latest")!, commit: commit, declarationSHA256: Data(SHA256.hash(data: data)))
    }
}
public struct StoreUpdateConfiguration: Equatable, Sendable {
    public let feedURL: URL
    public static func read(application: URL, bundleID: String) -> StoreUpdateConfiguration? {
        let file = application.appendingPathComponent("Contents/_MASReceipt/receipt")
        guard let identity = try? FileIdentity.capture(file), identity.fileType == UInt32(S_IFREG), identity.size > 0,
              (try? PathSafety.rejectSymbolicLinks(in: file)) != nil, !bundleID.isEmpty else { return nil }
        // The receipt is only a source hint; it is not decoded or used as proof of
        // purchase. Installation/authentication remain entirely with App Store.
        var url = URLComponents(string: "https://itunes.apple.com/lookup")!
        let region = Locale.current.region?.identifier ?? "US"
        let country = region.count == 2 && region.utf8.allSatisfy({ (65...90).contains($0) }) ? region : "US"
        url.queryItems = [URLQueryItem(name: "bundleId", value: bundleID), URLQueryItem(name: "entity", value: "macSoftware"), URLQueryItem(name: "country", value: country)]
        return StoreUpdateConfiguration(feedURL: url.url!)
    }
}
func validHex(_ value: String, length: Int) -> Bool { value.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }

enum AdditionalUpdateServices {
    static func check(_ target: AppUpdateTarget) async throws -> AppcastRelease? {
        let data = try await UpdateMetadataClient().load(target.feedURL)
        switch target.source {
        case .vscode:
            guard let parsed = try codeRelease(data, current: target.application.version) else { return nil }
            let length = try await UpdateMetadataClient().contentLength(parsed.downloadURL)
            return AppcastRelease(build: parsed.build, version: parsed.version, downloadURL: parsed.downloadURL, length: length, informationURL: parsed.informationURL, sha256: parsed.sha256, artifactID: parsed.artifactID)
        case .appStore: return try storeRelease(data, bundleID: target.application.bundleID, current: target.application.version)
        default: throw AppUpdateError.invalid("来源不适用此更新协议。")
        }
    }
    static func codeRelease(_ data: Data, current: String) throws -> AppcastRelease? {
        guard data.count <= 2 * 1024 * 1024, let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = info["productVersion"] as? String, AppUpdateVersion.components(version) != nil,
              let commit = info["version"] as? String, validHex(commit, length: 40),
              let checksum = info["sha256hash"] as? String, validHex(checksum, length: 64),
              let address = info["url"] as? String, let url = URL(string: address), AppUpdateURLPolicy.allows(url),
              url.pathExtension.lowercased() == "zip", let host = url.host,
              host == "vscode.download.prss.microsoft.com" || host == "az764295.vo.msecnd.net" else { throw AppUpdateError.invalid("VS Code 更新响应缺少适用版本、Microsoft 下载地址或 SHA-256。") }
        guard let comparison = AppUpdateVersion.compare(version, current) else { throw AppUpdateError.unavailable("当前版本格式不受支持。") }
        guard comparison == .orderedDescending else { return nil }
        return AppcastRelease(build: version, version: version, downloadURL: url, informationURL: URL(string: "https://code.visualstudio.com/updates"), sha256: checksum.lowercased(), artifactID: commit)
    }
    static func storeRelease(_ data: Data, bundleID: String, current: String) throws -> AppcastRelease? {
        guard data.count <= 2 * 1024 * 1024, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]], results.count <= 100 else { throw AppUpdateError.invalid("App Store 公开目录响应无效。") }
        let matches = results.filter { $0["bundleId"] as? String == bundleID && $0["kind"] as? String == "mac-software" }
        guard matches.count == 1, let match = matches.first else { throw AppUpdateError.unavailable("当前地区的公开目录未找到唯一对应应用；请在 App Store 中检查。") }
        guard let version = match["version"] as? String, let comparison = AppUpdateVersion.compare(version, current),
              let address = match["trackViewUrl"] as? String, let url = URL(string: address), url.host == "apps.apple.com", AppUpdateURLPolicy.allows(url) else { throw AppUpdateError.invalid("App Store 版本或官方页面无效。") }
        guard comparison == .orderedDescending else { return nil }
        return AppcastRelease(build: version, version: version, downloadURL: url, informationURL: url)
    }
}
