import Foundation
import CryptoKit

/// The signature authenticates the exact bytes preceding the trailing protocol
/// comment. XML is parsed only after verification; no canonicalization or expiry
/// fallback is used. Ambiguous or future signing blocks fail closed.
public enum SparkleSignedFeed {
    public static func verifiedContent(_ data: Data, publicKey: String) throws -> Data {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024,
              let key = Data(base64Encoded: publicKey), key.count == 32 else { throw invalid("信息源大小或公钥无效") }
        let prefix = Data("<!-- sparkle-signatures:\n".utf8), suffix = Data("-->".utf8)
        guard let start = data.range(of: prefix), start.lowerBound > data.startIndex,
              data.range(of: prefix, in: start.upperBound..<data.endIndex) == nil,
              let end = data.range(of: suffix, in: start.upperBound..<data.endIndex),
              end.lowerBound - start.upperBound <= 4096,
              data[end.upperBound...].allSatisfy({ [UInt8(9), 10, 13, 32].contains($0) }),
              let block = String(data: data[start.upperBound..<end.lowerBound], encoding: .utf8) else { throw invalid("缺少唯一、完整且位于末尾的签名块") }
        var fields: [String: String] = [:]
        for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            guard let colon = text.firstIndex(of: ":") else { throw invalid("签名块字段无效") }
            let name = String(text[..<colon])
            let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard ["edSignature", "length"].contains(name), fields[name] == nil, !value.isEmpty else { throw invalid("签名块包含未知或重复字段") }
            fields[name] = value
        }
        let content = Data(data[..<start.lowerBound])
        guard let lengthText = fields["length"], lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = UInt64(lengthText), length == UInt64(content.count),
              let encoded = fields["edSignature"], let signature = Data(base64Encoded: encoded), signature.count == 64,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key),
              publicKey.isValidSignature(signature, for: content) else { throw invalid("内容长度或 Ed25519 签名不匹配") }
        return content
    }
    private static func invalid(_ reason: String) -> AppUpdateError {
        .invalid("签名信息源验证失败：\(reason)。未使用未签名信息，也不会自动降级验证。")
    }
}
