import Foundation

public enum DiskReport {
    public static func csv(_ result: DiskScanResult) -> String {
        let headers = "名称,路径,字节,状态,目录,修改时间,读取问题,统计时间"
        let rows = result.entries.map { entry in
            [field(entry.name), field(entry.url.path), String(entry.size), field(entry.sizeStatus.label),
             entry.isDirectory ? "是" : "否", field(entry.modifiedAt?.ISO8601Format() ?? ""),
             String(entry.issueCount), field(result.scannedAt.ISO8601Format())].joined(separator: ",")
        }
        return "\u{feff}" + ([headers] + rows).joined(separator: "\r\n")
    }
    private static func field(_ text: String) -> String {
        // Quoted CSV fields can still be interpreted as spreadsheet formulas.
        let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first
        let safe = first.map { "=+-@".contains($0) } == true ? "'" + text : text
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
