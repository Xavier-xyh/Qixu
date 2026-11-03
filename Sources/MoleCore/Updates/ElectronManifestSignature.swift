import Foundation
import CryptoKit

/// EBUM1 with a bounded installed Ed25519 trust list; no network key import or unsigned fallback.
enum ElectronManifestSignature {
    static let prefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])
    static func publicKey(_ text: String) throws -> Data {
        guard text.utf8.count <= 4096 else { throw invalid() }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("-----BEGIN PUBLIC KEY-----") {
            guard body.hasSuffix("-----END PUBLIC KEY-----") else { throw invalid() }
            body = String(body.dropFirst("-----BEGIN PUBLIC KEY-----".count).dropLast("-----END PUBLIC KEY-----".count))
        }
        body = body.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: body), data.count == 44, data.prefix(12) == prefix else { throw invalid() }
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: data.suffix(32))
        return data
    }
    static func publicKeys(_ entries: [String]) throws -> [Data] {
        guard !entries.isEmpty, entries.count <= 8 else { throw invalid() }
        var keys: [Data] = []
        for entry in entries {
            guard entry.utf8.count <= 4096 else { throw invalid() }
            var remaining = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remaining.isEmpty else { throw invalid() }
            if remaining.hasPrefix("-----BEGIN PUBLIC KEY-----") {
                while !remaining.isEmpty {
                    guard remaining.hasPrefix("-----BEGIN PUBLIC KEY-----"), let end = remaining.range(of: "-----END PUBLIC KEY-----") else { throw invalid() }
                    keys.append(try publicKey(String(remaining[..<end.upperBound])))
                    guard keys.count <= 8 else { throw invalid() }
                    remaining = String(remaining[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } else { keys.append(try publicKey(remaining)) }
            guard keys.count <= 8 else { throw invalid() }
        }
        var seen = Set<Data>()
        return keys.filter { seen.insert($0).inserted }
    }
    static func verifiedDocument(_ data: Data, publicKey: Data?) throws -> UpdateYAML.Document {
        try verifiedDocument(data, publicKeys: publicKey.map { [$0] } ?? [])
    }
    static func verifiedDocument(_ data: Data, publicKeys: [Data]) throws -> UpdateYAML.Document {
        var document = try UpdateYAML.parse(data)
        guard !publicKeys.isEmpty else {
            guard document.values["signature"] == nil, document.values["signatures"] == nil else { throw invalid() }
            return document
        }
        guard publicKeys.count <= 8, publicKeys.allSatisfy({ $0.count == 44 && $0.prefix(12) == prefix }) else { throw invalid() }
        let message = try canonical(document)
        var candidates: [(String?, String)] = []
        if let legacy = document.values["signature"] { candidates.append((nil, legacy)) }
        for entry in document.signatures {
            guard Set(entry.keys).isSubset(of: ["keyId", "signature"]), let signature = entry["signature"] else { throw invalid() }
            if let id = entry["keyId"], !validHex(id, length: 64) { throw invalid() }
            candidates.append((entry["keyId"], signature))
        }
        guard !candidates.isEmpty, candidates.count <= 17 else { throw invalid() }
        var seen = Set<Data>(), verified = false
        for publicKey in publicKeys where seen.insert(publicKey).inserted {
            let id = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey.suffix(32))
            if candidates.contains(where: { keyID, value in
                guard keyID == nil || keyID == id, let signature = Data(base64Encoded: value), signature.count == 64 else { return false }
                return key.isValidSignature(signature, for: message)
            }) { verified = true; break }
        }
        guard verified else { throw invalid() }
        document.values.removeValue(forKey: "signature"); document.values.removeValue(forKey: "signatures")
        return document
    }
    static func canonical(_ document: UpdateYAML.Document) throws -> Data {
        guard let version = document.values["version"], stringType(document.rawValues["version"]),
              !document.files.isEmpty, document.files.count == document.rawFiles.count else { throw invalid() }
        var staging = "", minimum = ""
        if let value = document.values["stagingPercentage"] { staging = try number(value, raw: document.rawValues["stagingPercentage"]) }
        if let value = document.values["minimumSystemVersion"] {
            guard stringType(document.rawValues["minimumSystemVersion"]) else { throw invalid() }; minimum = quote(value)
        }
        var records: [String] = []
        for (index, file) in document.files.enumerated() {
            let raw = document.rawFiles[index]
            guard let url = file["url"], let hash = file["sha512"], stringType(raw["url"]), stringType(raw["sha512"]) else { throw invalid() }
            let size = try file["size"].map { try number($0, raw: raw["size"]) } ?? ""
            var record = "file:" + quote(url) + "\t" + quote(hash) + "\t" + size
            if let block = file["blockMapUrl"] {
                guard stringType(raw["blockMapUrl"]) else { throw invalid() }; record += "\t" + quote(block)
            }
            records.append(record)
        }
        records.sort { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
        return Data((["EBUM1", "version:" + quote(version), "staging:" + staging, "minimumSystemVersion:" + minimum] + records).joined(separator: "\n").utf8)
    }
    private static func number(_ value: String, raw: String?) throws -> String {
        guard let raw, raw.first != "\"", raw.first != "'", value.utf8.allSatisfy({ (48...57).contains($0) }),
              let n = UInt64(value), n <= 9_007_199_254_740_991, value == String(n) else { throw invalid() }; return value
    }
    private static func stringType(_ raw: String?) -> Bool {
        guard let raw, !raw.isEmpty else { return false }
        if raw.first == "\"" || raw.first == "'" { return true }
        let value = raw.components(separatedBy: " #")[0].lowercased()
        return !["true", "false", "null", "~", ".nan", ".inf", "-.inf", "+.inf"].contains(value) && Double(value) == nil && !value.hasPrefix("0x") && !value.hasPrefix("0o") && !value.hasPrefix("0b")
    }
    static func quote(_ value: String) -> String {
        var result = "\""
        for c in value.unicodeScalars {
            switch c.value {
            case 34: result += "\\\""
            case 92: result += "\\\\"
            case 8: result += "\\b"
            case 9: result += "\\t"
            case 10: result += "\\n"
            case 12: result += "\\f"
            case 13: result += "\\r"
            case 0..<32: result += String(format: "\\u%04x", c.value)
            default: result.unicodeScalars.append(c)
            }
        }
        return result + "\""
    }
    private static func invalid() -> AppUpdateError { .invalid("Electron 签名清单的公钥、类型、EBUM1 字段或签名验证失败，未使用未签名回退。") }
}

extension AppUpdateTarget {
    var requiresMetadataAuthentication: Bool {
        if requiresSignedFeed { return true }
        if case .electron(let configuration) = source { return !configuration.manifestPublicKeys.isEmpty }
        return false
    }
}
