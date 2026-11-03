import Foundation

public enum AppUpdateSource: Equatable, Sendable {
    case sparkle
    case electron(ElectronUpdateConfiguration)
    case vscode(CodeUpdateConfiguration)
    case appStore(StoreUpdateConfiguration)
    public var label: String {
        switch self {
        case .sparkle: return "Sparkle"
        case .electron(let configuration):
            switch configuration.provider {
            case "github": return "Electron · GitHub"
            case "gitlab": return "Electron · GitLab"
            case "bitbucket": return "Electron · Bitbucket"
            case "r2": return "Electron · R2"
            case "s3": return "Electron · S3"
            case "spaces": return "Electron · Spaces"
            default: return "Electron · 通用源"
            }
        case .vscode: return "VS Code 官方"
        case .appStore: return "App Store"
        }
    }
}

public struct AppUpdateTarget: Identifiable, Sendable {
    public let application: InstalledApplication
    public let feedURL: URL
    public let publicKey: String?
    public let requiresSignedFeed: Bool
    public let source: AppUpdateSource
    public var id: String { application.id }
    public init(application: InstalledApplication, feedURL: URL, publicKey: String?, requiresSignedFeed: Bool = false, source: AppUpdateSource = .sparkle) {
        self.application = application; self.feedURL = feedURL; self.publicKey = publicKey; self.requiresSignedFeed = requiresSignedFeed
        self.source = source
    }
}

public struct AppcastRelease: Identifiable, Hashable, Sendable {
    public let build: String
    public let version: String
    public let downloadURL: URL
    public let signature: String?
    public let length: Int64?
    public let minimumSystemVersion: String?
    public let maximumSystemVersion: String?
    public let architecture: String?
    public let channel: String?
    public let minimumUpdateVersion: String?
    public let installationType: String?
    public let informationURL: URL?
    public let sha512: String?
    public let sha256: String?
    public let artifactID: String?
    public var id: String { build + ":" + downloadURL.absoluteString }
    public init(build: String, version: String, downloadURL: URL, signature: String? = nil, length: Int64? = nil, minimumSystemVersion: String? = nil, maximumSystemVersion: String? = nil, architecture: String? = nil, channel: String? = nil, minimumUpdateVersion: String? = nil, installationType: String? = nil, informationURL: URL? = nil, sha512: String? = nil, sha256: String? = nil, artifactID: String? = nil) {
        self.build = build; self.version = version; self.downloadURL = downloadURL; self.signature = signature; self.length = length
        self.minimumSystemVersion = minimumSystemVersion; self.maximumSystemVersion = maximumSystemVersion
        self.architecture = architecture; self.channel = channel; self.minimumUpdateVersion = minimumUpdateVersion
        self.installationType = installationType; self.informationURL = informationURL
        self.sha512 = sha512
        self.sha256 = sha256; self.artifactID = artifactID
    }
}

public enum AppUpdateError: LocalizedError {
    case invalid(String), unavailable(String), failed(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s), .unavailable(let s), .failed(let s): return s }
    }
}

enum AppUpdateMetadata {
    /// Unknown declarations are treated as requiring the vendor updater.
    static func requiresSignedFeed(_ info: [String: Any]) -> Bool {
        guard let value = info["SURequireSignedFeed"] else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            return !["false", "no", "0"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return true
    }
}

/// Conservative numeric build comparison. Unknown/prerelease formats are left to the vendor updater.
public enum AppUpdateVersion {
    public static func components(_ value: String) -> [UInt64]? {
        guard !value.isEmpty, value.count <= 120 else { return nil }
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count <= 12 else { return nil }
        let numbers = fields.compactMap { part -> UInt64? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt64(part)
        }
        return numbers.count == fields.count ? numbers : nil
    }
    public static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        guard let lhs = components(a), let rhs = components(b) else { return nil }
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0, r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }
}

public enum AppUpdateURLPolicy {
    public static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let raw = url.host, !raw.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.absoluteString.utf8.count <= 8192 else { return false }
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"), !host.contains("%") else { return false }
        if host.contains(":") {
            return host != "::" && host != "::1" && !host.hasPrefix("fe80:") && !host.hasPrefix("fc") && !host.hasPrefix("fd") && !host.hasPrefix("::ffff:")
        }
        guard host.contains("."), host.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            guard parts.allSatisfy({ (0...255).contains($0) }) else { return false }
            if [0, 10, 127].contains(parts[0]) || (parts[0] == 169 && parts[1] == 254) || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168) { return false }
        } else if host.split(separator: ".").last?.first?.isNumber == true { return false }
        return true
    }
}
