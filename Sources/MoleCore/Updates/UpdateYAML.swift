import Foundation

/// A deliberately small reader for generated electron-builder metadata. It does
/// not evaluate YAML tags, aliases, merge keys or arbitrary object graphs.
enum UpdateYAML {
    struct Document {
        var values: [String: String] = [:]
        var rawValues: [String: String] = [:]
        var files: [[String: String]] = []
        var rawFiles: [[String: String]] = []
        var signatures: [[String: String]] = []
        var publicKeyList: [String]?
    }
    static func parse(_ data: Data, maximum: Int = 2 * 1024 * 1024) throws -> Document {
        guard !data.isEmpty, data.count <= maximum, let text = String(data: data, encoding: .utf8),
              !text.contains("\t"), !text.contains("\0") else { throw invalid() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count <= 50_000 else { throw invalid() }
        var document = Document(), inFiles = false, inSignatures = false, inKey = false, inKeyList = false, keyListBlock = false, inNotes = false, hasContent = false
        for raw in lines {
            let line = String(raw)
            guard line.utf8.count <= 32 * 1024 else { throw invalid() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count
            if inKeyList, keyListBlock, indent >= 4 {
                guard let count = document.publicKeyList?.count, count > 0 else { throw invalid() }
                document.publicKeyList![count - 1] += trimmed + "\n"
                continue
            }
            if inKey, indent > 0 {
                guard indent >= 2 else { throw invalid() }
                document.values["updateManifestPublicKey", default: ""] += trimmed + "\n"
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if inNotes, indent > 0 { continue }
            if trimmed == "---", !hasContent { hasContent = true; continue }
            hasContent = true
            if indent == 0 {
                inNotes = false; inFiles = false; inSignatures = false; inKey = false; inKeyList = false; keyListBlock = false
                let (key, value) = try pair(trimmed)
                guard document.values[key] == nil, document.values.count < 128 else { throw invalid() }
                document.rawValues[key] = value
                if key == "updateManifestPublicKey", value.isEmpty {
                    inKeyList = true; document.publicKeyList = []; document.values[key] = ""
                } else if key == "updateManifestPublicKey", ["|", "|-", "|+"].contains(value) {
                    inKey = true; document.values[key] = ""
                } else if key == "signatures" {
                    guard value.isEmpty else { throw invalid() }
                    inSignatures = true; document.values[key] = ""
                } else if key == "files" {
                    guard value.isEmpty else { throw invalid() }
                    inFiles = true; document.values[key] = ""
                } else if key == "releaseNotes", ["|", "|-", "|+", ">", ">-", ">+"].contains(value) {
                    inNotes = true; document.values[key] = ""
                } else { document.values[key] = try scalar(value, multiline: key == "updateManifestPublicKey") }
            } else if inKeyList, indent == 2, trimmed.hasPrefix("- ") {
                guard (document.publicKeyList?.count ?? 0) < 8 else { throw invalid() }
                let value = String(trimmed.dropFirst(2)); keyListBlock = ["|", "|-", "|+"].contains(value)
                document.publicKeyList!.append(keyListBlock ? "" : try scalar(value, multiline: true))
            } else if inFiles, indent == 2, trimmed.hasPrefix("- ") {
                guard document.files.count < 100 else { throw invalid() }
                let (key, value) = try pair(String(trimmed.dropFirst(2)))
                document.files.append([key: try scalar(value)]); document.rawFiles.append([key: value])
            } else if inFiles, indent == 4, !document.files.isEmpty {
                let (key, value) = try pair(trimmed)
                let index = document.files.count - 1
                guard document.files[index][key] == nil, document.files[index].count < 16 else { throw invalid() }
                document.files[index][key] = try scalar(value); document.rawFiles[index][key] = value
            } else if inSignatures, indent == 2, trimmed.hasPrefix("- ") {
                guard document.signatures.count < 16 else { throw invalid() }
                let (key, value) = try pair(String(trimmed.dropFirst(2)))
                document.signatures.append([key: try scalar(value)])
            } else if inSignatures, indent == 4, !document.signatures.isEmpty {
                let (key, value) = try pair(trimmed); let index = document.signatures.count - 1
                guard document.signatures[index][key] == nil, document.signatures[index].count < 2 else { throw invalid() }
                document.signatures[index][key] = try scalar(value)
            } else { throw invalid() }
        }
        return document
    }
    private static func pair(_ text: String) throws -> (String, String) {
        guard let colon = text.firstIndex(of: ":") else { throw invalid() }
        let key = String(text[..<colon])
        let tail = text[text.index(after: colon)...]
        guard !key.isEmpty, key.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }),
              tail.isEmpty || tail.first == " " else { throw invalid() }
        return (key, tail.trimmingCharacters(in: .whitespaces))
    }
    private static func scalar(_ text: String, multiline: Bool = false) throws -> String {
        guard !text.isEmpty else { throw invalid() }
        let result: String
        if text.hasPrefix("\"") {
            guard let data = ("[" + text + "]").data(using: .utf8), let array = try? JSONSerialization.jsonObject(with: data) as? [String], array.count == 1 else { throw invalid() }
            result = array[0]
        } else if text.hasPrefix("'") {
            guard text.count >= 2, text.hasSuffix("'") else { throw invalid() }
            let body = String(text.dropFirst().dropLast())
            guard !body.replacingOccurrences(of: "''", with: "").contains("'") else { throw invalid() }
            result = body.replacingOccurrences(of: "''", with: "'")
        } else {
            guard let first = text.first, !"&*!{[|>@`".contains(first), text != "null", text != "~" else { throw invalid() }
            result = text.components(separatedBy: " #")[0].trimmingCharacters(in: .whitespaces)
        }
        guard !result.isEmpty, !result.unicodeScalars.contains(where: { ($0.value < 32 && !(multiline && [10, 13].contains($0.value))) || $0.value == 127 }) else { throw invalid() }
        return result
    }
    private static func invalid() -> AppUpdateError { .invalid("更新 YAML 格式不受支持或存在重复、嵌套及歧义字段；请使用应用自身更新。") }
}
