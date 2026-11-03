import Foundation
import CoreGraphics

public struct DiskTreemapTile: Identifiable {
    public var id: String { entry.id }
    public var entry: DiskEntry
    public var rect: CGRect
}

public enum DiskTreemapLayout {
    public static func tiles(entries: [DiskEntry], in bounds: CGRect) -> [DiskTreemapTile] {
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return [] }
        let entries = entries.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        var result: [DiskTreemapTile] = []
        divide(ArraySlice(entries), bounds, into: &result)
        return result
    }
    private static func divide(_ entries: ArraySlice<DiskEntry>, _ rect: CGRect, into result: inout [DiskTreemapTile]) {
        guard let first = entries.first else { return }
        if entries.count == 1 { result.append(DiskTreemapTile(entry: first, rect: rect)); return }
        let total = entries.reduce(0.0) { $0 + Double($1.size) }
        var amount = 0.0; var count = 0
        for entry in entries.dropLast() {
            amount += Double(entry.size); count += 1
            if amount >= total / 2 { break }
        }
        let ratio = CGFloat(amount / total)
        let split = entries.index(entries.startIndex, offsetBy: count)
        if rect.width >= rect.height {
            let width = rect.width * ratio
            divide(entries[..<split], CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height), into: &result)
            divide(entries[split...], CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height), into: &result)
        } else {
            let height = rect.height * ratio
            divide(entries[..<split], CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height), into: &result)
            divide(entries[split...], CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height), into: &result)
        }
    }
}
